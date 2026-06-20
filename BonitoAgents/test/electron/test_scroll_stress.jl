# Tier 2l — scroll stress matrix.
#
# Builds on test_scroll_chase.jl but exercises the *combinations* the user
# called out: keyboard open/close × heavy streaming × thoughts × tool calls
# × attach/remove image × user-initiated scroll. Each section drives one
# specific permutation and asserts the same two invariants:
#   (1) the input field stays visible (never pushed below the viewport)
#   (2) the last visible-class message bubble's bottom edge is at/above
#       the messages container's bottom (when chase is engaged)
#
# Helpers used everywhere:
#   gap()         — scrollHeight - scrollTop - clientHeight (small = at bottom)
#   last_in_view() — true iff the last .bt-agent-msg bottom edge is visible
#   input_visible() — true iff .bt-text-input rect is inside the viewport
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using JSON

state = TH.make_state(; n_workers = 1, n_projects = 1)
proj  = state.projects[]["p-1"]

let
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
    TH.seed_chat_history!(model, 10)
end

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

# ── PNG bytes for attachment tests ─────────────────────────────────────────
const SMALL_PNG = UInt8[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
]
const SMALL_PNG_HEX = lowercase(bytes2hex(SMALL_PNG))

js_bytes_from_hex(hex) = """
    (() => {
        const hex = $(JSON.json(hex));
        const out = new Uint8Array(hex.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i*2, 2), 16);
        return out;
    })()
"""

