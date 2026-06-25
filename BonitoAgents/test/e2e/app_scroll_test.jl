# Ports the app_scroll e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:app_scroll" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "app_scroll.jl"))
    run_suite(SharedServer.server())
end
