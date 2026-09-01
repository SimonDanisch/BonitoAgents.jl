# The debug chat creates a project pointed at this checkout and persists a
# `dev_mode` flag, so it runs on its own clean dev_server rather than mutating
# the shared soak one's project list.
@testitem "e2e:debug_chat" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "debug_chat.jl"))
    server = TestKit.dev_server(agent = _ -> [TestKit.text("ready"), TestKit.end_turn()])
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
