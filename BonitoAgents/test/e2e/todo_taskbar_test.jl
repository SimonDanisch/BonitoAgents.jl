# Ports the todo_taskbar e2e suite onto the shared soak server (see chat_features_test.jl).
@testitem "e2e:todo_taskbar" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "todo_taskbar.jl"))
    run_suite(SharedServer.server())
end
