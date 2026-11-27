# A request to a worker that gets no answer. It used to fail after a fixed 5 s
# with "worker may be offline or stuck", also for a worker that was connected and
# answering, only behind a link busy with a 114 MB history replay (a laptop,
# 11-24). Now the wait grows by two of the link's ping round trips, and the error
# says what was true: not connected, a slow connection, or no answer although the
# connection is fine. Against a real worker over a real websocket.
@testitem "unit:rpc_timeout" tags = [:unit] begin
    import BonitoAgents, BonitoWorker
    const BA = BonitoAgents
    const BW = BonitoWorker
    const WL = BA.WorkerLink

    dir = mktempdir()
    state = BA.serve(; host = "127.0.0.1", port = 0, scan_on_connect = false,
                     state_dir = mkpath(joinpath(dir, "state")),
                     working_dir = mkpath(joinpath(dir, "working")))
    wid = "rpc-timeout-test"
    @test occursin("not connected", BA.rpc_timeout_detail(state, wid, 5.0))
    @test BA.link_rtt(state, wid) == 0.0

    worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
        worker_id = wid, name = wid,
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
        projects_root = mkpath(joinpath(dir, "projects"))))
    task = Threads.@spawn BW.serve(worker; retry_delay = 0.2)
    try
        @test timedwait(() -> BA.worker_connected(state, wid), 30.0) === :ok
        link = BA.worker_link(state, wid)
        # No pings from here on, so no pong replaces the round trip set below.
        WL.set_liveness!(link; ping_interval = 3600.0, ping_deadline = 7200.0)
        set_rtt!(s) = lock(() -> (link.ping_rtt = s), link.lock)

        set_rtt!(0.01)
        @test BA.rpc_timeout_detail(state, wid, 5.0) ==
              "no answer within 5.0 s, although the worker is connected and its connection is fast"
        set_rtt!(3.2)
        @test BA.rpc_timeout_detail(state, wid, 11.4) ==
              "no answer within 11.4 s; its connection is slow (a ping takes 3.2 s)"
        # A request nobody answers waits its budget plus two round trips.
        set_rtt!(1.0)
        rid, ch = BA.register_rpc!(state)
        t0 = time()
        r = @test_throws BA.WorkerUnreachableError BA.take_pending!(state, ch, rid, 0.5, "probe on '$wid'"; worker_id = wid)
        @test 2.4 <= time() - t0 < 6.0
        @test sprint(showerror, r.value) ==
              "probe on '$wid' no answer within 2.5 s, although the worker is connected and its connection is fast"
        # No worker named: the old budget and wording.
        rid2, ch2 = BA.register_rpc!(state)
        t0 = time()
        r2 = @test_throws BA.WorkerUnreachableError BA.take_pending!(state, ch2, rid2, 0.3, "probe")
        @test time() - t0 < 2.0
        @test occursin("may be offline or stuck", sprint(showerror, r2.value))
    finally
        close(worker)
        wait(task)
        BA.close_worker_links!(state)
        close(state.srv)
    end
end
