# What to index: the latest version of every package in a registry.

"""A registered package at one version."""
struct PackageVersion
    uuid::UUID
    name::String
    version::VersionNumber
    tree::SHA1
    repo::String
    subdir::String      # where in `repo` the package is, "" at its root
end
PackageVersion(uuid, name, version, tree, repo) = PackageVersion(uuid, name, version, tree, repo, "")

"""
    latest_versions(; registry = "General", jll = false) -> Vector{PackageVersion}

The newest non-yanked version of every package in `registry`, read from the local
registry copy. JLL wrappers are generated code and left out unless `jll`.
"""
function latest_versions(; registry = "General", jll = false)
    reg = only(r for r in RegistryInstances.reachable_registries() if r.name == registry)
    out = PackageVersion[]
    for e in values(reg.pkgs)
        !jll && endswith(e.name, "_jll") && continue
        info = RegistryInstances.registry_info(e)
        vs = [v for (v, vi) in info.version_info if !vi.yanked]
        isempty(vs) && continue
        v = maximum(vs)
        push!(out, PackageVersion(e.uuid, e.name, v, info.version_info[v].git_tree_sha1, info.repo,
                                  something(info.subdir, "")))
    end
    return sort!(out; by = p -> p.name)
end
