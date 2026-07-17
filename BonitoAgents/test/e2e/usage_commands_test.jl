# Ports the usage/commands e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:usage_commands" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "usage_commands.jl"))
    run_suite(SharedServer.server())
end
