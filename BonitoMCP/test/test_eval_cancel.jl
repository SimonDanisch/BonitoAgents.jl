# An MCP `notifications/cancelled` must actually STOP an in-flight eval, not leave
# it orphaned. Arbitrary user code has no cooperative stop, so the only lever is
# `Malt.interrupt` (SIGINT) — used deliberately by `handle_cancelled!`, with a
# kill-worker fallback for code that swallows InterruptException. Here we assert
# the common case: a running `sleep` is interrupted, the session becomes reusable,
# and the worker survives (a clean interrupt doesn't crash it).

using Test
using BonitoMCP
const M = BonitoMCP

@testset "MCP cancel interrupts the in-flight eval (stops it)" begin
    m   = M.manager()
    s   = M.JuliaSession(nothing; is_temp = true)
    key = "test-cancel-" * string(rand(UInt32))
    lock(m.lock) do; m.sessions[key] = s; end
    try
        r1 = M.execute(s, "sleep(60); 42"; timeout = 4.0)
        @test r1.status == :running
        @test s.in_flight !== nothing
        @test M.is_alive(s)

        # This is what an MCP `notifications/cancelled` triggers: interrupt the
        # in-flight eval(s) in the manager.
        M.handle_cancelled!(Dict("params" => Dict("requestId" => 1)))

        # The sleep takes the InterruptException → the eval task dies promptly.
        @test timedwait(() -> s.in_flight === nothing || istaskdone(s.in_flight),
                        15.0) === :ok
        @test M.is_alive(s)        # a clean interrupt does NOT crash the worker

        # Session is reusable: draining returns the (interrupted) result, clears
        # in_flight, and a fresh eval runs.
        r2 = M.continue_eval!(s; timeout = 5.0)
        @test r2.status == :completed
        @test s.in_flight === nothing
        r3 = M.execute(s, "1 + 1"; timeout = 10.0)
        @test r3.status == :completed
    finally
        lock(m.lock) do; delete!(m.sessions, key); end
        M.kill_session!(s)
    end
end

# A bare SIGINT is delivered to whichever task the worker happens to be running.
# Every session start!s a 4Hz stdout flusher, so the flusher kept taking the
# exception (its `catch` rethrows anything that isn't an IO error) and dying
# while the eval slept on — cancel and bt_julia_interrupt both silently did
# nothing. `request_interrupt!` throws into the tracked eval task instead, and
# only falls back to a signal when the worker is too wedged to answer.
@testset "interrupt targets the eval task, not whatever task is running" begin
    # `sleep` and blocking IO WAIT, so the throw reaches them directly; a tight
    # loop never yields to Malt's message loop, so it must escalate to SIGINT.
    for (label, code, want) in (("sleep",       "sleep(60); 42",                :targeted),
                                ("blocking IO", "read(`sleep 60`, String)",     :targeted),
                                ("tight loop",  "x = 0; while true; x += 1; end", :signal))
        @testset "$label" begin
            s = M.JuliaSession(nothing; is_temp = true)
            try
                @test M.execute(s, code; timeout = 3.0).status == :running
                @test M.request_interrupt!(s) === want
                @test timedwait(() -> s.in_flight === nothing || istaskdone(s.in_flight),
                                20.0) === :ok
                @test M.is_alive(s)        # interrupting must not cost the session
            finally
                M.kill_session!(s)
            end
        end
    end
end
