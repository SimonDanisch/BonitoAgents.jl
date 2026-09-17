# Ports the connection-guard suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:connection_guard" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "connection_guard.jl"))
    run_suite(SharedServer.server())
end
