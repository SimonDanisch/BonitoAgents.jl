# Follow mode + "↓ New messages" pill, migrated onto the TestKit harness (real
# dev_server, real worker subprocess, real ACP wire, real Electron browser; only
# the agent's behaviour is faked, via the `agent=` callback).
#
# The scroll-UX contract (unchanged from the legacy test):
#   - followMode starts true; chunks auto-scroll the viewport
#   - streaming while at the bottom shows NO pill
#   - user scrolls up → followMode flips false (pill stays hidden until there's
#     actually something new)
#   - new content while disengaged → pill becomes visible, unreadCount++
#   - clicking the pill → followMode back to true, pill hides, scrollTop snaps to
#     the bottom
#   - user scrolling back to the very bottom (within AT_BOTTOM_PX) also
#     re-engages followMode automatically (Slack/Discord style)
#
# Instead of poking the model with synthetic `chat_emit` bursts, we drive the
# REAL agent stream: one long turn that streams a viewport-filling first wave,
# holds the turn open with a quiet `delay` (the window in which the test scrolls
# up and asserts "no pill yet"), then streams a second wave (the new content
# that must surface the pill). `__bt_chat` is the chat instance's devtools hook;
# we read followMode / unreadCount off it exactly as the legacy test did.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, delay, end_turn

# A long line per chunk so the message pane overflows and becomes scrollable in
# a small window. `W1_N` chunks fill the viewport; the quiet `delay` is the
# scroll-up window; `W2_N` chunks are the "new while disengaged" content.
const LONG = "More content arriving while the chat streams a long agent reply that fills the viewport. "
const W1_N = 30
const QUIET_MS = 7000
const W2_N = 15

@testset "follow mode + new-message pill — driven by the real agent stream" begin
    s = TK.dev_server(; agent = msg -> begin
        evs = Any[]
        for i in 1:W1_N
            push!(evs, text("[w1-$i] " * LONG)); push!(evs, delay(120))
        end
        # Hold the turn open, quietly, so the test can scroll up and assert the
        # pill stays hidden BEFORE any new content arrives.
        push!(evs, delay(QUIET_MS))
        for i in 1:W2_N
            push!(evs, text("[w2-$i] " * LONG)); push!(evs, delay(150))
        end
        push!(evs, end_turn())
        evs
    end)
    try
        # Small window so the stream overflows and the pane scrolls.
        TK.open_browser(s; width = 900, height = 600)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        sleep(0.5)

        follow_mode() = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.followMode")
        unread()      = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.unreadCount")
        pill_visible() = TK.eval_js(s, """
            (() => { const el = document.querySelector('.bt-new-msg-pill');
                     return el ? el.classList.contains('bt-new-msg-pill-visible') : false; })()
        """)
        scroll_gap() = Int(TK.eval_js(s, """
            (() => { const c = document.querySelector('.bt-messages');
                     return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight); })()
        """))
        w2_count() = Int(TK.eval_js(s, """
            (() => Array.from(document.querySelectorAll('.bt-agent-msg'))
                     .reduce((n,b)=> n + (((b.innerText||'').match(/\\[w2-/g)||[]).length), 0))()
        """))

        # ── 1. Initial state ──────────────────────────────────────────────
        @test follow_mode() == true
        @test unread() == 0
        @test pill_visible() == false

        # ── 2. Streaming while at the bottom doesn't show the pill ─────────
        TK.send_message(s, "stream a long reply")
        # Wait until the pane is actually scrollable (content overflows).
        TK.wait_for(s, "pane became scrollable", """
            (() => { const c = document.querySelector('.bt-messages');
                     return (c.scrollHeight - c.clientHeight) > 200; })()
        """; timeout = 25)
        sleep(1.0)
        # Still following, still at the bottom → no pill, nothing unread.
        @test follow_mode() == true
        @test pill_visible() == false
        @test unread() == 0

        # ── 3. User scroll-to-top disengages follow mode (pill still hidden)
        # We do this during the quiet window (after wave 1, before wave 2), so
        # there is genuinely nothing new yet — the pill must stay hidden.
        TK.wait_for(s, "wave 1 fully streamed",
            "document.querySelector('.bt-messages').innerText.indexOf('[w1-$W1_N]') !== -1"; timeout = 25)
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: -100}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true; })()""")
        sleep(0.4)
        @test follow_mode() == false
        @test pill_visible() == false   # nothing new yet during the quiet window

        # ── 4. New content while disengaged surfaces the pill ─────────────
        # Wave 2 starts after the quiet delay; the chunks land while we're
        # scrolled away, so the pill must appear and unreadCount must climb.
        TK.wait_for(s, "pill becomes visible on new content",
            "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible') !== null"; timeout = 20)
        @test follow_mode() == false      # new chunks didn't yank us back
        @test Int(unread()) > 0

        # ── 5. Clicking the pill jumps to bottom, hides pill, re-engages ──
        TK.eval_js(s, "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible').click()")
        @test TK.wait_for(s, "followMode true after pill click",
            "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4)
        @test TK.wait_for(s, "pill hidden after click", """
            (() => { const el = document.querySelector('.bt-new-msg-pill');
                     return !el || !el.classList.contains('bt-new-msg-pill-visible'); })()
        """; timeout = 4)
        @test unread() == 0
        # Scroll settled at the bottom (rAF can be throttled offscreen → poll).
        @test TK.wait_for(s, "scroll gap < 60 after pill click",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 60; })()";
            timeout = 4)

        # ── 6. Scrolling manually back to the bottom auto-re-engages ──────
        # First disengage again.
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: -100}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true; })()""")
        sleep(0.4)
        @test follow_mode() == false
        # Now scroll back down to the very bottom (within AT_BOTTOM_PX).
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: 100}));
            c.scrollTop = c.scrollHeight - c.clientHeight;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true; })()""")
        @test TK.wait_for(s, "followMode re-engaged by scrolling to bottom",
            "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4)
        @test pill_visible() == false

        TK.screenshot(s, joinpath(tempdir(), "bt-follow-pill-final.png"))

        # ── 7. No JS errors during the whole exercise ─────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
