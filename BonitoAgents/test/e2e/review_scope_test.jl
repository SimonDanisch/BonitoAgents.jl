# Its own dev_server AND its own single chat: two review panels in one window
# cannot be told apart by `querySelector` (it answers about the first) nor by
# "which one is visible" (an inactive workspace panel still has an
# `offsetParent`). See review_scope.jl's header.
@testitem "e2e:review_scope" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "review_scope.jl"))
    server = TestKit.dev_server(agent = scope_agent)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end
