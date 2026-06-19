# Re-mount preserves history, migrated onto the TestKit harness (real dev_server,
# real worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked via the `agent=` callback).
#
# Flow under test: send a prompt, get a real streamed response, navigate Home,
# navigate back to the project. The chat panes are KEPT ALIVE on navigation
# (display:none pane cache in unified_main) — so the same `.bt-app` node stays in
# the DOM; navigating away only flips visibility, and navigating back must show
# the SAME bubbles, no repaint/refetch losing history.
#
# Contract (unchanged from the legacy MockTransport test, re-expressed against
# the real stack):
#   - send a prompt → a user bubble + a streamed agent bubble land, busy clears
#   - Home → the dashboard becomes visible, the chat pane goes display:none
#     (kept alive, not destroyed)
#   - back to the project → the chat pane is visible again, model.msgs_store is
#     unchanged, and the SAME user/agent bubble counts are still in the DOM.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, end_turn

@testset "chat re-mount preserves history (kept-alive pane cache)" begin
    s = TK.dev_server(; agent = msg -> [
        text("first response"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        sleep(0.5)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # ── 1. Send + receive a turn ──────────────────────────────────────────
        TK.send_message(s, "first prompt")
        @test TK.wait_for(s, "user bubble",
            "document.querySelectorAll('.bt-user-msg').length >= 1"; timeout = 10) == true
        @test TK.wait_for(s, "agent bubble",
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 15) == true
        # Wait for the turn to fully finish (busy clears) so the bubbles are sealed.
        @assert timedwait(() -> !model.busy_active[], 15.0) === :ok "turn never finished"
        sleep(0.4)

        n_msgs_before  = lock(() -> length(model.msgs_store), model.lock)
        n_user_before  = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        n_agent_before = Int(TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length"))
        @test n_user_before  >= 1
        @test n_agent_before >= 1

        # ── 2. Navigate Home — dashboard shown, chat pane hidden (kept alive) ──
        TK.to_dashboard(s)
        @test TK.wait_for(s, "dashboard becomes visible", """
            (() => { const dash = document.querySelector('.bt-view-dash');
                     return dash !== null && dash.style.display !== 'none'; })()
        """; timeout = 5) == true
        @test TK.eval_js(s, """
            (() => { const panes = document.querySelectorAll('.bt-view-chats .bt-chatpane');
                     return Array.from(panes).every(p => p.style.display === 'none'); })()
        """) == true

        # ── 3. Navigate back — history is still there ─────────────────────────
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        @test TK.wait_for(s, "chat pane visible again", """
            (() => { const app = document.querySelector('.bt-app');
                     if (!app) return false;
                     const pane = app.closest('.bt-chatpane');
                     return pane === null || pane.style.display !== 'none'; })()
        """; timeout = 5) == true
        # Give the JS-side chat a moment to settle after re-show.
        sleep(0.6)

        # Julia-side store unchanged.
        @test lock(() -> length(model.msgs_store), model.lock) == n_msgs_before

        # The kept-alive pane keeps the SAME bubbles in the DOM (no repaint loss).
        @test TK.wait_for(s, "user bubbles still present",
            "document.querySelectorAll('.bt-user-msg').length >= $n_user_before"; timeout = 6) == true
        @test TK.wait_for(s, "agent bubbles still present",
            "document.querySelectorAll('.bt-agent-msg').length >= $n_agent_before"; timeout = 6) == true
        @test Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))  == n_user_before
        @test Int(TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length")) == n_agent_before

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-remount-final.png"))

        # ── 4. No JS errors during the whole exercise ─────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
