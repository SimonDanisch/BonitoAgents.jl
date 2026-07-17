# Runs the header_collapse e2e suite on the shared soak server (see
# chat_features_test.jl). The suite resizes the worker's electron window and
# restores the default size in a `finally`, so co-scheduled suites are safe.
@testitem "e2e:header_collapse" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "header_collapse.jl"))
    run_suite(SharedServer.server())
end
