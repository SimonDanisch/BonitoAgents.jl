# Asking the index. Everything an agent needs before writing code that may already
# exist: definitions and packages by topic, a function's implementers across the
# ecosystem, who depends on whom, and code similar to a given definition.

"""A stored definition, as queries return it."""
struct Hit
    id::Int
    package::String
    version::String
    modpath::String
    kind::String
    name::String
    signature::String
    doc::String
    file::String
    line::Int
    nlines::Int
    exported::Bool
    generated::Bool
    users::Int        # the package's distinct non-CI downloaders over the past year
    islocal::Bool     # an unregistered package on this machine (see `addlocal!`)
    repo::String      # its directory, if local
end

# The package's users and whether it is local, for a query over `packages p`.
const USAGE = """COALESCE((SELECT w.users FROM downloads w WHERE w.uuid = p.uuid), 0) AS users,
    p.status = 'local' AS islocal"""

const HITCOLUMNS = """d.id, p.name AS package, p.version, p.repo, d.module, d.kind, d.name, d.signature,
    d.doc, d.file, d.line, d.nlines, d.generated,
    EXISTS (SELECT 1 FROM exports e WHERE e.package = d.package AND e.module = d.module
            AND e.name = d.name) AS exported, $USAGE"""

Hit(r::NamedTuple) = Hit(r.id, r.package, r.version, r.module, r.kind, r.name, r.signature, r.doc,
                         r.file, r.line, r.nlines, r.exported == 1, r.generated == 1, r.users, r.islocal == 1, r.repo)

"""Packages whose dependence on one of these makes them GPU packages."""
const GPU_DEPS = ["CUDA", "AMDGPU", "Metal", "oneAPI", "OpenCL", "KernelAbstractions", "GPUArrays",
                  "Vulkan", "AcceleratedKernels"]

const WORD = r"[\p{L}\p{N}_!]+"

# Names one algorithm goes by. A query naming one also searches for the others: the
# docstring of AcceleratedKernels' `accumulate` never says "prefix sum".
const SYNONYMS = [
    ["prefix sum", "scan", "accumulate", "cumsum"],
    ["sort", "sortperm", "radix sort", "argsort"],
    ["nearest neighbor", "nearest neighbour", "knn", "kdtree", "neighbor list", "neighbour list", "cell list"],
    ["spmv", "sparse matrix vector", "sparse matvec"],
    ["conjugate gradient", "cg"],
    ["fft", "fourier transform"],
    ["bvh", "bounding volume hierarchy", "acceleration structure"],
    ["marching cubes", "isosurface"],
    ["delaunay", "triangulation"],
    ["tetrahedral mesh", "tetrahedralization", "tetgen"],
    ["quadrature", "numerical integration"],
    ["automatic differentiation", "autodiff"],
    ["finite element", "finite elements", "fem"],
    ["smoothed particle hydrodynamics", "sph"],
    ["molecular dynamics", "md simulation"],
    ["discrete element", "discrete element method"],
    ["mapreduce", "reduction"],
    ["interpolation", "interpolate", "spline"],
    ["eigenvalue", "eigensolver", "eigs"],
    ["collision detection", "continuous collision"],
    ["matrix multiply", "gemm", "matmul"],
    ["computational fluid dynamics", "cfd", "navier stokes"],
    ["motion planning", "path planning"],
    ["rigid body dynamics", "multibody dynamics", "multibody"],
]

# Abbreviations a query may use, and what they stand for. One way only: a query saying
# "simulation" does not search "sim", which names SimJulia and ConcurrentSim.
const ABBREVIATIONS = Dict(
    "sim" => ["simulation", "simulator"],
    "viz" => ["visualization", "visualisation"],
    "ml" => ["machine learning"],
    "nn" => ["neural network"],
    "rl" => ["reinforcement learning"],
    "nlp" => ["natural language processing"],
    "ode" => ["ordinary differential equation"],
    "pde" => ["partial differential equation"],
    "db" => ["database"],
    "gui" => ["graphical user interface"],
    "ik" => ["inverse kinematics"],
)

"""The synonyms of the algorithm names `text` mentions (see `SYNONYMS`), and what its abbreviations stand for."""
function synonyms(text::AbstractString)
    low = lowercase(text)
    out = String[]
    for group in SYNONYMS
        any(t -> occursin(Regex("\\b" * t * "\\b"), low), group) && append!(out, group)
    end
    for m in eachmatch(WORD, low)
        append!(out, get(ABBREVIATIONS, m.match, String[]))
    end
    return out
end

