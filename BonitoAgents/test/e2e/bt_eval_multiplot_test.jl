# Several WGLMakie figures proxied into one chat from several eval results, kept
# live across a page reload (see bt_eval_multiplot.jl).
@testitem "e2e:bt_eval_multiplot" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "bt_eval_multiplot.jl"))
    run_suite(SharedServer.server())
end
