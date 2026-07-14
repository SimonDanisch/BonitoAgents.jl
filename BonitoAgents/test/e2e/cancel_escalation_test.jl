# Reliable-stop guarantee: a WEDGED agent that ignores `session/cancel` must
# still be killable — a deliberate re-cancel (after the agent's had its chance
# and is STILL busy) escalates to a force-close. Graceful cancel is covered by
# chat_cancel_test; THIS proves the escalation hammer.
#
# Own dev_server with an IGNORE-CANCEL mock (BT_MOCK_ACP_IGNORE_CANCEL) so the
# graceful cancel is swallowed and the turn stays live. Drives the SERVER path
# (no browser): `handle_command!` twice, with `conn.cancel_at` backdated past the
# 20 s escalate window so the test doesn't actually wait 20 s.
@testitem "e2e:cancel_escalation" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    TK = TestKit
    BA = TestKit.BT

    function poll_until(cond; timeout = 30.0, interval = 0.1)
        t0 = time()
        while time() - t0 < timeout
            cond() && return true
            sleep(interval)
        end
        return false
    end

    # A long stream the ignore-cancel mock keeps emitting despite `session/cancel`,
    # so the turn stays busy through the graceful cancel. (We cancel within a
    # couple seconds; the full ~60 s is just headroom so it never ends on its own.)
    function long_stream(_prompt)
        evs = Any[]
        for i in 1:600
            push!(evs, TK.text("chunk$(i) "))
            push!(evs, TK.delay(100))
        end
        push!(evs, TK.end_turn())
        return evs
    end

    server = TK.dev_server(; ignore_cancel = true, agent = long_stream)
    try
        state = server.h.state
        @test poll_until(() -> !isempty(state.workers[]); timeout = 30)
        wid = first(keys(state.workers[]))

        pres = BA.create_project_from_worker!(state, wid, mktempdir();
            name = "wedged", start_session = true)
        model = nothing
        @test poll_until(timeout = 30) do
            model = get(state.chat_models, pres.id, nothing)
            model !== nothing
        end

        @testset "re-cancel force-closes a wedged (ignore-cancel) agent" begin
            # Kick off a turn: streams the long story; the ignore-cancel mock won't
            # stop on `session/cancel`, so the turn stays busy.
            BA.send_message!(model, BA.UserMsg(model, "stream a long story"))
            @test poll_until(() -> model.busy_active[]; timeout = 30)
            c = BA.client(model.agent)
            @test c !== nothing

            # 1) Graceful cancel — SWALLOWED by the wedged agent; the turn stays busy.
            BA.handle_command!(model, nothing, BA.CancelCommand())
            @test poll_until(() -> (@atomic c.conn.cancel_at) > 0; timeout = 5)
            sleep(2.0)
            @test model.busy_active[]        # still busy: the cancel was ignored

            # 2) Backdate the first cancel past the 20 s escalate window, then
            #    re-cancel: agent's had its chance and is STILL busy → force-close.
            @atomic c.conn.cancel_at = time() - 21.0
            BA.handle_command!(model, nothing, BA.CancelCommand())

            # Force-close tears the connection down → the turn drain ends → busy
            # clears and the session is marked dead. (last_error races between the
            # escalate hint and the ConnectionClosed showerror, so we only assert
            # SOMETHING was surfaced, not its exact text.)
            @test poll_until(() -> !model.busy_active[]; timeout = 15)
            @test model.session_alive[] == false
            @test !isempty(model.last_error[])
        end
    finally
        close(server)
    end
end
