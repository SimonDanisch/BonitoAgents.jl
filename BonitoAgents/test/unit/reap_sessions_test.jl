# Worker-side session reaping (#33). The e2e zombie test can't isolate this:
# over healthy loopback the relay teardown reaps agents anyway — only a real
# network wedge (interface switch) leaves sessions orphaned, and that needs
# root to simulate. So the reap contract is pinned here directly: kill the
# agent process AND the session transport (a relay wedged in send holds
# ws.sendlock, so only the transport kill reaches it), and empty the registry.
@testitem "unit:reap_all_sessions" tags = [:unit] begin
    import BonitoWorker

    fake_ws(closed::Ref{Bool}) = (close_transport! = () -> (closed[] = true),)

    @testset "reap_all_sessions! kills procs, transports, and the registry" begin
        proc1 = run(`sleep 600`; wait = false)
        proc2 = run(`sleep 600`; wait = false)
        ws1_closed = Ref(false)
        lock(BonitoWorker._SESSION_PROCS_LOCK) do
            BonitoWorker._SESSION_PROCS["/tmp/reap-a"] = (proc = proc1, ws = fake_ws(ws1_closed))
            BonitoWorker._SESSION_PROCS["/tmp/reap-b"] = (proc = proc2, ws = nothing)  # pre-dial
        end
        BonitoWorker.reap_all_sessions!("test")
        @test timedwait(() -> !process_running(proc1), 10.0) == :ok
        @test timedwait(() -> !process_running(proc2), 10.0) == :ok
        @test ws1_closed[]
        @test isempty(lock(() -> copy(BonitoWorker._SESSION_PROCS),
                           BonitoWorker._SESSION_PROCS_LOCK))
    end

    @testset "close_session reaps the proc AND the wedged transport" begin
        proc = run(`sleep 600`; wait = false)
        ws_closed = Ref(false)
        lock(BonitoWorker._SESSION_PROCS_LOCK) do
            BonitoWorker._SESSION_PROCS["/tmp/reap-c"] = (proc = proc, ws = fake_ws(ws_closed))
        end
        BonitoWorker.handle_close_session(Dict("cwd" => "/tmp/reap-c"))
        @test timedwait(() -> !process_running(proc), 10.0) == :ok
        @test ws_closed[]
        # close_session does NOT deregister — the session's own finally owns
        # that (identity-checked, so a racing reopen is never mis-deleted).
        lock(BonitoWorker._SESSION_PROCS_LOCK) do
            delete!(BonitoWorker._SESSION_PROCS, "/tmp/reap-c")
        end
    end
end
