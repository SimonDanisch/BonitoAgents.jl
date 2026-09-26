# Ports the legacy Tier 3b electron test (test/electron/test_folder_threads.jl)
# onto TestKit as a black-box e2e testitem. ISOLATED: it seeds the worker's
# discover scan (state.discovered) and closes a chat, both of which would
# pollute a shared soak server's dashboard for neighbouring suites — so it gets
# its own throwaway dev_server + browser, torn down at the end.
@testitem "e2e:folder_threads" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "folder_threads.jl"))
    server = TestKit.dev_server()
    try
        TestKit.open_browser(server)
        run_suite(server)
        @test isempty(TestKit.js_errors(server))
    finally
        close(server)
    end
end
