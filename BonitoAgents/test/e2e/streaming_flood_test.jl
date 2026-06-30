# Ports the streaming_flood e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:streaming_flood" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "streaming_flood.jl"))
    run_suite(SharedServer.server())
end