# Words a request is phrased with that say nothing about what it asks for. Every
# package of this registry is a Julia package, so "julia" and "package" are among them.
const STOPWORDS = Set(split("""a an the for of in on at to with by from and or is are be how what which that this it
                               i my me we do does can into as using via some any want need way julia jl package
                               packages library"""))

quoted(s::AbstractString) = "\"" * join((w.match for w in eachmatch(WORD, s)), " ") * "\""

# A short abbreviation (`fem`, `cg`) is also somebody's variable name, as in
# FixedEffects' `fem::FixedEffectMatrix`: among definitions it is not searched in
# signatures. In a name it is a whole token, so it only finds functions called just that.
const SHORTCOLUMNS = "{name words doc} : "

"""
    termgroups(text; expand = true, short = SHORTCOLUMNS) -> Vector{Vector{String}}

The concepts in free text, each as the FTS5 terms that stand for it. `"double quoted"`
parts stay phrases and every other word is a term of its own, so punctuation a caller
types is never FTS5 syntax, and stopwords ("for", "the", "julia") are dropped; with
`expand`, a term naming an algorithm brings its
synonyms (`SYNONYMS`) into its group, a synonym of three letters or fewer behind the
column filter `short`.
"""
function termgroups(text::AbstractString; expand::Bool = true, short::AbstractString = SHORTCOLUMNS)
    if expand
        # A known name of several words, unquoted, is still one term: "prefix sum" as
        # `prefix` OR `sum` finds every function called `prefix`.
        for group in SYNONYMS, t in group
            occursin(' ', t) || continue
            text = replace(text, Regex("(?<![\"\\w])" * t * "(?![\"\\w])", "i") => "\"" * t * "\"")
        end
    end
    groups = Vector{String}[]
    have = Set{String}()
    matches = collect(eachmatch(r"\"([^\"]*)\"|([\p{L}\p{N}_!]+)", text))
    # Unquoted stopwords go, unless the request is nothing else.
    stop(m) = m.captures[2] !== nothing && lowercase(m.captures[2]) in STOPWORDS
    all(stop, matches) || filter!(!stop, matches)
    for m in matches
        phrase = something(m.captures[1], m.captures[2])
        t = quoted(phrase)
        (t == "\"\"" || lowercase(t) in have) && continue
        push!(have, lowercase(t))
        g = [t]
        for s in (expand ? synonyms(phrase) : String[])
            st = quoted(s)
            lowercase(st) in have && continue
            push!(have, lowercase(st))
            push!(g, length(s) <= 3 ? short * st : st)
        end
        push!(groups, g)
    end
    isempty(groups) && throw(ArgumentError("nothing to search for in $(repr(text))"))
    return groups
end

"""
An FTS5 query for free text: the terms of all its concepts (`termgroups`) OR-ed, so a
definition matching more of them ranks higher.
"""
ftsquery(text::AbstractString; expand::Bool = true, short::AbstractString = SHORTCOLUMNS) =
    join(Iterators.flatten(termgroups(text; expand, short)), " OR ")

# A good match in a package people use, exported and documented, is the better answer.
# Between packages it weighs less: a package's relevance is a sum over its best matches,
# so a widely used package that matches one word in passing (LLVM, "assembly") would
# otherwise beat the package that is about the topic.
# A local package has no download count; in the projects it was written for, it is as
# good an answer as a widely used one.
const LOCALUSERS = 10_000

popularity(users::Integer, islocal::Bool; weight = 0.12) = 1 + weight * log1p(islocal ? LOCALUSERS : users)

"""
Filter clauses on the package id in `column`: only packages depending (strongly, or
weakly through an extension) on one of `uses`, and with `gpu` only packages that work
on GPUs (`packages.gpu`).
"""
function filterclause(uses, gpu::Bool, column::AbstractString = "d.package")
    clause = gpu ? " AND $column IN (SELECT id FROM packages WHERE gpu = 1)" : ""
    uses === nothing && return clause, ()
    names = collect(String, uses)
    isempty(names) && return clause, ()
    return clause * " AND $column IN (SELECT package FROM deps WHERE kind != 'test' AND name IN ($(join(fill("?", length(names)), ", "))))",
           Tuple(names)
end

