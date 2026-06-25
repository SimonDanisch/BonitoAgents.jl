# Ports the lens e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:lens" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "lens.jl"))
    run_suite(SharedServer.server())
end
