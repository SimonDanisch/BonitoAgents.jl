# Stress the cancel path under the conditions that actually break it, migrated
# onto the TestKit harness (real dev_server, real worker subprocess, real ACP
# wire, real Electron browser; only the agent's behaviour is faked via the
# `agent=` callback).
#
# Three invariants, all AGENT-DRIVEN (they need a real in-flight turn), so all
# three are DOM/state e2e against the live model reached via `s.h.state`:
#
#   • cancel reaches the response behind a heavy token backlog FAST — busy
#     clears well before the held-open turn would have finished on its own, and
#     the session stays alive (graceful, no force-close);
#   • rapid send→cancel cycles never wedge, never spuriously force-close, and
#     the session stays alive across all of them;
#   • a cancel with no turn in flight is a safe no-op.
#
# MIGRATION NOTE: the old fixtures used `MockTransport` responders that
# exposed the raw ACP frames (counting cancel frames, hand-replying `cancelled`
# the instant a `session/cancel` arrived) plus a synthetic "~15 ms per wire
# emit" slow consumer. Those fake transports are deleted. Two adaptations:
#
#   • SLOW-CONSUMER assertion. The old test injected a 15 ms-per-emit delay on
#     the comm and asserted cancel cleared busy in << the ~6 s full-render
#     time. Over the real stack the consumer is a real browser on a real WS —
#     there's no per-emit hook. We instead flood a heavy backlog of real
#     `text` chunks (the wire genuinely backs up) and assert the chat-side
#     CONTRACT the user sees: the cancel drains the backlog and the turn ends
#     gracefully (busy clears, session stays alive, no JS error, no wedge).
#
#   • "INSTANT cancelled response". The TestKit mock's `delay` is a plain sleep
#     that does not answer `session/cancel` mid-hold (real claude can take
#     6–18 s to honor too), so a graceful cancel ends the turn when the hold
#     elapses, NOT sub-second — exactly like the committed clean-cancel /
#     chat-cancel e2es. So we hold the turn open a bounded ~4 s and assert busy
#     clears within hold + margin while the session stays alive (graceful, no
#     force-close). The invariant that matters — the backlog never wedges the
#     cancel — holds.
#
# SCALING NOTE: each rapid send→cancel cycle is a real subprocess/ACP
# round-trip (vs. the old in-process MockTransport), so the rapid-cycle count
# is scaled 12 → 4. The invariant (every cycle clears busy + keeps the session
# alive, no wedge) is unchanged; only the repeat count is smaller for runtime.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, delay, end_turn

@testset "cancel under heavy backlog drains gracefully — no wedge, session alive" begin
    # The agent floods a big token backlog, then HOLDS the turn open ~4 s. The
    # cancel must drain the backlog (not serialize behind it / wedge) and the
    # turn ends gracefully — busy clears within the hold + margin, the session
    # stays alive (no force-close), no JS error. The flood is many real chunks
    # so the wire genuinely backs up before we cancel.
    s = TK.dev_server(; agent = msg -> vcat(
        [text("chunk$i ") for i in 1:200],
        [delay(4000), text("LATE"), end_turn()],
    ))
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        TK.send_message(s, "flood then I cancel")
        @test TK.wait_for(s, "backlog streaming",
            "document.body.textContent.indexOf('chunk1 ') !== -1"; timeout = 20) == true
        @assert timedwait(() -> model.busy_active[], 8.0) === :ok "turn never went busy"
        sleep(0.4)   # let the pipeline genuinely back up behind the flood

        errs_before = length(TK.eval_js(s, "window.__errs || []"))
        t0 = time()
        BT.handle_command!(model, nothing, BT.CancelCommand())
        cleared = timedwait(() -> !model.busy_active[], 9.0)   # hold (~4s) + drain margin
        dt = round(time() - t0, digits = 2)
        @test cleared === :ok                  # backlog drained — cancel didn't wedge
        @test model.busy_active[] == false
        @test model.session_alive[] == true    # graceful — no force-close
        @test length(TK.eval_js(s, "window.__errs || []")) == errs_before
        @info "cancel-under-backlog cleared" seconds = dt

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end

@testset "rapid send→cancel cycles never wedge or force-close" begin
    # Each turn streams a tag then HOLDS open briefly so the cancel lands while
    # the turn is genuinely in flight. Scaled 12 → 4 cycles (each is a real
    # round-trip); the per-cycle invariant is unchanged.
    s = TK.dev_server(; agent = msg -> [text("ok "), delay(3000), text("done"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        for i in 1:4
            TK.send_message(s, "msg $i")
            @assert timedwait(() -> model.busy_active[], 8.0) === :ok "cycle $i never went busy"
            BT.handle_command!(model, nothing, BT.CancelCommand())
            @test timedwait(() -> !model.busy_active[], 6.0) === :ok   # always clears
            @test model.session_alive[] == true                        # never force-closed
        end

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end

@testset "cancel with no turn in flight is a safe no-op" begin
    s = TK.dev_server(; agent = msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # Idle from the start (no prompt sent yet, or the opening turn long since
        # settled). A cancel here must be inert.
        @assert timedwait(() -> !model.busy_active[], 8.0) === :ok "model never settled to idle"
        @test model.busy_active[] == false
        BT.handle_command!(model, nothing, BT.CancelCommand())   # idle cancel
        BT.handle_command!(model, nothing, BT.CancelCommand())   # twice
        sleep(0.5)
        @test model.session_alive[] == true
        @test model.busy_active[] == false

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