"""
    search(idx, text; limit = 20, kind = nothing, package = nothing, uses = nothing, gpu = false) -> Vector{Hit}

Definitions whose name, signature or docstring match `text`, best first: BM25 with a
name match weighing most, then favouring exported, documented definitions of packages
people use. A query that is one name (`sortperm`, `AK.sortperm!`) lists the definitions
of that name (with or without `!`) first. `kind` (`"function"`, `"struct"`, `"module"`,
`"readme"`, `"docs"`, …), `package`, `uses` (dependency names) and `gpu` narrow it;
READMEs and docs pages are only searched when `kind` asks for them.
"""
function search(idx::Index, text::AbstractString; limit::Integer = 20, kind = nothing,
                package = nothing, uses = nothing, gpu::Bool = false,
                semantic::Union{Nothing,Semantic} = nothing, exclude = String[])
    filters = kind === nothing ? " AND d.kind NOT IN ('readme', 'docs')" : " AND d.kind = ?"
    args = kind === nothing ? Any[] : Any[string(kind)]
    package === nothing || (filters *= " AND p.name = ?"; push!(args, string(package)))
    if !isempty(exclude)
        filters *= " AND p.name NOT IN ($(join(fill("?", length(exclude)), ", ")))"
        append!(args, exclude)
    end
    uclause, uargs = filterclause(uses, gpu)
    filters *= uclause
    append!(args, uargs)
    name, owner = queryname(text)
    named = name === nothing ? NamedTuple[] :
            sort!(rows(idx, """SELECT $HITCOLUMNS, -1.0 AS score FROM defs d JOIN packages p ON p.id = d.package
                               WHERE d.basename IN (?, ?)$filters ORDER BY users DESC LIMIT ?""",
                       (name, name * "!", args..., max(200, 4limit)));
                  by = r -> (r.package == owner, hitweight(r)), rev = true)
    q = focusedquery(idx, text)
    rs = rows(idx, """SELECT $HITCOLUMNS, bm25(defs_fts, 10.0, 6.0, 3.0, 1.0) AS score
                      FROM defs_fts f JOIN defs d ON d.id = f.rowid JOIN packages p ON p.id = d.package
                      WHERE defs_fts MATCH ?$filters ORDER BY score LIMIT ?""", (q, args..., max(200, 4limit)))
    sort!(rs; by = hitweight, rev = true)
    if name === nothing && package === nothing
        # A need put in words ("parse command line arguments") is often what a package is
        # about, and its functions' docstrings need not say it: the best definitions of the
        # packages most about it (`rankpackages`, by topic alone) are fused in.
        top = topical(idx, q, filters, args, first(rankpackages(idx, text; uses, gpu, usage = false, semantic, exclude), 10))
        byid = Dict(r.id => r for r in Iterators.flatten((rs, top)))
        rs = [byid[id] for id in fuse([[r.id for r in rs], [r.id for r in top]])]
    end
    # One method per function and package: `definition` lists the others.
    seen = Set{Tuple{String,String,String}}()
    hits = Hit[]
    for r in Iterators.flatten((named, rs))
        length(hits) == limit && break
        key = (r.package, r.module, r.name)
        key in seen && continue
        push!(seen, key)
        push!(hits, Hit(r))
    end
    return hits
end

"""How good a matching definition is as an answer: its BM25 score, used, exported, documented, not generated."""
hitweight(r) = -r.score * popularity(r.users, r.islocal == 1) * (r.exported == 1 ? 1.3 : 1.0) *
            (isempty(r.doc) ? 1.0 : 1.2) * (r.generated == 1 ? 0.5 : 1.0)

"""
The best `per` definitions matching `q` (under `filters`, whose arguments are `args`) of
each package in `pkgs`, the packages in that order.
"""
function topical(idx::Index, q::AbstractString, filters::AbstractString, args, pkgs::Vector{Int}; per::Integer = 2)
    out = NamedTuple[]
    for pid in pkgs
        # A package's definitions are stored together, so their ids span a range, which
        # FTS5 seeks to instead of walking every match of `q`. In a subquery of its own
        # (its LIMIT keeps it one), so that SQLite does not drive the join from `defs` and
        # run the MATCH once per definition.
        r = only(rows(idx, "SELECT min(id) AS lo, max(id) AS hi FROM defs WHERE package = ?", (pid,)))
        r.lo === missing && continue
        rs = rows(idx, """SELECT $HITCOLUMNS, m.score
                          FROM (SELECT rowid AS id, bm25(defs_fts, 10.0, 6.0, 3.0, 1.0) AS score FROM defs_fts
                                WHERE defs_fts MATCH ? AND rowid BETWEEN ? AND ? ORDER BY score LIMIT 50) m
                          JOIN defs d ON d.id = m.id JOIN packages p ON p.id = d.package
                          WHERE d.package = ? AND d.kind != 'module'$filters""", (q, r.lo, r.hi, pid, args...))
        append!(out, sort!(rs; by = hitweight, rev = true)[1:min(end, per)])
    end
    return out
end

