# Backgrounded / hidden tab still renders incoming messages, migrated onto the
# TestKit harness (real dev_server, real worker subprocess, real ACP wire, real
# Electron browser).
#
# Background: Chrome + Firefox pause `requestAnimationFrame` in backgrounded
# tabs (no callbacks fire). Earlier `appendNewMessage` queued its auto-scroll
# via rAF; while the tab was backgrounded, new messages went into
# `__bt_chat.cache` but never into the DOM, because (1) updateDOM had run with
# the *pre-scroll* visibleRange (which didn't include the new bottom bubble's
# index) and (2) the rAF that was supposed to scroll-to-bottom + re-update never
# fired. Re-focusing the tab fired the queued rAF and a pile of cached bubbles
# appeared at once ("I sent a message and 5 old replies appeared at once").
#
# Fix: `appendNewMessage` does a SYNCHRONOUS scrollToBottom()/refresh() instead
# of rAF batching — synchronous DOM/scroll writes work regardless of tab
# visibility. This test reproduces the stuck-rAF condition by forcing
# `_scrollQueued = true` / `_scrollRafId = -1` (the state a real backgrounded
# tab gets wedged in), then pushes fresh agent messages server-side via the
# REAL `BT.send!` path and asserts the new bubble lands in the DOM anyway —
# while the rAF queue is verified to still be stuck (proving the fix doesn't
# depend on rAF firing).
#
# The messages here aren't streamed by the agent callback — they're pushed
# directly through `BT.send!` (the same server-side entrypoint the ACP pipeline
# ends at) so the test can deterministically control the wedged-rAF window. The
# agent callback is therefore a no-op (we never send a prompt).

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: end_turn

# Seed `n` (UserMsg/AgentMsg) pairs straight into the store + re-broadcast the
# count so a re-opened client bootstraps from it (same approach as
# test_virtual_scroll — avoids streaming a slow history through the agent).
function seed_history!(model, n::Int)
    lock(model.lock) do
        for i in 1:n
            push!(model.msgs_store, BT.UserMsg("hi $i"))
            push!(model.msgs_store, BT.AgentMsg("agent-$i", "ok $i"))
        end
    end
    BT.chat_emit(model, Dict{String,Any}(
        "type" => "msgs.count", "n" => length(model.msgs_store)))
    return model
end

@testset "backgrounded-tab rAF pause: new bubble still lands in DOM" begin
    # No prompt is ever sent; the agent callback is irrelevant here.
    s = TK.dev_server(; agent = msg -> [end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 800)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # Seed some history so virtual-scroll is engaged (5 pairs = 10 msgs).
        seed_history!(model, 5)
        @test lock(() -> length(model.msgs_store), model.lock) == 10

        # Re-open the chat pane so a FRESH JS Chat instance bootstraps from the
        # latest count (totalCount == 10) through the real render path.
        TK.to_dashboard(s)
        sleep(0.4)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat re-mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        @test TK.wait_for(s, "history loaded",
            "document.querySelector('.bt-messages')?.__bt_chat?.totalCount === 10"; timeout = 10) == true

        # ── Force rAF into the "queued-but-never-fires" state ─────────────────
        # The exact condition a real backgrounded tab leaves the chat in. Cancel
        # any REAL chase rAF still in flight from the mount first: planting
        # `_scrollRafId = -1` over a live id leaves that callback scheduled, and
        # when it fires it clears `_scrollQueued` — the sentinel assert below
        # would then fail on a pure timing race.
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages').__bt_chat;
            c._cancelPendingScroll();
            c._scrollQueued = true;
            c._scrollRafId  = -1;
            return true; })()""")

        before_bubbles = Int(TK.eval_js(s,
            "document.querySelectorAll('.bt-agent-msg, .bt-user-msg').length"))
        before_total = Int(TK.eval_js(s,
            "document.querySelector('.bt-messages').__bt_chat.totalCount"))

        # Push 3 fresh agent messages server-side via the real send! path. With
        # the rAF stuck, the pre-fix code would never insert them into the DOM.
        for i in 1:3
            BT.send!(model, BT.AgentMsg("bg-test-$i",
                "background-tab message $i — should appear despite paused rAF"))
        end
        # Let the WS round-trip + synchronous render land.
        @test TK.wait_for(s, "totalCount climbed by 3",
            "document.querySelector('.bt-messages').__bt_chat.totalCount === $(before_total + 3)";
            timeout = 6) == true

        after_total = Int(TK.eval_js(s,
            "document.querySelector('.bt-messages').__bt_chat.totalCount"))
        after_bubbles = Int(TK.eval_js(s,
            "document.querySelectorAll('.bt-agent-msg, .bt-user-msg').length"))
        raf_state = TK.eval_js(s,
            "document.querySelector('.bt-messages').__bt_chat._scrollQueued")

        # totalCount went up by exactly 3.
        @test (after_total - before_total) == 3
        # The crux: bubbles in the DOM grew (the bug was bubbles staying cached
        # but not rendered). We don't require ALL 3 — virtual scroll may render
        # only some — but at least the bottom one must be there.
        @test after_bubbles > before_bubbles
        # rAF is STILL stuck — we never let it fire. So if the bubbles are in the
        # DOM, the SYNCHRONOUS code path put them there, not a fired rAF.
        @test raf_state === true

        # The last bubble's text should be the most recent push.
        last_text = String(TK.eval_js(s, """
            (() => { const b = document.querySelectorAll('.bt-agent-msg');
                     return b.length > 0 ? b[b.length - 1].innerText : ''; })()"""))
        @test occursin("background-tab message 3", last_text)

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-background-tab-final.png"))

        # No JS errors fired across the run.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
