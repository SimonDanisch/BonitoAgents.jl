# Building the index: fetch and parse on worker tasks, write from one task (SQLite has
# one writer). A package already stored under its tree hash is skipped, so an
# interrupted build resumes where it stopped.

"""What happened to one package: its source, or why there is none."""
struct Outcome
    package::PackageVersion
    status::String            # "ok", "no-entry", "fetch-failed", "extract-failed"
    source::PackageSource
    message::String
    dir::String               # the cached source, "" when the fetch failed
end
Outcome(p, status, src, message) = Outcome(p, status, src, message, "")

function process(idx::Index, p::PackageVersion)
    dir = try
        fetch!(idx, p)
    catch e
        # Only a failed request is an expected outcome; anything else is a bug here.
        e isa Downloads.RequestError || rethrow()
        return Outcome(p, "fetch-failed", PackageSource(), sprint(showerror, e))
    end
    isfile(joinpath(dir, "src", p.name * ".jl")) ||
        return Outcome(p, "no-entry", PackageSource(), "no src/$(p.name).jl", dir)
    rootreadme!(dir, p)
    src = try
        extract(dir, p.name; extensions = extensions(dir))
    catch e
        # One package's source tripping the extractor is a bug to fix, not a reason to
        # lose the other 14000: it is stored as `extract-failed` with its backtrace, and
        # `build!` reports how many there were.
        e isa InterruptException && rethrow()
        return Outcome(p, "extract-failed", PackageSource(), sprint(showerror, e, catch_backtrace()), dir)
    end
    return Outcome(p, "ok", src, "", dir)
end

"""
    build!(idx, packages; ntasks = 2 * Threads.nthreads(), progress = (done, total) -> nothing,
           reindex = true, replace = false) -> Dict(status => count)

Index every package in `packages` not yet stored; with `replace`, the stored ones too,
from their cached sources, each replacing its old version in one step (after the
extractor changed). `progress` is called after each package is written. Returns how
many packages ended in each status. The full-text index is rebuilt at the end, unless
`reindex` is false.
"""
function build!(idx::Index, packages::AbstractVector{PackageVersion};
                ntasks = 2 * Threads.nthreads(), progress = (done, total) -> nothing, reindex::Bool = true,
                replace::Bool = false)
    have = indexed(idx)
    todo = replace ? collect(packages) : [p for p in packages if !(string(p.tree) in have)]
    work = Channel{PackageVersion}(length(todo))
    foreach(p -> put!(work, p), todo)
    close(work)
    results = Channel{Outcome}(64)
    workers = [Threads.@spawn begin
                   for p in work
                       put!(results, process(idx, p))
                   end
               end for _ in 1:min(ntasks, length(todo))]
    # Closed however the workers end, so the loop below cannot wait forever; `wait`
    # then rethrows a worker's error.
    closer = @async try
        foreach(wait, workers)
    finally
        close(results)
    end
    counts = Dict{String,Int}()
    for o in results
        tree = string(o.package.tree)
        old = tree in have ? Int[r.id for r in rows(idx, "SELECT id FROM packages WHERE tree = ?", (tree,))] : Int[]
        pid = store!(idx, o.package, o.status, o.source, isempty(o.dir) ? Tuple{String,String}[] : dependencies(o.dir); replace = old)
        isempty(o.message) || DBInterface.execute(idx.db,
            "INSERT INTO problems (package, kind, file, message) VALUES (?, ?, '', ?)",
            (pid, o.status, o.message))
        counts[o.status] = get(counts, o.status, 0) + 1
        progress(sum(values(counts)), length(todo))
    end
    wait(closer)
    reindex && reindex_text!(idx)
    return counts
end

