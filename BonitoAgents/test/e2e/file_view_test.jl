# The file viewer writes files on the worker and mounts a WebGL context, so like
# file_open it runs on its own clean dev_server rather than the shared soak one.
@testitem "e2e:file_view" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "file_view.jl"))
    server = TestKit.dev_server(agent = _ -> [TestKit.text("ready"), TestKit.end_turn()])
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
