# The review tab needs its own git repo as the chat's cwd, so it runs on a clean
# dev_server rather than the shared soak one.
@testitem "e2e:review" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "review.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
