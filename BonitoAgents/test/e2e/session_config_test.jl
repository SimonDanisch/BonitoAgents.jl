# Black-box e2e for PR #10's session-config header controls. ISOLATED (own
# throwaway dev_server + browser): the mock is started with BT_MOCK_ACP_CONFIG=1
# so its session/new advertises the permission-mode / model / effort config
# blocks — which would otherwise appear in every other suite's header — and the
# header picks mutate session state. Torn down at the end.
@testitem "e2e:session_config" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "session_config.jl"))
    server = TestKit.dev_server(; mock_env = Dict("BT_MOCK_ACP_CONFIG" => "1"))
    try
        TestKit.open_browser(server)
        run_suite(server)
        @test isempty(TestKit.js_errors(server))
    finally
        close(server)
    end
end