"""
    update!(idx, versions = latest_versions(); progress = (done, total) -> nothing, stats = true,
            embedder = nothing) -> Dict(status => count)

Bring the index to `versions`, by default the latest in the local copy of the General
registry (which `Pkg.Registry.update()` refreshes): index new packages and versions,
retry the fetches that failed, then drop what is not in `versions` (older versions,
packages gone from the registry) with its cached sources, and index the local packages
again (see `addlocal!`). With `stats`, the download statistics are refreshed too, and
with an `embedder`, every package without a vector gets one (see `embed_packages!`). The
counts are those of `build!`, plus `"dropped"`, `"local"` and, with an embedder, `"embedded"`.
"""
function update!(idx::Index, versions::AbstractVector{PackageVersion} = latest_versions();
                 progress = (done, total) -> nothing, stats::Bool = true, embedder = nothing)
    latest = Set(string(p.tree) for p in versions)
    forget!(idx, Int[r.id for r in rows(idx, "SELECT id FROM packages WHERE status = 'fetch-failed'")])
    counts = build!(idx, versions; progress, reindex = false)
    stale = [r for r in rows(idx, "SELECT id, name, tree FROM packages WHERE status != 'local'") if !(r.tree in latest)]
    forget!(idx, Int[r.id for r in stale])
    foreach(r -> rm(joinpath(idx.sources, r.name, r.tree); force = true, recursive = true), stale)
    counts["local"] = index_local!(idx)
    reindex_text!(idx)
    stats && downloads!(idx)
    embedder === nothing || (counts["embedded"] = embed_packages!(idx, embedder))
    counts["dropped"] = length(stale)
    return counts
end

"""
    addlocal!(idx, dirs...) -> number of local packages

Index the unregistered packages in `dirs`, each a package or a folder of packages (a
working folder's `dev/`), now and on every `update!`: an agent then finds what your own
packages provide like anything registered. Packages registered in General (checkouts
of them, under `dev/`) are left to the registry's version; a package in several of the
folders is taken from the first.
"""
function addlocal!(idx::Index, dirs::AbstractString...)
    foreach(d -> exec!(idx.db, "INSERT OR IGNORE INTO localroots (path) VALUES (?)", (normpath(abspath(d)),)), dirs)
    n = index_local!(idx)
    reindex_text!(idx)
    return n
end

"""
    removelocal!(idx, dirs...) -> number of local packages

Stop indexing the local packages in `dirs` (as given to `addlocal!`).
"""
function removelocal!(idx::Index, dirs::AbstractString...)
    foreach(d -> exec!(idx.db, "DELETE FROM localroots WHERE path = ?", (normpath(abspath(d)),)), dirs)
    n = index_local!(idx)
    reindex_text!(idx)
    return n
end

"""The package directories at `root`: `root` if it is one, else those directly under it."""
function packagedirs(root::AbstractString)
    ispackage(d) = (p = project(d); haskey(p, "name") && haskey(p, "uuid") && isfile(joinpath(d, "src", p["name"] * ".jl")))
    ispackage(root) && return [root]
    return filter(d -> isdir(d) && ispackage(d), readdir(root; join = true))
end

# The local packages are read again from their directories, which change all the time;
# a directory is the package's "tree", its path hashed, so it is stored once.
function index_local!(idx::Index)
    registered = Set(r.uuid for r in rows(idx, "SELECT uuid FROM packages WHERE status != 'local'"))
    forget!(idx, Int[r.id for r in rows(idx, "SELECT id FROM packages WHERE status = 'local'")])
    taken = Set{String}()
    for root in (r.path for r in rows(idx, "SELECT path FROM localroots ORDER BY rowid"))
        isdir(root) || (@warn "skipping the local packages under $root: it is gone"; continue)
        for dir in packagedirs(root)
            proj = project(dir)
            (proj["uuid"] in registered || proj["uuid"] in taken) && continue
            push!(taken, proj["uuid"])
            name = proj["name"]
            p = PackageVersion(UUID(proj["uuid"]), name, VersionNumber(get(proj, "version", "0.0.0")),
                               SHA1(SHA.sha1(dir)), dir)
            store!(idx, p, "local", extract(dir, name; extensions = extensions(dir)), dependencies(dir))
        end
    end
    return length(taken)
end
