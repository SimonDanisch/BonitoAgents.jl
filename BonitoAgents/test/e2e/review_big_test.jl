# Single chat, single review panel: the multi-frame (chunked) git_diff reply
# must reassemble server-side, render every file, and show the FULL per-file
# add/delete counts — the DOM-level proof that no frame was lost in transit.
# Fixture + suite live in review_big.jl (big enough to force index > 1).
@testitem "e2e:review_big" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "review_big.jl"))
    server = TestKit.dev_server(agent = big_agent)
    try
        TestKit.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end