"""
    search(idx, texts; limit = 20, kind, package, uses, gpu) -> Vector{Hit}

Definitions for any of several phrasings of one need: each phrasing's best `3limit`
hits fused by reciprocal rank (see `fuse`), so what several phrasings find comes first.
"""
function search(idx::Index, texts::AbstractVector{<:AbstractString}; limit::Integer = 20, kind = nothing,
                package = nothing, uses = nothing, gpu::Bool = false,
                semantic::Union{Nothing,Semantic} = nothing, exclude = String[])
    lists = [search(idx, t; limit = 3limit, kind, package, uses, gpu, semantic, exclude) for t in unique(texts)]
    byid = Dict(h.id => h for list in lists for h in list)
    return [byid[id] for id in first(fuse([[h.id for h in list] for list in lists]), limit)]
end

"""
The name a query is, without its module and `!`, and the module written before it:
`AcceleratedKernels.sortperm!` is `("sortperm", "AcceleratedKernels")`; prose is `(nothing, nothing)`.
"""
function queryname(text::AbstractString)
    s = strip(text)
    occursin(r"^@?[\p{L}_][\p{L}\p{N}_!.]*$", s) || return nothing, nothing
    parts = split(s, '.')
    return String(rstrip(parts[end], '!')), length(parts) > 1 ? String(parts[1]) : nothing
end

"""A package, as package queries return it."""
struct PackageHit
    name::String
    version::String
    repo::String
    users::Int
    islocal::Bool
    matches::Int                # definitions, README and docs pages matching the query
    examples::Vector{String}    # the best matching definitions, `name` or `Module.name`
    gpu::Bool
    gpudeps::Vector{String}     # GPU packages it depends on, extends or tests with
    summary::String             # the README's first paragraph, else its module docstring's
    found::Vector{String}       # which of several phrasings found it (see `packages`)
    matched::Vector{String}     # the query's concepts the package's text has
    missed::Vector{String}      # and those it has not: a package matching only "simulation" is a weak answer
end

gpudeps(idx::Index, pid::Integer) =
    [r.name for r in rows(idx, """SELECT DISTINCT name FROM deps WHERE package = ? AND
                                  name IN ($(join(fill("?", length(GPU_DEPS)), ", "))) ORDER BY name""",
                          (pid, GPU_DEPS...))]

"""
    rankpackages(idx, text; uses = nothing, gpu = false, usage = true, semantic = nothing) -> Vector{Int}

Ids of the packages about `text`, best first, and with `usage` the most used first among
equally good matches. Rankings are fused by reciprocal rank: the package as a whole
document (`described`), the package as the sum of its matching definitions
(`aggregated`), and with a `Semantic`, the package by meaning (`semanticrank`). They
fail differently: a package mentioning a common word all over its README wins the
first, one with many weakly matching docstrings the second, and only the third finds a
package that never uses the query's words. `uses` keeps only packages depending on one
of those names, `gpu` only packages that work on GPUs.
"""
function rankpackages(idx::Index, text::AbstractString; uses = nothing, gpu::Bool = false, usage::Bool = true,
                      semantic::Union{Nothing,Semantic} = nothing, exclude = String[])
    lists = [described(idx, text; uses, gpu), aggregated(idx, text; uses, gpu)]
    semantic === nothing || push!(lists, semanticrank(semantic, idx, text; uses, gpu))
    score = fusion(lists)
    foreach(id -> delete!(score, id), packageids(idx, exclude))
    (isempty(score) || !usage) && return sort!(collect(keys(score)); by = id -> score[id], rev = true)
    # Among packages the two rankings agree on, the one people use is the better answer.
    use = Dict(r.id => popularity(r.users, r.islocal == 1; weight = 0.05)
               for r in rows(idx, "SELECT p.id, $USAGE FROM packages p WHERE p.id IN ($(join(keys(score), ", ")))"))
    return sort!(collect(keys(score)); by = id -> score[id] * use[id], rev = true)
end

"""Each id's sum over the lists of 1 / (k + its rank): reciprocal rank fusion."""
function fusion(lists; k = 10)
    score = Dict{Int,Float64}()
    for list in lists, (r, id) in enumerate(list)
        score[id] = get(score, id, 0.0) + 1 / (k + r)
    end
    return score
end

"""Ids ranked by reciprocal rank fusion of the lists (see `fusion`)."""
fuse(lists; k = 10) = (score = fusion(lists; k); sort!(collect(keys(score)); by = id -> score[id], rev = true))

