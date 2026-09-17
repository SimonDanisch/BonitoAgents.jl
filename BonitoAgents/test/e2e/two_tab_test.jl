# Two browser tabs on one project each get their own per-page proxied root, so
# both live embeds are interactive simultaneously and never clobber each other
# (the regression the old single `root_conn` could not pass). See two_tab.jl.
@testitem "e2e:two_tab" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    include(joinpath(@__DIR__, "two_tab.jl"))
    run_suite(SharedServer.server())
end
