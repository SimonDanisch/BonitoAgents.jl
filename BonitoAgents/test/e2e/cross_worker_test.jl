# cross_worker spawns + kills a second worker, so it gets its own throwaway
# dev_server + browser rather than mutating the shared soak server's worker set.
@testitem "e2e:cross_worker" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "cross_worker.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
