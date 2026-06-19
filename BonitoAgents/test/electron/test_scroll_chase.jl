# Scroll-to-bottom regression tests, migrated onto the TestKit harness (real
# dev_server, real worker subprocess, real ACP wire, real Electron browser; only
# the agent's behaviour is faked, via the `agent=` callback).
#
# User reports the original bugs guarded against: "sometimes I can't see the last
# message nor the message field; on desktop sometimes it doesn't scroll to the
# newest message; one time I thought the chat was hanging when the last message
# just didn't scroll into view." Four distinct virtual-scroll auto-follow bugs:
#
#   1. bt-busy height transition (0↔28px / 150ms) shrinks the chat's
#      clientHeight but doesn't re-scroll, so the last bubble slides below the
#      fold during agent turns.
#   2. scrollToBottom() read pre-layout scrollHeight after a textContent write,
#      ending short of the actual bottom during streaming.
#   3. atBottom() threshold was 60px — one 80-100px bubble flipped
#      wasAtBottom=false, disengaging chase.
#   4. the scroll listener treated programmatic scrolls (our own
#      scrollToBottom) as user intent, racing the user-scroll handler.
#
# The fix: ResizeObserver-driven re-scroll, rAF-batched scroll-to-bottom,
# generous threshold, user-vs-programmatic scroll discrimination.
#
# MIGRATION NOTES vs the legacy MockTransport version:
#   - Instead of poking `chat_emit` with synthetic chunk dicts, we drive the
#     REAL agent stream: one long held-open turn that floods the viewport with
#     `text(...)` chunks. The chunks travel the full ACP path and render real
#     DOM, so the ResizeObserver-driven chase is exercised end to end.
#   - `__bt_chat` is the chat instance devtools hook; we read followMode and
#     call dispatch / setFollowMode / _queueScrollToBottom off it exactly as the
#     legacy test did (all still present in assets/bonitoagents.js).
#   - Chunk counts are scaled to keep a held-open turn responsive (a long line
#     per chunk overflows a 900x600 window). The scroll invariants (at-bottom,
#     last-bubble-visible, disengage-on-scroll-up, resize keeps tail) are NOT
#     weakened — only synchronised on real DOM state, never wall-clock sleeps.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, delay, end_turn

# A long line per chunk so the pane overflows in a small window. Wave 1 fills the
# viewport; the quiet delay holds the turn open so the test can assert against a
# live (still-streaming) chat; wave 2 is the burst that must stay pinned.
const LONG = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod. "
const W1_N = 24
const QUIET_MS = 9000
const W2_N = 30

