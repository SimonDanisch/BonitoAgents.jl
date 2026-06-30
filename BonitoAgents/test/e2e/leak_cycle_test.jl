# leak_cycle asserts WHOLE-server cleanup after closing all chats (pollers → 0),
# which only holds when nothing else lives on the server — so it runs on its own
# dedicated dev_server, not the shared soak one.
@testitem "e2e:leak_cycle" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "leak_cycle.jl"))
    server = TestKit.dev_server(agent = agent_script)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
