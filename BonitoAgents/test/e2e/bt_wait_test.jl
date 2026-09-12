# bt_wait through the real chat, on the shared soak server (it spawns nothing,
# so it needs no isolated worker).
@testitem "e2e:bt_wait" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "bt_wait.jl"))
    run_suite(SharedServer.server())
end