# BM25 over one document per package (`packages_fts`: its name, README and module
# docstring, docs pages, and its definitions' names and docstring openings, stemmed): the
# rarity of a word is how few packages use it, and a package saying "simulation" a
# hundred times counts little more than one saying it five times. A query of a few
# words also counts as a phrase: "point cloud" is not "point" or "cloud".
function described(idx::Index, text::AbstractString; uses = nothing, gpu::Bool = false)
    q = ftsquery(text; short = "")
    words = [m.match for m in eachmatch(WORD, text)]
    length(words) in 2:4 && (q = quoted(join(words, " ")) * " OR " * q)
    uclause, uargs = filterclause(uses, gpu, "p.id")
    rs = rows(idx, """SELECT p.id, bm25(packages_fts, 10.0, 10.0, 5.0, 1.0) AS score, $USAGE
                      FROM packages_fts f JOIN packages p ON p.id = f.rowid
                      WHERE packages_fts MATCH ?$uclause ORDER BY score LIMIT 300""", (q, uargs...))
    sort!(rs; by = r -> -r.score * popularity(r.users, r.islocal == 1; weight = 0.15), rev = true)
    return Int[r.id for r in rs]
end

# The package as its matching definitions, README and docs pages: their scores summed
# with harmonically falling weights (the best counts fully, the second half, …; a README
# match weighs most, then the module docstring, then docs pages and definitions), times
# the share of the query's concepts it matches.
function aggregated(idx::Index, text::AbstractString; uses = nothing, gpu::Bool = false)
    concepts, counts, n = focused(idx, text)
    q = join(Iterators.flatten(concepts), " OR ")
    uclause, uargs = filterclause(uses, gpu)
    # FTS5 cannot evaluate bm25() inside an aggregate, so matches are scored in a
    # subquery; its LIMIT keeps SQLite from flattening it into the GROUP BY (and bounds
    # the work for very common words to their best 50000 matches).
    # Names weigh little here: whether a package is about a topic shows in its prose; a
    # type named `Particles` does not make a package about particle simulation.
    groups = rows(idx, """SELECT m.package AS id, sum(m.score / m.r) AS score, $USAGE
                          FROM (SELECT package, score, ROW_NUMBER() OVER (PARTITION BY package ORDER BY score) AS r
                                FROM (SELECT d.package, bm25(defs_fts, 2.0, 2.0, 1.0, 1.0) *
                                             (CASE d.kind WHEN 'readme' THEN 10 WHEN 'module' THEN 8
                                                          WHEN 'docs' THEN 3 ELSE 1 END) AS score
                                      FROM defs_fts f JOIN defs d ON d.id = f.rowid
                                      WHERE defs_fts MATCH ?$uclause
                                      ORDER BY bm25(defs_fts, 2.0, 2.0, 1.0, 1.0) LIMIT 50000)) m
                          JOIN packages p ON p.id = m.package
                          GROUP BY m.package ORDER BY score LIMIT 300""", (q, uargs...))
    coverage = Dict(g.id => 1.0 for g in groups)
    length(concepts) > 1 && !isempty(groups) && coverage!(coverage, idx, concepts, counts, n)
    sort!(groups; by = g -> -g.score * coverage[g.id] * popularity(g.users, g.islocal == 1; weight = 0.05), rev = true)
    return Int[g.id for g in groups]
end

"""
    focused(idx, text) -> (concepts, counts, n)

The concepts of `text` (`termgroups`) worth scoring definitions by, how many of the `n`
definitions match each: a word in every fiftieth definition ("function", "in", "run")
adds little to a score and costs scoring hundreds of thousands of matches, so it is left
out while a rarer concept remains.
"""
function focused(idx::Index, text::AbstractString)
    concepts = termgroups(text)
    n = only(rows(idx, "SELECT max(id) AS n FROM defs")).n
    counts = [only(rows(idx, "SELECT count(*) AS n FROM defs_fts WHERE defs_fts MATCH ?", (join(c, " OR "),))).n
              for c in concepts]
    keep = counts .<= 0.02n
    any(keep) || (keep[argmin(counts)] = true)
    return concepts[keep], counts[keep], n
end

"""The FTS5 query for the concepts of `text` worth scoring by (see `focused`)."""
focusedquery(idx::Index, text::AbstractString) = join(Iterators.flatten(first(focused(idx, text))), " OR ")

# A package matching some of the concepts ("assembly" in LLVM's docs, for "finite
# element" assembly) is weighted by the square of the share it covers, each concept
# weighing by its rarity among the `n` definitions (`counts` match it): in "cloth
# simulation" the topic is cloth, which 8 definitions mention, not simulation, which
# 13000 do.
function coverage!(coverage::Dict{Int,Float64}, idx::Index, concepts, counts, n)
    ids = join(keys(coverage), ", ")
    got = Dict(id => 0.0 for id in keys(coverage))
    total = 0.0
    for (c, nc) in zip(concepts, counts)
        cq = join(c, " OR ")
        w = log(1 + (n - nc + 0.5) / (nc + 0.5))
        total += w
        for r in rows(idx, """SELECT DISTINCT d.package FROM defs_fts f JOIN defs d ON d.id = f.rowid
                              WHERE defs_fts MATCH ? AND d.package IN ($ids)""", (cq,))
            got[r.package] += w
        end
    end
    foreach(id -> coverage[id] = (got[id] / total)^2, keys(got))
    return coverage
