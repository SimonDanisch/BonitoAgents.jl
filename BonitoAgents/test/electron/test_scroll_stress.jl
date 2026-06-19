# Scroll stress matrix, migrated onto the TestKit harness (real dev_server, real
# worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked, via the `agent=` callback).
#
# Exercises the combinations the user called out: keyboard open/close × heavy
# streaming × thoughts × tool calls × attach/remove image × user-initiated
# scroll. Each phase drives one permutation and asserts the same invariants:
#   (1) the input field stays visible (never pushed below the viewport)
#   (2) the chat stays pinned at the bottom while chase is engaged (gap small),
#       i.e. the last bubble is in view
#   (3) a user scroll-up disengages chase and is NOT re-anchored by new chunks
#       (the "↓ New messages" pill appears instead)
#
# MIGRATION NOTES vs the legacy MockTransport version:
#   - Instead of `emit_chunks`/`emit_thought_chunks`/`emit_tool` poking
#     `chat_emit` directly, we drive a REAL held-open agent turn that streams
#     text + thoughts + tool calls with small `delay`s between events, so the
#     chunks travel the full ACP path and render real DOM. The test branches the
#     agent on the prompt text: "stream" runs the long interleaved stress turn;
#     a follow-up user send drives the scrollback-no-yank phase.
#   - Phases synchronise on DOM markers (chunk tags / pill class), never
#     wall-clock guesses. Chunk counts are scaled so a single held-open turn
#     stays responsive; the anchoring invariants are unchanged.
#   - Real attach via `_attachAddBlob` (a 1x1 PNG File), real removal via the
#     thumbnail's remove button — same as the legacy paste_image path.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, thought, tool, tool_update, text_block, delay, end_turn

# Long line per chunk so the pane overflows in a small window.
const LINE = "lorem ipsum dolor sit amet, consectetur adipiscing elit. "

# One big interleaved stress turn, held open with a long quiet window in the
# middle so the test can attach/scroll/resize against a live chat. The phase
# markers ([burst-*], [interleave-*], [tooltext-*], [hold], [tail-*]) let the
# test synchronise on real DOM rather than wall-clock sleeps.
function stress_turn()
    evs = Any[]
    # Phase 1: heavy agent burst.
    for i in 1:24
        push!(evs, text("[burst-$i] " * LINE)); push!(evs, delay(45))
    end
    # Phase 2: interleaved agent text + thoughts.
    for i in 1:8
        push!(evs, text("[interleave-$i] " * LINE)); push!(evs, delay(40))
        push!(evs, thought("considering option $i. ")); push!(evs, delay(40))
    end
    # Phase 3: a tool call in flight (open) then completed, with text after.
    push!(evs, tool(; kind = "execute", title = "ls -la", id = "stress-tool",
                      complete = false, open_status = "in_progress",
                      content = Any[text_block("running…")]))
    push!(evs, delay(120))
    push!(evs, tool_update("stress-tool"; status = "completed",
                           content = Any[text_block("done: 3 entries")]))
    for i in 1:6
        push!(evs, text("[tooltext-$i] " * LINE)); push!(evs, delay(40))
    end
    # Phase 4: a long quiet hold — the window in which the test attaches images,
    # resizes the viewport (keyboard sim) and scrolls. Marker [hold] lets the
    # test know the stream paused here.
    push!(evs, text("[hold] " * LINE))
    push!(evs, delay(15000))
    # Phase 5: tail burst (used by the scroll-up-disengage assertion: new chunks
    # arrive while the user is scrolled up; chase must NOT re-anchor).
    for i in 1:12
        push!(evs, text("[tail-$i] " * LINE)); push!(evs, delay(120))
    end
    push!(evs, end_turn())
    return evs
end

