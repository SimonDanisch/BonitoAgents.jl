# @testitem wrapper for the "resumed chat eagerly binds the agent on open"
# regression. The suite lives in `resume_eager_bind.jl` and drives the server
# state directly (no browser); a throwaway dev_server + worker runs it.
@testitem "e2e:resume_eager_bind" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    include(joinpath(@__DIR__, "resume_eager_bind.jl"))
    server = TestKit.dev_server()
    try
        run_suite(server)
    finally
        close(server)
    end
end
