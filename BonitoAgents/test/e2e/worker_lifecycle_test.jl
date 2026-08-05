# worker_lifecycle KILLS the main worker, so it must NOT run on the shared soak
# server (it would break worker-dependent neighbors). It gets its own throwaway
# dev_server + browser, torn down at the end.
@testitem "e2e:worker_lifecycle" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "worker_lifecycle.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
