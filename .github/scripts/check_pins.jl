# Assert that the envs resolved the pins they declare.
#
#   julia .github/scripts/check_pins.jl <env-dir> <env-dir> …
#
# Two questions, both of which have cost a day:
#
#   1. Did every `[sources]` entry actually take? `[sources]` only governs
#      packages the project DECLARES. `test/evalenv` listed Makie under
#      `[extras]`, so its pin was ignored and Makie came from the registry —
#      at the same version number as the branch, so nothing looked wrong —
#      while WGLMakie came from the branch and called a function only the
#      branch has. The env could not precompile, the eval worker had no
#      bridge, and eight e2e suites reported timeouts.
#
#   2. Do both sides of the eval proxy agree on Bonito? The page is served by a
#      Bonito from the server's env and the embed's values are serialized by a
#      Bonito in the eval worker's env. A branch is not a commit: resolve them
#      at different moments and an embed renders its static DOM and never comes
#      alive.
using TOML

const ENVS = ARGS
isempty(ENVS) && error("check_pins: pass the env directories to check")

manifest_of(env) = joinpath(env, "Manifest.toml")
project_of(env)  = joinpath(env, "Project.toml")

"The manifest entry for `pkg`, or nothing if this env doesn't have it."
function resolved(env::AbstractString, pkg::AbstractString)
    deps = get(TOML.parsefile(manifest_of(env)), "deps", Dict{String,Any}())
    haskey(deps, pkg) || return nothing
    return only(deps[pkg])
end

# ── 1. every declared source resolved to that source ────────────────────────
ignored = String[]
for env in ENVS
    isfile(project_of(env))  || error("check_pins: no Project.toml in $env")
    isfile(manifest_of(env)) || error("check_pins: $env was never instantiated")
    project = TOML.parsefile(project_of(env))
    declared = keys(get(project, "sources", Dict{String,Any}()))
    for pkg in declared
        entry = resolved(env, pkg)
        entry === nothing && continue              # not in the dependency graph
        if !haskey(entry, "repo-url") && !haskey(entry, "path")
            push!(ignored, "$env: $pkg is pinned in [sources] but resolved to " *
                           "v$(get(entry, "version", "?")) from the registry")
        end
    end
end
if !isempty(ignored)
    foreach(l -> println("  ", l), ignored)
    error("check_pins: a [sources] pin did not take. `[sources]` only governs " *
          "packages the project itself declares — move it out of [extras] into " *
          "[deps].")
end

# ── 2. one Bonito across the eval proxy ─────────────────────────────────────
trees = Dict{String,Vector{String}}()
for env in ENVS
    entry = resolved(env, "Bonito")
    entry === nothing && continue
    push!(get!(trees, get(entry, "git-tree-sha1", "(not a git source)"), String[]), env)
end
if length(trees) > 1
    for (tree, where) in trees
        println("  $tree  ", join(where, ", "))
    end
    error("check_pins: these envs resolved DIFFERENT Bonito trees; the eval proxy " *
          "needs one tree on both sides. Resolve them in the same step, or pin the " *
          "[sources] rev to a commit.")
end

@info "check_pins: every [sources] pin took" envs = length(ENVS) bonito = only(keys(trees))
