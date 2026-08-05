# Ports the workflows e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:workflows" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "workflows.jl"))
    run_suite(SharedServer.server())
end
