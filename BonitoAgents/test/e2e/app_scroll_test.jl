# Moving a live eval embed between bubble / float / tab must not scroll the
# chat, and the app must stay live across the moves. See app_scroll.jl.
@testitem "e2e:app_scroll" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "app_scroll.jl"))
    run_suite(SharedServer.server())
end