@testset "scroll stress matrix — burst/thoughts/tools/keyboard/attach, no-yank scroll" begin
    s = TK.dev_server(; agent = msg -> occursin("stream", lowercase(msg)) ?
                                        stress_turn() :
                                        [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 900, height = 600)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        sleep(0.6)

        follow() = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.followMode")
        gap_lt(target) = "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < $target; })()"
        input_visible() = TK.eval_js(s, """(() => {
            const inp = document.querySelector('.bt-text-input');
            if (!inp) return false;
            const r = inp.getBoundingClientRect();
            return r.bottom > 0 && r.top < window.innerHeight; })()""")
        last_in_view() = TK.eval_js(s, """(() => {
            const bubbles = document.querySelectorAll('.bt-agent-msg');
            if (bubbles.length === 0) return false;
            const last = bubbles[bubbles.length - 1];
            const lr = last.getBoundingClientRect();
            const cr = document.querySelector('.bt-messages').getBoundingClientRect();
            return lr.bottom <= cr.bottom + 50 && lr.bottom >= cr.top; })()""")
        reengage() = TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.__bt_chat.setFollowMode(true);
            c.__bt_chat._queueScrollToBottom();
            return true; })()""")
        marker_seen(m) = "document.querySelector('.bt-messages').innerText.indexOf('$m') !== -1"
        attach_png(name) = TK.eval_js(s, """(() => {
            const hex = '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489';
            const bytes = new Uint8Array(hex.length/2);
            for (let i=0;i<bytes.length;i++) bytes[i]=parseInt(hex.substr(i*2,2),16);
            const file = new File([bytes], $(TK.json(name)), {type:'image/png'});
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachAddBlob(file, file.type, file.name);
            return true; })()""")
        remove_attach() = TK.eval_js(s, """(() => {
            const rm = document.querySelector('.bt-attachment-thumb .bt-attachment-remove');
            if (rm) rm.click(); return true; })()""")

        # ── 0. Baseline at desktop ────────────────────────────────────────────
        TK.set_window_size(s, 1280, 800); sleep(0.3)
        @test input_visible()
        @test TK.eval_js(s, gap_lt(200))

        # ── Kick off the long interleaved stress turn ─────────────────────────
        TK.send_message(s, "stream the stress turn please")
        TK.wait_for(s, "pane overflows", """
            (() => { const c = document.querySelector('.bt-messages');
                     return (c.scrollHeight - c.clientHeight) > 200; })()
        """; timeout = 25)

        # ── 1. Heavy agent burst → stays at bottom ────────────────────────────
        TK.wait_for(s, "burst streamed", marker_seen("[burst-24]"); timeout = 25)
        @test TK.wait_for(s, "gap small after burst", gap_lt(200); timeout = 6)
        @test input_visible()

        # ── 2. Interleaved agent + thoughts → stays at bottom ─────────────────
        TK.wait_for(s, "interleave streamed", marker_seen("[interleave-8]"); timeout = 25)
        @test TK.wait_for(s, "gap small after interleave", gap_lt(200); timeout = 6)
        @test TK.wait_for(s, "thought bubble rendered",
            "document.querySelectorAll('.bt-thought-msg').length > 0"; timeout = 6)
        @test input_visible()

        # ── 3. Tool calls in flight don't unanchor scroll ─────────────────────
        TK.wait_for(s, "tool rendered",
            "document.querySelectorAll('.bt-tool-msg').length > 0"; timeout = 15)
        TK.wait_for(s, "post-tool text streamed", marker_seen("[tooltext-6]"); timeout = 25)
        @test TK.wait_for(s, "gap small after tool churn", gap_lt(200); timeout = 6)
        @test input_visible()
        @test last_in_view()

        # The stream now holds quiet at [hold]; the UI-action phases run here.
        TK.wait_for(s, "stream reached hold", marker_seen("[hold]"); timeout = 25)

        # ── 4. Keyboard open mid-hold keeps input visible and gap small ───────
        # At 480x400 a single tall bubble can exceed the viewport, so we assert
        # "gap small" (at the bottom of the scrollable area) — the strongest
        # invariant when the latest content is taller than the viewport.
        TK.set_window_size(s, 480, 800); sleep(0.4)
        reengage()
        @test TK.wait_for(s, "re-engaged at 480x800",
            "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4)
        TK.set_window_size(s, 480, 400); sleep(0.4)   # soft-keyboard slide-in
        @test TK.wait_for(s, "gap small after keyboard up", gap_lt(200); timeout = 4)
        @test input_visible()

        # ── 5. Keyboard close (viewport grow back) keeps tail anchored ────────
        reengage()
        TK.set_window_size(s, 480, 800); sleep(0.4)
        @test TK.wait_for(s, "gap small after keyboard close", gap_lt(200); timeout = 4)
        @test input_visible()

        # ── 6. Attach image during hold → input + tail stay visible ───────────
        TK.set_window_size(s, 1280, 800); sleep(0.4)
        reengage()
        attach_png("during-stream.png")
        @test TK.wait_for(s, "thumbnail appeared",
            "document.querySelectorAll('.bt-attachment-thumb').length === 1"; timeout = 4)
        @test input_visible()
        # The attachment bar shrinks .bt-messages; the container ResizeObserver
        # re-scroll must keep us pinned.
        @test TK.wait_for(s, "gap small after attachment-bar pop", gap_lt(200); timeout = 4)
        @test last_in_view()

        # ── 7. Remove attachment → still anchored ─────────────────────────────
        reengage()
        remove_attach()
        @test TK.wait_for(s, "thumbnail removed",
            "document.querySelectorAll('.bt-attachment-thumb').length === 0"; timeout = 4)
        @test input_visible()
        @test TK.wait_for(s, "gap small after attachment-bar collapse", gap_lt(200); timeout = 4)

        # ── 8. Rapid attach/remove toggle x 5 ─────────────────────────────────
        reengage()
        for i in 1:5
            attach_png("toggle-$i.png")
            TK.wait_for(s, "toggle-$i attached",
                "document.querySelectorAll('.bt-attachment-thumb').length === 1"; timeout = 4)
            remove_attach()
            TK.wait_for(s, "toggle-$i removed",
                "document.querySelectorAll('.bt-attachment-thumb').length === 0"; timeout = 4)
        end
        @test Int(TK.eval_js(s, "document.querySelectorAll('.bt-attachment-thumb').length")) == 0
        @test input_visible()

        # ── 9. Scroll-up disengages chase; tail burst must NOT re-anchor ──────
        # Scroll to the top (synthetic wheel marks it user-driven). The held
        # stream resumes the tail burst; followMode must stay false and the
        # "↓ New messages" pill must appear.
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: -100}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true; })()""")
        @test TK.wait_for(s, "followMode false after scroll-to-top",
            "document.querySelector('.bt-messages').__bt_chat.followMode === false"; timeout = 4)
        # Tail burst lands while we're scrolled away.
        TK.wait_for(s, "tail burst streaming", marker_seen("[tail-1]"); timeout = 20)
        @test TK.wait_for(s, "pill visible on new content",
            "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible') !== null"; timeout = 8)
        @test follow() == false   # new chunks didn't yank us back

        # Wait for the turn to finish so the next send is a clean turn.
        TK.wait_for(s, "tail burst finished", marker_seen("[tail-12]"); timeout = 20)

        # ── 10. Sending from scrollback does NOT re-engage chase ──────────────
        # Strict no-yank: the user's bubble lands at the bottom but the viewport
        # stays where they were reading. Re-scroll to the top first (the tail
        # burst may have nudged scrollTop).
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: -100}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true; })()""")
        @test TK.wait_for(s, "followMode false before send",
            "document.querySelector('.bt-messages').__bt_chat.followMode === false"; timeout = 4)
        TK.send_message(s, "back to bottom please")
        sleep(1.0)
        @test follow() == false
        @test input_visible()
        # Explicit re-engage (pill-click path) → chase converges.
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages').__bt_chat;
            c.setFollowMode(true); c.scrollToBottom(); return true; })()""")
        @test TK.wait_for(s, "gap small after explicit re-engage", gap_lt(200); timeout = 4)

        # Restore desktop viewport for the final screenshot.
        TK.set_window_size(s, 1280, 800); sleep(0.3)
        TK.screenshot(s, joinpath(tempdir(), "bt-scroll-stress-final.png"))

        # ── 11. No JS errors during the whole stress matrix ───────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