try
    # ── Navigate into chat ─────────────────────────────────────────────────
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null") "chat didn't mount"
    sleep(0.8)

    chat = state.chat_models["p-1"]

    function gap()
        # Math.round here — Chromium can return fractional pixel values
        # for scrollHeight/clientHeight under subpixel layout (which
        # the input-area flex-column layout reliably triggers).
        # `Int(15.89)` raises InexactError; rounding in JS keeps the
        # Julia call sites simple.
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight);
        })()""")
    end

    function last_in_view()
        TH.eval_js(ctx, """(() => {
            const bubbles = document.querySelectorAll('.bt-agent-msg');
            if (bubbles.length === 0) return false;
            const last = bubbles[bubbles.length - 1];
            const lr = last.getBoundingClientRect();
            const cr = document.querySelector('.bt-messages').getBoundingClientRect();
            return lr.bottom <= cr.bottom + 50 && lr.bottom >= cr.top;
        })()""")
    end

    function input_visible()
        TH.eval_js(ctx, """(() => {
            const inp = document.querySelector('.bt-text-input');
            if (!inp) return false;
            const r = inp.getBoundingClientRect();
            return r.bottom > 0 && r.top < window.innerHeight;
        })()""")
    end

    function reengage_chase()
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            c.__bt_chat.setFollowMode(true);
            c.__bt_chat._queueScrollToBottom();
            return true;
        })()""")
    end

    function emit_chunks(stream_id, n; text = "lorem ipsum dolor sit amet. ")
        # Start the agent stream if it isn't already in flight.
        if !any(m -> m isa BonitoAgents.AgentMsg && m.id == stream_id, chat.msgs_store)
            push!(chat.msgs_store, BonitoAgents.AgentMsg(stream_id, ""))
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "agent", "id" => stream_id, "streaming" => true,
                "text" => "", "n" => length(chat.msgs_store)))
            sleep(0.1)
        end
        for _ in 1:n
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "chunk", "id" => stream_id, "text" => text))
        end
    end

    # Settle: wait until the WS-queued chunks have all landed on JS and the
    # chase-rAF has caught up. 0.6s was too short for 80-chunk bursts; 1.5s
    # is enough headroom for offscreen rAF throttling on this setup.
    settle() = sleep(1.5)

    # Poll until the chase has driven gap below `target` (default 200). In
    # headless Electron rAF can be throttled to ~1 Hz, so a plain `sleep`
    # of 1.5s sometimes isn't enough when the layout is also changing
    # (viewport resize fires async resize observers across multiple frames).
    # Returns true on success, false on timeout.
    function wait_for_gap_settled(; target::Int = 200, timeout::Float64 = 4.0)
        TH.wait_for(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            return c.scrollHeight - c.scrollTop - c.clientHeight < $target;
        })()"""; timeout = timeout, interval = 0.1)
    end

    function emit_thought_chunks(stream_id, n; text = "considering options. ")
        if !any(m -> m isa BonitoAgents.ThoughtMsg && m.id == stream_id, chat.msgs_store)
            push!(chat.msgs_store, BonitoAgents.ThoughtMsg(stream_id, ""))
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "thought", "id" => stream_id, "streaming" => true,
                "text" => "", "n" => length(chat.msgs_store)))
            sleep(0.1)
        end
        for _ in 1:n
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "thought_chunk", "id" => stream_id, "text" => text))
        end
    end

    function emit_tool(id, status)
        tool = BonitoAgents.GenericToolMsg(id, "execute", "ls -la", status, "1 line",
                                         0.0, 0.0, nothing)
        push!(chat.msgs_store, tool)
        d = BonitoAgents.msg_to_dict(tool, chat.chat_dir)
        d["n"] = length(chat.msgs_store)
        BonitoAgents.chat_emit(chat, d)
    end

    function paste_image(filename)
        TH.eval_js(ctx, """(() => {
            const bytes = $(js_bytes_from_hex(SMALL_PNG_HEX));
            const file  = new File([bytes], $(JSON.json(filename)),
                                   {type: 'image/png'});
            const chat = document.querySelector('.bt-messages').__bt_chat;
            chat._attachAddBlob(file, file.type, file.name);
            return true;
        })()""")
    end

    # ── 0. Baseline at desktop ────────────────────────────────────────────
    TH.section("Baseline at desktop viewport") do
        TH.set_window_size(ctx, 1280, 800)
        sleep(0.3)
        record("input visible at baseline",        @TH.test_true input_visible())
        record("last bubble visible at baseline",  @TH.test_true last_in_view())
        record("gap < 200 at baseline",            @TH.test_true (Int(gap()) < 200))
    end

    # ── 1. Heavy agent burst ──────────────────────────────────────────────
    TH.section("Burst: 30 chunks of agent text → stays at bottom") do
        emit_chunks("stress-1", 30)
        settle()
        record("gap < 200 after burst", @TH.test_true (Int(gap()) < 200))
        record("last bubble in view",   @TH.test_true last_in_view())
        record("input still visible",   @TH.test_true input_visible())
    end

    # ── 2. Interleaved thoughts + agent ───────────────────────────────────
    TH.section("Interleaved agent + thought chunks → stays at bottom") do
        for _ in 1:4
            emit_chunks("stress-1", 6)
            emit_thought_chunks("stress-thought-1", 6)
            sleep(0.15)
        end
        settle()
        record("gap < 200",            @TH.test_true (Int(gap()) < 200))
        record("last bubble in view",  @TH.test_true last_in_view())
        record("input still visible",  @TH.test_true input_visible())
    end

    # ── 3. Tool calls in flight (pending → completed) ─────────────────────
    TH.section("Tool calls in flight don't unanchor scroll") do
        for i in 1:4
            emit_tool("tool-stress-$i", "pending")
            emit_chunks("stress-2", 8)
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "tool_update", "id" => "tool-stress-$i",
                "status" => "completed", "title" => "ls -la", "summary" => "0 lines"))
            sleep(0.15)
        end
        settle()
        record("gap < 200 after tool churn",  @TH.test_true (Int(gap()) < 200))
        record("last bubble in view",         @TH.test_true last_in_view())
        record("input still visible",         @TH.test_true input_visible())
    end

    # ── 4. Keyboard open mid-stream (viewport shrink) ─────────────────────
    # At 480x400 a single tall bubble can exceed the messages viewport — in
    # that case last_in_view is fundamentally false even when chase is
    # perfect. We assert "gap small" instead: the user is at the bottom of
    # the scrollable area, which is the strongest invariant the chat can
    # offer when the latest message is taller than the viewport.
    TH.section("Keyboard open mid-burst keeps input visible and gap small") do
        TH.set_window_size(ctx, 480, 800)
        sleep(0.4)
        reengage_chase()
        # Stream while shrinking — simulate iOS soft-keyboard slide-in.
        @async begin
            for _ in 1:6
                emit_chunks("stress-3", 4)
                sleep(0.08)
            end
        end
        sleep(0.1)
        TH.set_window_size(ctx, 480, 400)
        record("gap < 200 after keyboard up (poll)",
               @TH.test_true wait_for_gap_settled(; timeout = 4.0))
        record("input visible after keyboard up", @TH.test_true input_visible())
    end

    # ── 5. Keyboard close (viewport grow back) ────────────────────────────
    TH.section("Keyboard close (viewport grow back) keeps tail anchored") do
        reengage_chase()
        emit_chunks("stress-3", 15)
        sleep(0.5)
        TH.set_window_size(ctx, 480, 800)
        settle()
        record("input visible after keyboard close", @TH.test_true input_visible())
        record("last bubble still in view",          @TH.test_true last_in_view())
        record("gap < 200",                          @TH.test_true (Int(gap()) < 200))
    end

    # ── 6. Attach image during streaming ─────────────────────────────────
    TH.section("Attach image mid-stream → input + tail stay visible") do
        TH.set_window_size(ctx, 1280, 800)
        sleep(0.4)
        reengage_chase()
        @async begin
            for _ in 1:5
                emit_chunks("stress-4", 4)
                sleep(0.08)
            end
        end
        sleep(0.1)
        paste_image("during-stream.png")
        settle()
        record("thumbnail appeared",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 1";
                   timeout = 2.0))
        record("input still visible after paste",  @TH.test_true input_visible())
        record("last bubble still in view",        @TH.test_true last_in_view())
        # gap may be slightly larger because the attachment bar pushed the
        # input area up (which shrinks .bt-messages); the chase should still
        # be < 200 due to the container ResizeObserver re-scroll.
        record("gap < 200 after attachment-bar pop",
               @TH.test_true (Int(gap()) < 200))
    end

    # ── 7. Remove attachment during streaming ────────────────────────────
    TH.section("Remove attachment mid-stream → still anchored") do
        reengage_chase()
        @async begin
            for _ in 1:5
                emit_chunks("stress-4", 4)
                sleep(0.08)
            end
        end
        sleep(0.1)
        TH.eval_js(ctx, """(() => {
            const thumb = document.querySelector('.bt-attachment-thumb .bt-attachment-remove');
            if (thumb) thumb.click();
            return true;
        })()""")
        settle()
        record("thumbnail removed",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelectorAll('.bt-attachment-thumb').length === 0";
                   timeout = 2.0))
        record("input still visible after remove", @TH.test_true input_visible())
        record("last bubble still in view",        @TH.test_true last_in_view())
        record("gap < 200 after attachment-bar collapse",
               @TH.test_true (Int(gap()) < 200))
    end

    # ── 8. Add/remove rapid toggle while streaming ───────────────────────
    TH.section("Rapid attach/remove toggle x 5 while streaming") do
        reengage_chase()
        @async begin
            for _ in 1:8
                emit_chunks("stress-5", 4)
                sleep(0.05)
            end
        end
        sleep(0.05)
        for i in 1:5
            paste_image("toggle-$i.png")
            sleep(0.18)
            TH.eval_js(ctx, """(() => {
                const rm = document.querySelector('.bt-attachment-thumb .bt-attachment-remove');
                if (rm) rm.click();
                return true;
            })()""")
            sleep(0.12)
        end
        settle()
        record("attachment bar empty at end",
               @TH.test_eq TH.dom_count(ctx, ".bt-attachment-thumb")  0)
        record("input still visible after rapid toggling", @TH.test_true input_visible())
        record("last bubble still in view",                @TH.test_true last_in_view())
    end

    # ── 9. User scrolls up → chase disengages → new chunks DON'T re-anchor
    # rAF + scroll events are throttled in headless Electron (≈1 Hz when the
    # window is hidden), so a programmatic scrollTop=0 takes a long time to
    # trigger the natural scroll event. We dispatch a synthetic 'scroll'
    # event right after the write so the chat's scroll handler runs in the
    # same tick. This mirrors what would happen during a real user scroll.
    #
    # We can't reliably assert on scrollTop after this point — Chromium's
    # scroll-anchoring shifts scrollTop when DOM mutations happen above
    # the viewport (which `refresh()` does, swapping bottom-rendered
    # nodes for top-of-list nodes). The user-facing invariant we care
    # about is "the chat doesn't auto-re-engage follow mode from chunks
    # alone", which is captured by `followMode` staying false through
    # the burst — plus the "↓ New messages" pill must appear.
    TH.section("Scrolling up during stream disengages follow mode") do
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            // Simulate a wheel event so the chat treats this as
            // user-driven (the 400ms recent-user-input window). Without
            // this, the scroll handler classifies as a layout shift and
            // re-engages follow mode.
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        sleep(0.3)
        follow = TH.eval_js(ctx, """
            document.querySelector('.bt-messages').__bt_chat.followMode""")
        record("followMode is false after scroll-to-top",
               @TH.test_eq follow false)
        # Stream more chunks; the chat must NOT re-engage follow mode by
        # itself, and the pill should appear to signal unread content.
        emit_chunks("stress-6", 10)
        sleep(0.6)
        follow_after = TH.eval_js(ctx, """
            document.querySelector('.bt-messages').__bt_chat.followMode""")
        record("followMode still false after chunks",
               @TH.test_eq follow_after false)
        record("'↓ New messages' pill is visible",
               @TH.test_true TH.wait_for(ctx,
                   "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible') !== null";
                   timeout = 2.0))
    end

    # ── 10. Sending from scrollback does NOT re-engage chase ──────────────
    # Strict no-yank spec: the user's own message bubble lands at the
    # bottom but the viewport stays where they were reading. They must
    # click the pill (or scroll to the bottom) to come back.
    TH.section("Sending from scrollback keeps user in scrollback") do
        TH.type_into(ctx, ".bt-text-input", "back to bottom please")
        sleep(0.1)
        TH.dom_click(ctx, ".bt-send-btn")
        sleep(1.0)
        follow = TH.eval_js(ctx,
            "document.querySelector('.bt-messages').__bt_chat.followMode")
        record("followMode still false after user send",
               @TH.test_eq follow false)
        record("input still visible",        @TH.test_true input_visible())
        # Now re-engage explicitly (pill click) — chase should converge.
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages').__bt_chat;
            c.setFollowMode(true);
            c.scrollToBottom();
            return true;
        })()""")
        record("gap < 200 after explicit re-engage",
               @TH.test_true wait_for_gap_settled(; timeout = 4.0))
    end

    # ── 11. Attach + send → bubble + multimodal in one go, still anchored
    TH.section("Attach + send while at bottom → still anchored after") do
        reengage_chase()
        paste_image("final-attach.png")
        sleep(0.3)
        TH.type_into(ctx, ".bt-text-input", "with image")
        sleep(0.1)
        TH.dom_click(ctx, ".bt-send-btn")
        sleep(0.8)
        record("attachment thumbnails cleared",
               @TH.test_eq TH.dom_count(ctx, ".bt-attachment-thumb")  0)
        record("gap < 200",                  @TH.test_true (Int(gap()) < 200))
        record("input still visible",        @TH.test_true input_visible())
    end

    # ── 12. No JS errors ──────────────────────────────────────────────────
    TH.section("No JS errors during the whole stress matrix") do
        errs = TH.js_errors(ctx)
        record("zero JS errors", @TH.test_eq length(errs) 0)
        isempty(errs) || @info "JS errors:" errs
    end

    # Restore desktop viewport for the final screenshot.
    TH.set_window_size(ctx, 1280, 800)
    sleep(0.3)
    TH.emit_screenshot(ctx; label = "scroll-stress final")

finally
    TH.report!("Tier 2l — scroll stress matrix", results)
    TH.shutdown(ctx)
end
