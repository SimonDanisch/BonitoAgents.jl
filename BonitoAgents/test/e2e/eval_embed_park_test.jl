# Live eval-result embeds get bt_show_app's output handling: keep-alive
# parking on scroll-off and ⤢ detach into a workspace panel (see
# eval_embed_park.jl).
@testitem "e2e:eval_embed_park" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "eval_embed_park.jl"))
    run_suite(SharedServer.server())
end