end

"""
Package `id` as a hit for the FTS5 query `q` (see `focusedquery`): its facts, how many of
its definitions match and the best ones, and which concepts of `need` (the query a
caller put first) its text has.
"""
function packagehit(idx::Index, id::Integer, q::AbstractString, found::Vector{String}, need::AbstractString)
    p = only(rows(idx, "SELECT p.name, p.version, p.repo, p.summary, p.gpu, $USAGE FROM packages p WHERE p.id = ?", (id,)))
    # Over the package's id range, so FTS5 does not walk every match of `q`, and in a
    # subquery its LIMIT keeps one (see `topical`).
    r = only(rows(idx, "SELECT min(id) AS lo, max(id) AS hi FROM defs WHERE package = ?", (id,)))
    m = rows(idx, """SELECT d.module, d.name, d.kind, m.score
                     FROM (SELECT rowid AS id, bm25(defs_fts, 10.0, 6.0, 3.0, 1.0) AS score FROM defs_fts
                           WHERE defs_fts MATCH ? AND rowid BETWEEN ? AND ? LIMIT 1000000) m
                     JOIN defs d ON d.id = m.id WHERE d.package = ? ORDER BY m.score""", (q, r.lo, r.hi, id))
    n = length(m)
    ex = first(filter(x -> !(x.kind in ("module", "readme", "docs")), m), 4)
    matched, missed = String[], String[]
    concepts = termgroups(need; short = "")
    for c in (length(concepts) > 1 ? concepts : ())
        has = !isempty(rows(idx, "SELECT rowid FROM packages_fts WHERE packages_fts MATCH ? AND rowid = ?", (join(c, " OR "), id)))
        push!(has ? matched : missed, strip(first(c), '"'))
    end
    return PackageHit(p.name, p.version, p.repo, p.users, p.islocal == 1, n, [relname(p.name, r.module, r.name) for r in ex],
                      p.gpu == 1, gpudeps(idx, id), p.summary, found, matched, missed)
end

"""
    packages(idx, text; uses = nothing, gpu = false, limit = 15) -> Vector{PackageHit}
    packages(idx, texts; uses = nothing, gpu = false, limit = 15) -> Vector{PackageHit}

Packages about `text` (see `rankpackages`), or about any of several phrasings of one
need, as an expert would put it ("contact simulation", "collision response", "frictional
contact"): the phrasings' rankings are fused like `rankpackages` fuses its two, so a
package found under several names ranks above one found under one. Its hit lists the
phrasings that rank it among their best 50, and which concepts of the first it has.
"""
function packages(idx::Index, text::AbstractString; uses = nothing, gpu::Bool = false, limit::Integer = 15,
                  semantic::Union{Nothing,Semantic} = nothing, exclude = String[])
    q = focusedquery(idx, text)
    return [packagehit(idx, id, q, String[], text) for id in first(rankpackages(idx, text; uses, gpu, semantic, exclude), limit)]
end

function packages(idx::Index, texts::AbstractVector{<:AbstractString}; uses = nothing, gpu::Bool = false,
                  limit::Integer = 15, semantic::Union{Nothing,Semantic} = nothing, exclude = String[])
    texts = unique(String.(texts))
    ranked = [rankpackages(idx, t; uses, gpu, semantic, exclude) for t in texts]
    qs = [focusedquery(idx, t) for t in texts]
    hits = PackageHit[]
    for id in first(fuse(ranked), limit)
        at = [something(findfirst(==(id), r), typemax(Int)) for r in ranked]
        found = [t for (t, i) in zip(texts, at) if i <= 50]
        push!(hits, packagehit(idx, id, qs[argmin(at)], found, first(texts)))
    end
    return hits
end

"""`name` qualified by its module relative to package `pkg`: `f`, `Sub.f`, `PkgCUDAExt.f`."""
function relname(pkg::AbstractString, mod::AbstractString, name::AbstractString)
    mod == pkg && return String(name)
    startswith(mod, pkg * ".") && return mod[length(pkg)+2:end] * "." * name
    return mod * "." * name
end

