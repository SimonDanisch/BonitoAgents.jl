# Regression: the eval worker must behave like a plain `julia --project=env_path`.
#
# The BonitoAgentsApp bundle launcher exports a fixed JULIA_LOAD_PATH (bundle
# project + stdlib, with NO `@`). Malt workers inherit the parent env, so without
# `worker_env()` resetting JULIA_LOAD_PATH the worker resolved packages against
# the BUNDLE's project and IGNORED `--project=env_path` entirely (`@` never on the
# load path). We also must NOT stack any extra entry (the old bridge-Bonito hack).

using Test
using BonitoMCP
const M = BonitoMCP

@testset "worker LOAD_PATH is pristine (plain julia --project)" begin
    # The pure default we hand the worker — exactly an un-set JULIA_LOAD_PATH.
    @test M.DEFAULT_LOAD_PATH == join(["@", "@v#.#", "@stdlib"], Sys.iswindows() ? ";" : ":")
    @test M.worker_env() == ["JULIA_LOAD_PATH" => M.DEFAULT_LOAD_PATH]

    envdir = mktempdir()
    # A real (empty) project so `@` has something to resolve to.
    write(joinpath(envdir, "Project.toml"), "")

    # Simulate the bundle: a contaminating parent JULIA_LOAD_PATH with NO `@`.
    saved = get(ENV, "JULIA_LOAD_PATH", nothing)
    ENV["JULIA_LOAD_PATH"] = "/nonexistent/bundle/Project.toml:@stdlib"
    s = M.JuliaSession(envdir)
    try
        M.start!(s)
        lp   = M.Malt.remote_eval_fetch(s.worker, :(copy(LOAD_PATH)))
        proj = M.Malt.remote_eval_fetch(s.worker, :(Base.active_project()))
        # Plain-julia load path: project + shared default env + stdlib. The
        # contaminating parent value is gone, and no extra (bridge) entry stacked.
        @test lp == ["@", "@v#.#", "@stdlib"]
        # `@` actually resolves to env_path, so packages come from its manifest.
        @test proj == joinpath(envdir, "Project.toml")
        # stdlib still loadable through @stdlib / @v#.#
        @test M.Malt.remote_eval_fetch(s.worker,
            :(try; @eval(using Dates); true; catch; false; end)) === true
    finally
        M.kill_session!(s)
        saved === nothing ? delete!(ENV, "JULIA_LOAD_PATH") : (ENV["JULIA_LOAD_PATH"] = saved)
    end
end
