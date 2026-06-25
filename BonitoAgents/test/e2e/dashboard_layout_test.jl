# Ports the dashboard_layout e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:dashboard_layout" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "dashboard_layout.jl"))
    run_suite(SharedServer.server())
end
