# Where a slow page load spent its time, in the server log. A phone took minutes
# to load the page and the server had no trace of it: the browser now reports its
# own load (`page_load_report` → `page_timing_response`), and the login gate says
# which request it took long to answer and how much of that was Authelia
# (`log_slow_request`).
@testitem "unit:page_timing" tags = [:unit] begin
    using BonitoAgents, Test, Logging
    import HTTP, JSON
    const BT = BonitoAgents

    post(report) = HTTP.Request("POST", BT.PAGE_TIMING_ROUTE,
        ["User-Agent" => "Mozilla/5.0 (Linux; Android 10; K)"], Vector{UInt8}(JSON.json(report)))
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())

    @testset "a page's report" begin
        fast = Dict("why" => "ready", "view" => "abc", "html" => 80, "scripts" => 300,
                    "connected" => 420, "chat_settled" => 900, "status" => "connected", "slow" => Any[])
        r = @test_logs (:info, "page load") BT.page_timing_response(st, post(fast))
        @test r.status == 204
        # Kept for `bt_dev_timings` too: usable after the chat settled.
        @test only(st.timings.kinds[:browser_load]).seconds == 0.9
        # Slow, and where the time went: the downloads that took longest.
        slow = merge(fast, Dict("chat_settled" => 95_000,
                                "slow" => Any[Any["/worker-file/w1?path=x", 90_000, 4]]))
        @test_logs (:warn, "slow page load") BT.page_timing_response(st, post(slow))
        # Never usable: no connection within the time the page waits.
        never = Dict("why" => "gave_up", "html" => 80, "status" => "connecting", "waited" => 60_000)
        @test_logs (:warn, "slow page load") BT.page_timing_response(st, post(never))
        @test last(st.timings.kinds[:browser_load]).seconds == 60.0   # how long it waited
        @test BT.page_timing_response(st, HTTP.Request("GET", BT.PAGE_TIMING_ROUTE)).status == 405
        big = HTTP.Request("POST", BT.PAGE_TIMING_ROUTE, [], zeros(UInt8, 20_000))
        @test BT.page_timing_response(st, big).status == 413
    end

    @testset "a request the server was slow to answer" begin
        req = HTTP.Request("GET", "/assets/x.js", ["User-Agent" => "Mozilla/5.0 (Linux; Android 10; K)"])
        req.context[:gate_t0] = time() - 3
        req.context[:login_s] = 2.5
        @test_logs (:warn, r"slow request") BT.log_slow_request(req, HTTP.Response(200))
        quick = HTTP.Request("GET", "/assets/x.js")
        quick.context[:gate_t0] = time()
        @test_logs BT.log_slow_request(quick, HTTP.Response(200))
    end

    @testset "where a slow page spent its time" begin
        # The gate gives each request a table in its task; the page's parts add
        # their time to it, and the warning lists them, slowest first.
        phases = task_local_storage(:bt_page_phases, Dict{Symbol,Float64}())
        @test BT.page_phase(() -> (sleep(0.2); :built), :dashboard) === :built
        BT.page_phase(() -> sleep(0.1), :sidebar)
        BT.page_phase(() -> nothing, :apps)                   # too quick to list
        @test phases[:dashboard] >= 0.2 && phases[:sidebar] >= 0.1
        summary = BT.phase_summary(phases)
        @test occursin(r"^dashboard=0\.2\d*s sidebar=0\.1\d*s$", summary)
        @test !occursin("apps", summary)
        req = HTTP.Request("GET", "/")
        req.context[:gate_t0] = time() - 3
        req.context[:page_phases] = phases
        @test_logs (:warn, r"slow request") BT.log_slow_request(req, HTTP.Response(200))
        delete!(task_local_storage(), :bt_page_phases)
        # Outside a page request it only calls the function.
        @test BT.page_phase(() -> 7, :dashboard) == 7
    end
end
