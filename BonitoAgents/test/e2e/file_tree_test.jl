# file_tree's sidebar tree-scan doesn't populate reliably on a server that has
# already churned many chats (worker/filesystem state), so it runs on its own
# clean dev_server rather than the shared soak server.
@testitem "e2e:file_tree" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "file_tree.jl"))
    server = TestKit.dev_server(agent = (_ -> TestKit.end_turn()))
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
