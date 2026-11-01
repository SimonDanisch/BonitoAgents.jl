# Package sources, from the package server, cached by tree hash. Only what the index
# reads is kept: `src/` and `ext/` Julia files, the project files (the package's and the
# tests'), the README and the Documenter pages under `docs/src`.

sourcedir(idx, p::PackageVersion) = joinpath(idx.sources, p.name, string(p.tree))

# Written into a cached source once it is complete. A cache from an older layout (one
# that kept less) is fetched again.
# Persistent cache marker: retained across the package rename.
const FETCHMARK = ".romeo-fetch"
const FETCHVERSION = "2"

function keepentry(h::Tar.Header)
    p = h.path
    h.type == :directory && return any(d -> startswith(p, d), ("src", "ext", "docs", "test"))
    (startswith(p, "src/") || startswith(p, "ext/")) && return endswith(p, ".jl")
    startswith(p, "docs/src/") && return endswith(p, ".md")
    return p in ("Project.toml", "JuliaProject.toml", "test/Project.toml") ||
           (!occursin('/', p) && startswith(uppercase(p), "README"))
end

"""
    fetch!(idx, p) -> directory

The source of `p`, downloaded once. A partial extraction is never mistaken for a cached
one: it is extracted next to its final place and moved there when complete.
"""
function fetch!(idx, p::PackageVersion)
    dir = sourcedir(idx, p)
    mark = joinpath(dir, FETCHMARK)
    isfile(mark) && read(mark, String) == FETCHVERSION && return dir
    tmp = dir * ".partial"
    rm(tmp; force = true, recursive = true)
    mkpath(tmp)
    io = IOBuffer()
    Downloads.download("$(idx.server)/package/$(p.uuid)/$(p.tree)", io)
    seekstart(io)
    Tar.extract(keepentry, CodecZlib.GzipDecompressorStream(io), tmp)
    write(joinpath(tmp, FETCHMARK), FETCHVERSION)
    rm(dir; force = true, recursive = true)
    mv(tmp, dir)
    return dir
end

"""
Where the README of `p` is when the package server's tarball cannot have it: `p` lives in
a subdirectory of its GitHub repository, as the repository's main package (named like
it: SpeedyWeather in SpeedyWeather.jl), so the README is at the repository's root.
`nothing` otherwise: a monorepo's other packages are not what its README describes.
"""
function rootreadme_url(p::PackageVersion)
    isempty(p.subdir) && return nothing
    m = match(r"^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", p.repo)
    (m === nothing || replace(m[2], r"\.jl$" => "") != p.name) && return nothing
    return "https://raw.githubusercontent.com/$(m[1])/$(m[2])/HEAD/README.md"
end

"""Add the repository's README to the source of `p` at `dir` if it has none (see `rootreadme_url`)."""
function rootreadme!(dir::AbstractString, p::PackageVersion)
    url = rootreadme_url(p)
    (url === nothing || any(f -> startswith(uppercase(f), "README"), readdir(dir))) && return
    io = IOBuffer()
    try
        Downloads.download(url, io)
    catch e
        # No README.md at the repository's root (or no repository): nothing to add.
        e isa Downloads.RequestError || rethrow()
        return
    end
    write(joinpath(dir, "README.md"), take!(io))
    return
end

"""The parsed project file of a package source, empty when it has none."""
function project(dir)
    for f in ("JuliaProject.toml", "Project.toml")
        path = joinpath(dir, f)
        isfile(path) && return TOML.parsefile(path)
    end
    return Dict{String,Any}()
end

"""The extension module names a package declares."""
extensions(dir) = collect(String, keys(get(project(dir), "extensions", Dict{String,Any}())))

"""
`(name, kind)` of every dependency: `"dep"`, `"weakdep"`, or `"test"` for what only the
tests use (`[extras]`, or `test/Project.toml`).
"""
function dependencies(dir)
    proj = project(dir)
    out = [(String(name), kind) for (kind, section) in (("dep", "deps"), ("weakdep", "weakdeps"), ("test", "extras"))
           for name in keys(get(proj, section, Dict{String,Any}()))]
    testproj = joinpath(dir, "test", "Project.toml")
    if isfile(testproj)
        have = Set(n for (n, _) in out)
        for name in keys(get(TOML.parsefile(testproj), "deps", Dict{String,Any}()))
            name in have || push!(out, (String(name), "test"))
        end
    end
    return out
end

"""The README and the Documenter pages, as `(path relative to the package, text)`."""
function textdocs(dir)
    out = Tuple{String,String}[]
    for f in readdir(dir)
        startswith(uppercase(f), "README") && isfile(joinpath(dir, f)) && push!(out, (f, read(joinpath(dir, f), String)))
    end
    docs = joinpath(dir, "docs", "src")
    isdir(docs) || return out
    for (root, _, files) in walkdir(docs), f in files
        path = joinpath(root, f)
        # `isfile` follows links: a docs page linked to a file outside `docs/src`
        # (`NEWS.md -> ../../NEWS.md`) was not extracted and is skipped.
        endswith(f, ".md") && isfile(path) && push!(out, (relpath(path, dir), read(path, String)))
    end
    return out
end
