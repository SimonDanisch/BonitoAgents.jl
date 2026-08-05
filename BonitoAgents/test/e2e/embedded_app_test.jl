# Ports the embedded_app e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:embedded_app" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "embedded_app.jl"))
    run_suite(SharedServer.server())
end
