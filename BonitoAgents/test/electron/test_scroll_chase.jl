# Scroll-to-bottom regression tests.
#
# User reports: "sometimes I can't see the last message nor the message
# field; on desktop sometimes it doesn't scroll to the newest message;
# one time I thought the chat was hanging when the last message just
# didn't scroll into view." Symptoms point at four distinct bugs in
# the virtual-scroll auto-follow logic (since fixed in the same commit
# this test ships with):
#
#   1. bt-busy height transition (0↔28px / 150ms) shrinks the chat's
#      clientHeight but doesn't re-scroll, so the last bubble slides
#      below the fold during agent turns.
#   2. scrollToBottom() used scrollTop = scrollHeight synchronously
#      after a textContent write — reads pre-layout scrollHeight, so
#      we end up short of the actual bottom during streaming.
#   3. atBottom() threshold was 60px — a single 80-100px message bubble
#      flips wasAtBottom=false, disengaging chase.
#   4. The scroll event listener treated all scroll events as user
#      intent, including the ones our own scrollToBottom triggers, so
#      programmatic scrolls would race with the user-scroll handler.
#
# These tests cover the fix: ResizeObserver-driven re-scroll, rAF-batched
# scroll-to-bottom, generous threshold, and user-vs-programmatic scroll
# discrimination via wheel/touch/keydown tracking.
using BonitoAgents
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

using JSON

state = TH.make_state(; n_workers = 1, n_projects = 1)
let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id     = proj.id,
                                  transport      = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
    # Seed a small history so virtual scroll has something to mount but
    # we still start "at bottom" with room to grow.
    TH.seed_chat_history!(model, 8)
end

