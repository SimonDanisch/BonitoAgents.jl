# Ports the tool_rendering e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:tool_rendering" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "tool_rendering.jl"))
    run_suite(SharedServer.server())
end
