# Warm the depot for the ACTIVE project: import every one of its `[deps]`, which
# compiles whatever that project still lacks an image for.
#
#   julia --project=<env> .github/scripts/warmup.jl
#
# LOADING rather than `Pkg.precompile()`, on purpose. A process that has just run
# `Pkg.instantiate()`/`Pkg.update()` holds the versions it loaded on the way in,
# and precompiling from there builds images against THOSE versions — Julia says so
# itself ("N dependencies precompiled but different versions are currently loaded
# … Restart julia to access the new versions"). A fresh process then resolves the
# manifest, finds no image that matches, and compiles the whole stack again, which
# is what every downstream CI job used to do inside its test budget. Importing in a
# clean process produces exactly the images the test run will look for.
using TOML

const PROJECT = Base.active_project()
const DEPS = sort!(collect(keys(get(TOML.parsefile(PROJECT), "deps", Dict{String,Any}()))))

isempty(DEPS) && error("warmup: $PROJECT declares no [deps]")

@info "warming $PROJECT" count = length(DEPS)
for dep in DEPS
    @eval import $(Symbol(dep))
end
@info "warm" project = PROJECT loaded = length(DEPS)
