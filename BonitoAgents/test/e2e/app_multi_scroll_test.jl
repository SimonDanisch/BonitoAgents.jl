# Scrolling to one of several tall embeds must not jump the chat to the top.
# See app_multi_scroll.jl.
@testitem "e2e:app_multi_scroll" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "app_multi_scroll.jl"))
    run_suite(SharedServer.server())
end
