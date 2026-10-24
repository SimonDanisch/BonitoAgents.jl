# Scanning a worker's agent sessions, against a real worker over a real
# websocket. Opening a chat refreshes the scan, and it used to be the full one:
# every installed agent started to list its sessions (8 s here, MiMo alone hits
# its limit), once per chat opened, so three chats opened together were three
# full scans at once and none came back within the server's 15 s. Now opening a
# chat reads the session files alone, and callers share a scan that is running.
@testitem "unit:session_scan" tags = [:unit] begin
    import BonitoAgents, BonitoWorker
    const BA = BonitoAgents
    const BW = BonitoWorker
    using Test

    dir = mktempdir()
    state = BA.serve(; host = "127.0.0.1", port = 0, scan_on_connect = false,
                     state_dir = mkpath(joinpath(dir, "state")),
                     working_dir = mkpath(joinpath(dir, "working")))
    wid = "scan-test"
    worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
        worker_id = wid, name = wid,
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
        projects_root = mkpath(joinpath(dir, "projects"))))
    task = Threads.@spawn BW.serve(worker; retry_delay = 0.2)
    try
        @test timedwait(() -> BA.worker_connected(state, wid), 30.0) === :ok

        # What a full scan found earlier: one agent's session, one from the files.
        row(sid; kw...) = Dict{String,Any}("session_id" => sid, "path" => dir, "kind" => "session",
                                           (String(k) => v for (k, v) in kw)...)
        state.discovered[][wid] = [row("kimi-1"; provider = "KimiCode"), row("file-gone")]

        @testset "the session files alone keep the agents' sessions" begin
            rows = BA.scan_and_store!(state, wid; agents = false)
            sids = [r["session_id"] for r in rows if haskey(r, "session_id")]
            @test "kimi-1" in sids               # kept from the full scan
            @test !("file-gone" in sids)          # the files are what they are now
            @test !any(haskey(r, "error") for r in rows)
            @test state.discovered[][wid] === rows
            # A worker that sent the agents' rows anyway: not twice.
            fresh = [row("kimi-1"; provider = "KimiCode")]
            @test length(BA.keep_agent_rows!(fresh, [row("kimi-1"; provider = "KimiCode")])) == 1
        end

        @testset "callers while a scan runs share it" begin
            # All three are let in at once: the first starts the scan, the
            # others find it running (it takes a round trip to the worker).
            tasks = lock(state.lock) do
                [Threads.@spawn(BA.scan_and_store!(state, wid; agents = false)) for _ in 1:3]
            end
            results = fetch.(tasks)
            @test results[1] === results[2] === results[3]
            @test isempty(state.scan_inflight)
            # A later call is a new scan.
            @test BA.scan_and_store!(state, wid; agents = false) !== results[1]
        end
    finally
        close(worker)
        wait(task)
        BA.close_worker_links!(state)
        close(state.srv)
    end
end
