# BonitoMCP test suite.
using Test

@testset "BonitoMCP" begin
    # Stability regressions (M2–M7, M9–M11, M14): output caps, kill-session
    # races, dial bootstrap, requestId-scoped cancel. Pure unit tests.
    include("test_stability.jl")
    include("test_worker_loadpath.jl")
    include("test_session_singleflight.jl")
    include("test_running_response_shape.jl")
    include("test_eval_cancel.jl")
    include("test_remote_proxy.jl")
end
