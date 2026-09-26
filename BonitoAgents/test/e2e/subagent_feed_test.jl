# Subagent visibility (Task activity feed + taskbar staleness) needs its own
# dev_server: the suite backdates a live TaskToolMsg's `last_activity_at`
# server-side and holds a ~27 s turn open — too stateful for the shared soak
# server.
@testitem "e2e:subagent_feed" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "subagent_feed.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
