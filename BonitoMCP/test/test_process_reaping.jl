# Processes spawned by eval'd code (`run(...)`, a test suite, a server) are not
# tracked or reaped by Julia — killing the worker used to leave them running
# forever. The worker leads its own process group, which kill_session! kills as a
# unit; the kernel keeps that group intact after the leader dies, so it works even
# when the worker was SIGKILLed and no handler of ours could run.

using Test
using BonitoMCP
const M = BonitoMCP

alive(pid) = success(pipeline(ignorestatus(`kill -0 $pid`), stderr = devnull))

# The grandchild outlives its parent unless something reaps it, so give it a long
# sleep and kill it in `finally` — a failing test must not leak the process it
# was written to catch.
spawn_grandchild(s) = Int(M.Malt.remote_eval_fetch(s.worker,
    quote Int(getpid(run(`sleep 300`; wait = false))) end))

hard_kill(pid) = ccall(:kill, Cint, (Cint, Cint), pid, 9)

if !Sys.isunix()
    @info "process-group reaping test is unix-only; skipping"
else
    @testset "kill_session! reaps what the eval spawned" begin
        s = M.JuliaSession(nothing; is_temp = true)
        M.start!(s)
        child = spawn_grandchild(s)
        try
            # Malt spawns detached, so the worker already leads its own group.
            @test s.pgid == M.worker_pid(s)
            @test s.pgid != 0
            @test alive(child)

            M.kill_session!(s)
            @test timedwait(() -> !alive(child), 10.0) === :ok
        finally
            hard_kill(child)
        end
    end

    @testset "reaping survives a SIGKILLed worker (no handler can run)" begin
        s = M.JuliaSession(nothing; is_temp = true)
        M.start!(s)
        child = spawn_grandchild(s)
        wpid  = M.worker_pid(s)
        try
            hard_kill(wpid)                       # no atexit, no finalizer, nothing
            @test timedwait(() -> !alive(wpid), 10.0) === :ok
            @test alive(child)                    # orphaned, still running

            M.kill_session!(s)                    # is_alive is false — reap anyway
            @test timedwait(() -> !alive(child), 10.0) === :ok
        finally
            hard_kill(child)
        end
    end

    @testset "reap_process_tree never signals our own group" begin
        own = Int(ccall(:getpgid, Cint, (Cint,), 0))
        # If the guard is missing this kills the test runner outright, which is
        # exactly the failure it exists to prevent.
        M.reap_process_tree(own)
        @test alive(getpid())
        M.reap_process_tree(0)                    # "no group" is a no-op
        @test alive(getpid())
    end
end
