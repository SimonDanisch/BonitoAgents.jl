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
    include("test_process_reaping.jl")
    include("test_wait.jl")
    # ⚠ LAST on purpose: this one needs `Bonito`, which is not in the test
    # target, so it errors and takes the rest of the file with it. That was
    # invisible while `Pkg.test` could not resolve `Test` at all and the suite
    # never ran; it needs a decision about WHICH Bonito the test env pins
    # (registry vs the dev checkout) before it can be fixed properly.
    include("test_remote_proxy.jl")
end
