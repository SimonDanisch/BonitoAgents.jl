# Worker-side reaping. A worker reaps everything it runs for the server when its
# link resets or dies, and before an immediate update: the agent processes, the
# eval hosts, and the agents' channels (aborted, so the server's side of each
# session ends too). A merely DETACHED link reaps nothing: that is the point of
# the link, and the in-process resume test covers it.
@testitem "unit:reap_all_sessions" tags = [:unit] begin
    import BonitoWorker, WorkerLink
    using HTTP: WebSockets
    const BW = BonitoWorker

    new_worker() = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:1", secret = "s",
        worker_id = "reap-test", name = "reap-test", mcp_command = "julia",
        mcp_arguments = String[], projects_root = mktempdir(), agent_bin = ""))

    # A session as `run_agent_session` registers it; the channel is opened on
    # the (never connected) link, which is all reaping needs of it.
    function add_session!(w, cwd)
        proc = open(`sleep 600`, "r+")
        ch = WorkerLink.open_channel(w.link, UInt8[])
        lock(() -> (w.sessions[ch] = BW.AgentSession(proc, "p-" * basename(cwd), cwd)), w.lock)
        return proc, ch
    end

    @testset "reap! kills agents and eval hosts, aborts the channels, empties the registry" begin
        w = new_worker()
        proc1, ch1 = add_session!(w, "/tmp/reap-a")
        proc2, ch2 = add_session!(w, "/tmp/reap-b")
        host = open(`sleep 600`, "r")
        lock(() -> (w.eval_hosts["p-host"] = host), w.lock)
        @test !BW.worker_idle(w)

        BW.reap!(w, "test")
        @test timedwait(() -> !process_running(proc1) && !process_running(proc2) &&
                              !process_running(host), 10.0) == :ok
        @test WebSockets.isclosed(ch1) && WebSockets.isclosed(ch2)
        err = try WebSockets.receive(ch1); nothing catch e; e end
        @test err isa WebSockets.WebSocketError && occursin("test", sprint(showerror, err))
        @test BW.worker_idle(w)
        close(w)
    end

    @testset "a dead link reaps; closing the worker kills the link" begin
        w = new_worker()
        proc, ch = add_session!(w, "/tmp/reap-c")
        close(w)
        @test WorkerLink.state(w.link) === :dead
        @test timedwait(() -> !process_running(proc), 10.0) == :ok
        @test WebSockets.isclosed(ch)
        @test BW.worker_idle(w)
    end
end