@testset "scroll chase — at-bottom, busy transition, burst, disengage, mobile resize" begin
    s = TK.dev_server(; agent = msg -> begin
        evs = Any[]
        for i in 1:W1_N
            push!(evs, text("[w1-$i] " * LONG)); push!(evs, delay(80))
        end
        # Hold the turn open so the test can exercise busy transitions / scroll
        # while the chat is genuinely live, then fire the chunk burst (wave 2).
        push!(evs, delay(QUIET_MS))
        for i in 1:W2_N
            push!(evs, text("[w2-$i] " * LONG)); push!(evs, delay(60))
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
        sleep(0.8)  # initial scroll-to-bottom + ResizeObserver settle

        follow_mode() = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.followMode")
        scroll_state() = TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            return { top:    Math.round(c.scrollTop),
                     height: Math.round(c.scrollHeight),
                     client: Math.round(c.clientHeight),
                     gap:    Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) };
        })()""")
        gap() = Int(scroll_state()["gap"])
        last_in_view() = TK.eval_js(s, """(() => {
            const bubbles = document.querySelectorAll('.bt-agent-msg');
            if (bubbles.length === 0) return false;
            const last = bubbles[bubbles.length - 1];
            const r = last.getBoundingClientRect();
            const c = document.querySelector('.bt-messages').getBoundingClientRect();
            return r.bottom <= c.bottom + 50; })()""")
        input_visible() = TK.eval_js(s, """(() => {
            const input = document.querySelector('.bt-text-input');
            if (!input) return false;
            const r = input.getBoundingClientRect();
            return r.bottom > 0 && r.top < window.innerHeight; })()""")

        # ── 1. Initial mount lands at bottom ──────────────────────────────────
        # Empty chat: clientHeight is set, gap is ~0. followMode true on mount.
        @test follow_mode() == true
        @test gap() < 50

        # ── Stream wave 1 so the pane overflows and becomes scrollable ────────
        TK.send_message(s, "stream a long reply")
        TK.wait_for(s, "pane became scrollable", """
            (() => { const c = document.querySelector('.bt-messages');
                     return (c.scrollHeight - c.clientHeight) > 200; })()
        """; timeout = 25)
        sleep(0.6)
        s0 = scroll_state()
        @test Int(s0["height"]) > Int(s0["client"])   # content overflows
        # Mid-stream: offscreen rAF is throttled to ~1 Hz, so the chase can lag a
        # frame behind the latest growth — poll for the at-bottom band (<200, the
        # same threshold the legacy test used for all in-flight at-bottom checks).
        @test TK.wait_for(s, "pinned at bottom while wave 1 streams",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()";
            timeout = 6)

        # ── Bug 1: bt-busy height transition keeps us at bottom ───────────────
        # The CSS transition takes 150ms; the ResizeObserver-driven re-scroll
        # must keep the tail anchored across it.
        TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.dispatch({type: 'busy_start'})")
        @test TK.wait_for(s, "at bottom after busy_start",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()";
            timeout = 4)
        TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.dispatch({type: 'busy_end'})")
        @test TK.wait_for(s, "at bottom after busy_end",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()";
            timeout = 4)

        # ── Bug 2+3: streaming the burst keeps us pinned at the tail ──────────
        # Wait out the quiet window, then wave 2 floods chunks; the chase must
        # ride every growth frame and keep the last bubble in view.
        TK.wait_for(s, "wave 1 fully streamed",
            "document.querySelector('.bt-messages').innerText.indexOf('[w1-$W1_N]') !== -1"; timeout = 25)
        TK.wait_for(s, "burst (wave 2) started",
            "document.querySelector('.bt-messages').innerText.indexOf('[w2-1]') !== -1"; timeout = 20)
        TK.wait_for(s, "burst fully streamed",
            "document.querySelector('.bt-messages').innerText.indexOf('[w2-$W2_N]') !== -1"; timeout = 20)
        @test TK.wait_for(s, "scroll settled at bottom after burst",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()";
            timeout = 6)
        @test last_in_view()

        # ── Bug 4: scrolling far up disengages chase ──────────────────────────
        # Synthetic wheel before the programmatic scrollTop write so the chat
        # marks this as user-initiated (otherwise it's classed as a layout
        # shift and re-anchors). Headless Electron throttles natural scroll
        # events to ~1 Hz, so we dispatch a synthetic 'scroll' too.
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: -100}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true; })()""")
        @test TK.wait_for(s, "followMode false after scroll-to-top",
            "document.querySelector('.bt-messages').__bt_chat.followMode === false"; timeout = 4)

        # ── Mobile keyboard / viewport shrink keeps tail + input visible ──────
        TK.set_window_size(s, 480, 800)
        sleep(0.3)
        # Re-engage chase via the public path the pill-click uses.
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.__bt_chat.setFollowMode(true);
            c.__bt_chat._queueScrollToBottom();
            return true; })()""")
        @test TK.wait_for(s, "re-engaged (followMode true)",
            "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4)

        # Soft-keyboard slide-in: shrink the viewport ~half. onViewportResize +
        # ResizeObserver must keep the input + last bubble visible.
        TK.set_window_size(s, 480, 400)
        sleep(0.5)
        @test input_visible()
        @test TK.wait_for(s, "tail in view after keyboard up",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()";
            timeout = 4)

        # Close keyboard — restore full height; tail must remain anchored.
        TK.set_window_size(s, 480, 800)
        sleep(0.5)
        @test input_visible()
        @test TK.wait_for(s, "tail in view after keyboard close",
            "(() => { const c = document.querySelector('.bt-messages'); return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 200; })()";
            timeout = 4)

        # Restore desktop viewport before the final screenshot.
        TK.set_window_size(s, 1280, 800)
        sleep(0.3)
        TK.screenshot(s, joinpath(tempdir(), "bt-scroll-chase-final.png"))

        # ── No JS errors throughout ───────────────────────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