ctx = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    p1_idx = TH.eval_js(ctx, """(() => {
        const items = document.querySelectorAll('.bt-side-item .bt-side-name');
        for (let i = 0; i < items.length; i++) if (items[i].innerText.split(' · ')[0] === 'Project1') return i;
        return -1; })()""")
    TH.eval_js(ctx, """document.querySelectorAll('.bt-side-item')[$p1_idx].click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null";
                        timeout = 15.0) "chat didn't mount"
    sleep(1.0)  # initial scroll-to-bottom + RO settle

    # Helper: read scroll state of the messages container.
    function scroll_state()
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            // Math.round throughout — Chromium can return fractional
            // pixel values for scrollHeight/clientHeight when subpixel
            // layout is in play; the Julia side compares against
            // integer thresholds with `Int(...)`, which would raise
            // InexactError on a Float64 with a non-zero fractional part.
            return {
                top:    Math.round(c.scrollTop),
                height: Math.round(c.scrollHeight),
                client: Math.round(c.clientHeight),
                gap:    Math.round(c.scrollHeight - c.scrollTop - c.clientHeight),
            };
        })()""")
    end

    TH.section("Initial mount lands at bottom") do
        s = scroll_state()
        record("scrollHeight grew past clientHeight",
               @TH.test_true (Int(s["height"]) > Int(s["client"])))
        record("gap below clientHeight < 50px (we're at bottom)",
               @TH.test_true (Int(s["gap"]) < 50))
    end

    # ── Bug 1: busy transition ─────────────────────────────────────────────
    TH.section("bt-busy height transition keeps us at bottom") do
        TH.eval_js(ctx, """(() => {
            document.querySelector('.bt-messages').__bt_chat.dispatch({type: 'busy_start'});
        })()""")
        # The CSS transition takes 150ms; wait through it + a frame.
        sleep(0.3)
        s = scroll_state()
        record("still at bottom after busy_start (was ≤200, now ≤200)",
               @TH.test_true (Int(s["gap"]) < 200))

        TH.eval_js(ctx, """(() => {
            document.querySelector('.bt-messages').__bt_chat.dispatch({type: 'busy_end'});
        })()""")
        sleep(0.3)
        s = scroll_state()
        record("still at bottom after busy_end",
               @TH.test_true (Int(s["gap"]) < 200))
    end

    # ── Bug 2: streaming chunks land at bottom every frame ───────────────
    TH.section("Streaming many chunks keeps us pinned at the tail") do
        chat = state.chat_models["p-1"]
        # Manually create a streaming agent message.
        push!(chat.msgs_store, BonitoAgents.AgentMsg("stream-1", ""))
        BonitoAgents.chat_emit(chat, Dict{String,Any}(
            "type" => "agent", "id" => "stream-1", "streaming" => true,
            "text" => "", "n" => length(chat.msgs_store)))
        sleep(0.2)

        # Fire a burst of chunks. Each chunk grows the bubble; the
        # ResizeObserver on the message node should ensure we re-scroll.
        for i in 1:30
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "chunk", "id" => "stream-1",
                "text" => "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "))
        end
        # Wait for the chase to settle rather than a fixed sleep. The chase
        # settles in ~200ms (measured), but the headless suite window throttles
        # rAF to ~1 Hz, so a fixed 0.5s sleep races the throttled chase ~50/50.
        # Polling the gap is the correct, non-flaky check.
        settled = TH.wait_for(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            return (c.scrollHeight - c.scrollTop - c.clientHeight) < 200;
        })()"""; timeout = 6.0)

        s = scroll_state()
        # The streaming bubble is now ~1.5KB of text — must have stayed
        # at the tail throughout, NOT lagged behind.
        record("scroll at bottom after burst of 30 chunks",
               @TH.test_true settled)

        # The last message bubble's bottom edge should be within the viewport.
        last_in_view = TH.eval_js(ctx, """(() => {
            const bubbles = document.querySelectorAll('.bt-agent-msg');
            if (bubbles.length === 0) return false;
            const last = bubbles[bubbles.length - 1];
            const r = last.getBoundingClientRect();
            const c = document.querySelector('.bt-messages').getBoundingClientRect();
            // The last bubble's bottom should be at or above the
            // container's bottom (visible).
            return r.bottom <= c.bottom + 50;
        })()""")
        record("last bubble visible in viewport", @TH.test_true last_in_view)
    end

    # ── Scrolling up disengages chase ──────────────────────────────────
    TH.section("Scrolling far up disengages chase") do
        # Synthetic 'scroll' dispatch alongside the programmatic
        # scrollTop write — Electron throttles natural scroll events
        # to ~1 Hz when the window is hidden, so the chat's scroll
        # handler won't run in time off the natural event alone.
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            // Simulate a wheel event before the scrollTop write so the
            // chat marks this as user-initiated. Otherwise the chat's
            // scroll handler treats it as a layout shift and re-anchors.
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        sleep(0.3)
        follow = TH.eval_js(ctx, """
            document.querySelector('.bt-messages').__bt_chat.followMode
        """)
        record("followMode is false after scrolling to top",
               @TH.test_eq follow false)
    end

    # ── Mobile keyboard / viewport shrink ──────────────────────────────────
    # Re-engage chase, then simulate the soft keyboard popping up by
    # shrinking the viewport. The chat must keep the input field +
    # last message visible across the resize.
    TH.section("Mobile viewport shrink (soft-keyboard sim) keeps tail visible") do
        # Mobile-ish baseline first.
        TH.set_window_size(ctx, 480, 800)
        sleep(0.3)
        chat = state.chat_models["p-1"]
        # Re-engage chase: any new message arriving while followMode is
        # false won't auto-scroll, so the previous "scroll to top" test
        # disengaged us. Use the public setFollowMode helper so we go
        # through the same path the pill-click does.
        TH.eval_js(ctx, """(() => {
            const c = document.querySelector('.bt-messages');
            c.__bt_chat.setFollowMode(true);
            c.__bt_chat._queueScrollToBottom();
        })()""")
        sleep(0.3)
        for i in 1:5
            BonitoAgents.chat_emit(chat, Dict{String,Any}(
                "type" => "chunk", "id" => "stream-1",
                "text" => "Tail content $i. "))
        end
        sleep(0.4)

        # Now shrink the viewport ~half — simulates iOS soft keyboard.
        TH.set_window_size(ctx, 480, 400)
        sleep(0.5)   # let onViewportResize + ResizeObserver fire + flush

        # Verify the input field is still visible (not pushed off-screen
        # by the streaming content).
        input_visible = TH.eval_js(ctx, """(() => {
            const input = document.querySelector('.bt-text-input');
            if (!input) return false;
            const r = input.getBoundingClientRect();
            return r.bottom > 0 && r.top < window.innerHeight;
        })()""")
        record("input field still visible after viewport shrink",
               @TH.test_true input_visible)

        # Verify the last agent bubble is within the messages viewport.
        last_in_messages = TH.eval_js(ctx, """(() => {
            const bubbles = document.querySelectorAll('.bt-agent-msg');
            if (bubbles.length === 0) return false;
            const last = bubbles[bubbles.length - 1];
            const lr = last.getBoundingClientRect();
            const cr = document.querySelector('.bt-messages').getBoundingClientRect();
            // Allow a generous tolerance for sub-pixel + threshold.
            return lr.bottom <= cr.bottom + 50 && lr.bottom >= cr.top;
        })()""")
        record("last agent bubble still in the messages viewport",
               @TH.test_true last_in_messages)

        # Now "close keyboard" — restore full height.
        TH.set_window_size(ctx, 480, 800)
        sleep(0.5)
        last_in_messages_after = TH.eval_js(ctx, """(() => {
            const bubbles = document.querySelectorAll('.bt-agent-msg');
            if (bubbles.length === 0) return false;
            const last = bubbles[bubbles.length - 1];
            const lr = last.getBoundingClientRect();
            const cr = document.querySelector('.bt-messages').getBoundingClientRect();
            return lr.bottom <= cr.bottom + 50 && lr.bottom >= cr.top;
        })()""")
        record("last bubble still visible after viewport restore",
               @TH.test_true last_in_messages_after)
    end

    # Restore desktop viewport before final screenshot so the saved PNG
    # isn't a mobile snapshot.
    TH.set_window_size(ctx, 1280, 800)
    sleep(0.3)

    # ── No JS errors throughout ──────────────────────────────────────────
    TH.section("No JS errors in console") do
        errs = TH.js_errors(ctx)
        record("zero JS errors during scroll-chase exercise",
               @TH.test_eq length(errs) 0)
    end

    TH.emit_screenshot(ctx; label = "scroll-chase final")

finally
    TH.report!("Tier 2g — scroll chase", results)
    TH.shutdown(ctx)
end
