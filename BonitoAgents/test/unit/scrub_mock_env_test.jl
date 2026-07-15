# A mock TestKit dev_server writes its agent_env into the process ENV (the
# worker subprocess inherits it). A later `dev_server(mock = false)` in the
# SAME process must scrub those leftovers — otherwise its chats default to
# MockCode and the spawned MockACP dials the closed mock server's dispatcher
# port: every ACP bind dies with "ACP connection closed" and no useful stderr.
@testitem "unit:scrub_mock_env" tags = [:unit] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    const TK = TestKit

    mock_keys = ("BT_ENABLE_MOCK_AGENT", "BT_MOCK_ACP_SCENARIO",
                 "BT_MOCK_ACP_DISPATCHER", "BT_MOCK_PROJECT",
                 "BT_MOCK_ACP_IGNORE_CANCEL")
    saved = Dict(k => get(ENV, k, nothing) for k in (mock_keys..., "BT_DEFAULT_PROVIDER"))
    try
        # Simulate the leak of a closed mock dev_server.
        ENV["BT_ENABLE_MOCK_AGENT"]   = "1"
        ENV["BT_DEFAULT_PROVIDER"]    = "MockCode"
        ENV["BT_MOCK_ACP_SCENARIO"]   = "dispatcher"
        ENV["BT_MOCK_ACP_DISPATCHER"] = "127.0.0.1:41975"
        ENV["BT_MOCK_PROJECT"]        = "/tmp/somewhere"
        TK.scrub_mock_env!()
        for k in mock_keys
            @test !haskey(ENV, k)
        end
        @test !haskey(ENV, "BT_DEFAULT_PROVIDER")

        # A user's own non-mock default provider is NOT the mock's leftover —
        # it must survive the scrub.
        ENV["BT_DEFAULT_PROVIDER"] = "MiMoCode"
        TK.scrub_mock_env!()
        @test get(ENV, "BT_DEFAULT_PROVIDER", "") == "MiMoCode"
    finally
        for (k, v) in saved
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end
