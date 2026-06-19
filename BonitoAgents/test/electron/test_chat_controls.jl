# Non-input chat controls, migrated onto the TestKit harness (real dev_server,
# real worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked, via the `agent=` callback).
#
#   - Stop button cancels an in-flight prompt (the click reaches Julia as a
#     CancelCommand without a JS error, and history is preserved).
#   - Sync button actually fires its handler — no `notify_observable is not a
#     function` JS error — and its label changes away from "Sync".
#   - Restart button flips to the dead/pulse state when session_alive goes
#     false, and recovers (session_alive back to true) when clicked.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, delay, end_turn

@testset "chat controls — stop / sync / restart" begin
    # A long-running turn: emit some text, then hold the turn open for ~3s via
    # `delay`, so the stop button is meaningful (the prompt is in-flight while we
    # click it). The mock honours cancel by simply running to completion (the
    # dispatcher stream is fire-and-forget), so after stop the stream drains and
    # the agent bubble stays in history.
    s = TK.dev_server(; agent = msg -> [
        text("streaming "),
        delay(3000),
        text("done"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # ── Stop button cancels an in-flight prompt ─────────────────────────
        TK.send_message(s, "go")
        # Streaming actually started: the agent bubble landed.
        TK.wait_for(s, "agent bubble appears",
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 10)
        # The turn is genuinely in-flight (the `delay` holds it open ~3s).
        @assert timedwait(() -> model.busy_active[], 5.0) === :ok "turn never went busy"

        errs_before = length(TK.eval_js(s, "window.__errs || []"))
        # The stop button is always in the DOM; the delegated capture-phase
        # handler posts `{type:'cancel'}` → CancelCommand on the Julia side.
        TK.click(s, ".bt-stop-btn")
        sleep(0.5)
        # The stop click must reach Julia cleanly — no JS error (this is where a
        # broken cancel wiring would throw in the renderer).
        @test length(TK.eval_js(s, "window.__errs || []")) == errs_before
        # Cancel doesn't wipe history: the agent bubble is still present.
        @test TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length") >= 1

        # Drain the rest of the stream so later sections don't race with it.
        @assert timedwait(() -> !model.busy_active[], 10.0) === :ok "turn never finished"

        # ── Sync button fires its handler (no notify_observable JS error) ────
        errs_before_sync = length(TK.eval_js(s, "window.__errs || []"))
        TK.click(s, ".bt-header-sync")
        # No new JS errors after the sync click (the regression this guards).
        sleep(0.5)
        @test length(TK.eval_js(s, "window.__errs || []")) == errs_before_sync
        # The label changes away from "Sync" (it moves through "starting…" /
        # progress / "✓ synced …" against the real worker).
        TK.wait_for(s, "sync label changed",
            "(document.querySelector('.bt-header-sync').innerText || '').trim() !== 'Sync'";
            timeout = 15)

        # ── Restart button: dead/pulse on session_alive=false, recovers on click
        @test TK.eval_js(s,
            "document.querySelector('.bt-header-restart-dead') === null") == true

        # Flip session_alive from Julia → the button gains the dead/pulse class.
        model.session_alive[] = false
        model.last_error[]    = "test-induced disconnect"
        TK.wait_for(s, "restart button flips to dead/pulse",
            "document.querySelector('.bt-header-restart-dead') !== null"; timeout = 5)

        # Click the (now-pulsing) restart button. The handler calls
        # restart_chat_session! which rebuilds the client and sets session_alive
        # back to true.
        TK.click(s, ".bt-header-restart-dead")
        TK.wait_for(s, "restart button returns to healthy",
            "document.querySelector('.bt-header-restart-dead') === null"; timeout = 30)
        @test model.session_alive[] == true

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-controls-final.png"))

        # No JS errors fired across the whole run.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
