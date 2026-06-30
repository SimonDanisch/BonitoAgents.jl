# Ports the app_stress e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:app_stress" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "app_stress.jl"))
    run_suite(SharedServer.server())
end
