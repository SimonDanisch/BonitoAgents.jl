# Ports the scroll_persist e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:scroll_persist" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "scroll_persist.jl"))
    run_suite(SharedServer.server())
end
