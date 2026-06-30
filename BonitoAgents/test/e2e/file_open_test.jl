# file_open (open-in-editor + worker file fetch) is worker/filesystem-stateful
# like file_tree, so it runs on its own clean dev_server, not the shared soak one.
@testitem "e2e:file_open" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "file_open.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
