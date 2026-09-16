# Assert that the envs on both sides of the eval proxy resolved the SAME Bonito.
#
#   julia .github/scripts/check_pins.jl <manifest> <manifest> …
#
# The page is served by a Bonito from the server's env; the live embed's values
# are serialized by a Bonito in the eval worker's env (`test/evalenv`,
# `test/altenv`). Both are pinned to the same branch in `[sources]`, but a branch
# is not a commit: resolve them at different moments and the two sides end up on
# different trees, at which point an embed still renders its static DOM and never
# comes alive. That failure reads as a timing flake in eight different e2e suites,
# so it is worth one loud error here instead.
using TOML

const MANIFESTS = ARGS
isempty(MANIFESTS) && error("check_pins: pass the manifests to compare")

"The git tree a manifest resolved for `pkg`, or nothing if it has no such dep."
function resolved_tree(manifest::AbstractString, pkg::AbstractString)
    entries = get(TOML.parsefile(manifest), "deps", Dict{String,Any}())
    haskey(entries, pkg) || return nothing
    return get(only(entries[pkg]), "git-tree-sha1", "(not a git source)")
end

seen = Dict{String,Vector{String}}()
for manifest in MANIFESTS
    isfile(manifest) || error("check_pins: no such manifest: $manifest")
    tree = resolved_tree(manifest, "Bonito")
    tree === nothing && continue
    push!(get!(seen, tree, String[]), manifest)
end

if length(seen) > 1
    for (tree, where) in seen
        println("  $tree  ", join(where, ", "))
    end
    error("check_pins: these envs resolved DIFFERENT Bonito trees; the eval proxy " *
          "needs one tree on both sides. Resolve them in the same step, or pin the " *
          "[sources] rev to a commit.")
end
@info "check_pins: one Bonito tree across $(length(MANIFESTS)) envs" tree = only(keys(seen))