"""
    definition(idx, id) -> Hit
    definition(idx, package, name) -> Vector{Hit}

One definition by id, or every definition named `name` (as written, or its last
component: `show` finds `Base.show`) in `package`.
"""
function definition(idx::Index, id::Integer)
    r = rows(idx, "SELECT $HITCOLUMNS FROM defs d JOIN packages p ON p.id = d.package WHERE d.id = ?", (id,))
    isempty(r) && throw(KeyError(id))
    return Hit(only(r))
end
definition(idx::Index, package::AbstractString, name::AbstractString) =
    Hit.(rows(idx, """SELECT $HITCOLUMNS FROM defs d JOIN packages p ON p.id = d.package
                      WHERE p.name = ? AND (d.name = ? OR d.basename = ?) ORDER BY d.file, d.line""",
              (package, name, shortname(name))))

"""
    implementers(idx, name; limit = 50) -> Vector{Hit}

Methods of the function `name` across the ecosystem: `Tables.rows` finds methods
written `Tables.rows(…)` and `rows(…)` (the latter in packages that use Tables, or
wherever when `name` is unqualified). The most used packages first.
"""
function implementers(idx::Index, name::AbstractString; limit::Integer = 50)
    parts = split(name, '.')
    base = String(parts[end])
    owner = length(parts) > 1 ? join(parts[1:end-1], ".") : nothing
    cond = owner === nothing ? "d.basename = ?" :
           "d.basename = ? AND (d.name = ? OR (d.name = ? AND p.name = ?) OR (d.name = ? AND EXISTS (SELECT 1 FROM deps x WHERE x.package = d.package AND x.name = ?)))"
    args = owner === nothing ? (base,) : (base, name, base, owner, base, owner)
    rs = rows(idx, """SELECT $HITCOLUMNS FROM defs d JOIN packages p ON p.id = d.package
                      WHERE $cond AND d.kind = 'function' ORDER BY users DESC, p.name LIMIT ?""", (args..., limit))
    return Hit.(rs)
end

"""
    dependents(idx, package; tests = false, limit = 100) -> Vector{NamedTuple}

Packages depending on `package` (`kind` is `"dep"` or `"weakdep"`, and `"test"` with
`tests`), the most used first.
"""
dependents(idx::Index, package::AbstractString; tests::Bool = false, limit::Integer = 100) =
    rows(idx, """SELECT p.name, x.kind, $USAGE
                 FROM deps x JOIN packages p ON p.id = x.package WHERE x.name = ?$(tests ? "" : " AND x.kind != 'test'")
                 ORDER BY users DESC LIMIT ?""", (package, limit))

"""What a package is: version, repository, users, dependencies, exports and its descriptions."""
struct PackageInfo
    name::String
    version::String
    repo::String
    users::Int
    islocal::Bool
    ndefs::Int
    ndependents::Int
    gpu::Bool
    deps::Vector{String}
    weakdeps::Vector{String}
    testdeps::Vector{String}
    exports::Vector{String}
    summary::String
    doc::String          # the top module's docstring
end

function package_info(idx::Index, name::AbstractString)
    p = rows(idx, "SELECT p.*, $USAGE FROM packages p WHERE p.name = ?", (name,))
    isempty(p) && throw(ArgumentError(unknownpackage(idx, name)))
    p = only(p)
    deps = rows(idx, "SELECT name, kind FROM deps WHERE package = ? ORDER BY name", (p.id,))
    exps = [r.name for r in rows(idx, "SELECT DISTINCT name FROM exports WHERE package = ? AND module = ? ORDER BY name", (p.id, name))]
    doc = rows(idx, "SELECT doc FROM defs WHERE package = ? AND kind = 'module' ORDER BY length(module) LIMIT 1", (p.id,))
    nd = only(rows(idx, "SELECT count(DISTINCT package) AS n FROM deps WHERE name = ? AND kind != 'test'", (name,))).n
    bykind(k) = String[r.name for r in deps if r.kind == k]
    return PackageInfo(p.name, p.version, p.repo, p.users, p.islocal == 1, p.ndefs, nd, p.gpu == 1, bykind("dep"), bykind("weakdep"),
                       bykind("test"), exps, p.summary, isempty(doc) ? "" : only(doc).doc)
end

"""Why there is no package `name`, and the names it may have meant."""
function unknownpackage(idx::Index, name::AbstractString)
    like = [r.name for r in rows(idx, "SELECT name FROM packages WHERE name LIKE ? ORDER BY length(name), name LIMIT 5",
                                 ("%" * name * "%",))]
    roots = [r.path for r in rows(idx, "SELECT path FROM localroots ORDER BY path")]
    return string("no package named ", name, " in the index, which holds the General registry's packages",
                  isempty(roots) ? "" : " and the unregistered ones under " * join(roots, ", "),
                  isempty(like) ? "" : "; similar names: " * join(like, ", "))
