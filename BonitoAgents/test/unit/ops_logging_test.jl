# What the logs keep for a post-mortem: worker requests that timed out (once a
# minute per kind, with a count, so a stuck worker polled every second does not
# flood the file) and the periodic memory line (what ran out, and who held it).

@testitem "unit:ops logging" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    const BW = BT.BonitoWorker
    using Test, Logging

    dir = mktempdir()
    state = BT.ServerState(; state_dir = mkpath(joinpath(dir, "state")),
                             working_dir = mkpath(joinpath(dir, "work")))
    logs, _ = Test.collect_test_logs() do
        for _ in 1:5
            BT.log_rpc_timeout(state, "stat_path on 'w1'", 5.0)
        end
        BT.log_rpc_timeout(state, "list_dir on 'w1'", 5.0)
    end
    @test [l.kwargs[:request] for l in logs] == ["stat_path on 'w1'", "list_dir on 'w1'"]
    @test all(l.level == Logging.Warn for l in logs)
    @test state.rpc_timeouts["stat_path on 'w1'"][2] == 4        # the ones not logged, counted
    # A minute later the next one is logged again, saying how many were quiet.
    last, n = state.rpc_timeouts["stat_path on 'w1'"]
    state.rpc_timeouts["stat_path on 'w1'"] = (last - 61, n)
    logs, _ = Test.collect_test_logs(() -> BT.log_rpc_timeout(state, "stat_path on 'w1'", 5.0))
    @test only(logs).kwargs[:since_last_line] == 4

    logs, _ = Test.collect_test_logs(BW.log_memory)
    line = only(logs)
    @test line.message == "memory"
    @test 0 < line.kwargs[:available_gb] <= line.kwargs[:total_gb]
    if !Sys.iswindows()
        @test line.kwargs[:this_process_gb] > 0
        @test length(line.kwargs[:largest]) == 5
        @test all(occursin(" GB  ", p) for p in line.kwargs[:largest])
    end
end
