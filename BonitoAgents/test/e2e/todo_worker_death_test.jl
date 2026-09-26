# todo_worker_death SIGKILLs the chat's own worker, so it gets its own throwaway
# dev_server + browser rather than taking the shared soak server's worker down
# with it.
@testitem "e2e:todo_worker_death" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "todo_worker_death.jl"))
    server = TestKit.dev_server(agent = agent_script, worker_link_grace = GRACE)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