end

"""The source lines of a definition: from the cached package source, or a local package's directory."""
function source(idx::Index, h::Hit)
    root = h.islocal ? h.repo :
           joinpath(idx.sources, h.package,
                    only(rows(idx, "SELECT tree FROM packages WHERE name = ? AND version = ?", (h.package, h.version))).tree)
    lines = readlines(joinpath(root, h.file))
    return join(lines[h.line:min(end, h.line + h.nlines - 1)], "\n")
end

"""Every sketch in the index, in memory: what `similar` scans."""
struct SketchTable
    ids::Vector{Int}
    packages::Vector{Int}
    words::Matrix{UInt64}     # 4 × n
    row::Dict{Int,Int}        # definition id => column
end

"""
    sketches(idx; mintokens = MINTOKENS) -> SketchTable

Load the sketches of every definition with at least `mintokens` tokens that is not in a
generated file.
"""
function sketches(idx::Index; mintokens::Integer = MINTOKENS)
    ids, pkgs, words = Int[], Int[], UInt64[]
    for r in DBInterface.execute(idx.db, "SELECT id, package, sketch FROM defs WHERE ntokens >= ? AND generated = 0",
                                 (mintokens,))
        push!(ids, r.id)
        push!(pkgs, r.package)
        append!(words, reinterpret(UInt64, r.sketch))
    end
    return SketchTable(ids, pkgs, reshape(words, 4, :), Dict(id => i for (i, id) in enumerate(ids)))
end

"""
    nearest(t, sketch; limit, minsimilarity, exclude = Int[]) -> Vector{Tuple{Int,Float64}}

`(definition id, similarity)` of the sketches closest to `sketch`, leaving out the
packages with ids in `exclude`.
"""
function nearest(t::SketchTable, q::NTuple{4,UInt64}; limit::Integer = 20, minsimilarity = 0.5,
                 exclude = Int[])
    n = size(t.words, 2)
    dist = Vector{Int}(undef, n)
    Threads.@threads for j in 1:n
        @inbounds dist[j] = count_ones(t.words[1, j] ⊻ q[1]) + count_ones(t.words[2, j] ⊻ q[2]) +
                            count_ones(t.words[3, j] ⊻ q[3]) + count_ones(t.words[4, j] ⊻ q[4])
    end
    # similarity ≥ s  ⇔  distance ≤ 256 (1 - s) / 2
    maxdist = floor(Int, 256 * (1 - minsimilarity) / 2)
    cand = findall(d -> d <= maxdist, dist)
    isempty(exclude) || filter!(j -> !(t.packages[j] in exclude), cand)
    sort!(cand; by = j -> dist[j])
    return [(t.ids[j], 1 - 2 * dist[j] / 256) for j in cand[1:min(end, limit)]]
end

"""
    similar(idx, table, id; limit = 20, minsimilarity = 0.5) -> Vector{Tuple{Hit,Float64}}

Definitions whose sketch is closest to definition `id`'s, with the Jaccard similarity
the sketches estimate, excluding `id` itself.
"""
function similar(idx::Index, t::SketchTable, id::Integer; limit::Integer = 20, minsimilarity = 0.5)
    col = get(t.row, id, nothing)
    col === nothing && throw(ArgumentError("definition $id has no sketch (fewer than $MINTOKENS tokens, or generated)"))
    near = nearest(t, ntuple(k -> t.words[k, col], 4); limit = limit + 1, minsimilarity)
    return [(definition(idx, i), s) for (i, s) in near if i != id][1:min(end, limit)]
end

"""
    clones(idx; mintokens = 40, minpackages = 2, limit = 100) -> Vector{NamedTuple}

Functions and macros that are the same code up to renaming in at least `minpackages`
packages, widest spread first. Generated files and groups where one package holds
more than two copies (templates) are left out; `variants` counts the distinct exact
texts, `ids` lists the copies.
"""
function clones(idx::Index; mintokens::Integer = 40, minpackages::Integer = 2, limit::Integer = 100)
    return rows(idx, """SELECT renamed, count(*) AS copies, count(DISTINCT package) AS packages,
                            count(DISTINCT exact) AS variants, max(ntokens) AS ntokens, group_concat(id) AS ids
                        FROM defs WHERE ntokens >= ? AND generated = 0 AND kind IN ('function', 'macro')
                        GROUP BY renamed HAVING packages >= ? AND copies <= 2 * packages
                        ORDER BY packages DESC, ntokens DESC LIMIT ?""", (mintokens, minpackages, limit))
end
