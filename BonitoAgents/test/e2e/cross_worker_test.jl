# cross_worker spawns + kills a second worker, so it gets its own throwaway
# dev_server + browser rather than mutating the shared soak server's worker set.
@testitem "e2e:cross_worker" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "cross_worker.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
