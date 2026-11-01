# The index on disk: one SQLite file. Hashes are stored as signed 64-bit integers (their
# bits), the sketch as a 32-byte blob, and `defs_fts` is an FTS5 index over name, its words,
# signature and docstring with `defs` as its content table.

const SCHEMA = [
    # `summary`: the README's first paragraph (else the module docstring's). `gpu`: the
    # package depends on, extends or tests with a GPU package, or its README/docs say GPU.
    """CREATE TABLE IF NOT EXISTS packages (
        id INTEGER PRIMARY KEY, uuid TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL,
        tree TEXT NOT NULL UNIQUE, repo TEXT NOT NULL, status TEXT NOT NULL, ndefs INTEGER NOT NULL,
        summary TEXT NOT NULL, gpu INTEGER NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS packages_name ON packages(name)",
    """CREATE TABLE IF NOT EXISTS defs (
        id INTEGER PRIMARY KEY, package INTEGER NOT NULL REFERENCES packages(id),
        module TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL, basename TEXT NOT NULL, words TEXT NOT NULL,
        signature TEXT NOT NULL, doc TEXT NOT NULL, file TEXT NOT NULL, line INTEGER NOT NULL,
        nlines INTEGER NOT NULL, decorators TEXT NOT NULL, generated INTEGER NOT NULL,
        exact INTEGER NOT NULL, renamed INTEGER NOT NULL, ntokens INTEGER NOT NULL,
        nodes INTEGER NOT NULL, complexity INTEGER NOT NULL, sketch BLOB NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS defs_package ON defs(package)",
    "CREATE INDEX IF NOT EXISTS defs_name ON defs(name)",
    "CREATE INDEX IF NOT EXISTS defs_basename ON defs(basename)",
    "CREATE INDEX IF NOT EXISTS defs_exact ON defs(exact)",
    "CREATE INDEX IF NOT EXISTS defs_renamed ON defs(renamed)",
    """CREATE TABLE IF NOT EXISTS exports (
        package INTEGER NOT NULL REFERENCES packages(id), module TEXT NOT NULL,
        name TEXT NOT NULL, public INTEGER NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS exports_name ON exports(name)",
    """CREATE TABLE IF NOT EXISTS deps (
        package INTEGER NOT NULL REFERENCES packages(id), name TEXT NOT NULL, kind TEXT NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS deps_name ON deps(name)",
    "CREATE INDEX IF NOT EXISTS deps_package ON deps(package)",
    # Over the past year, from the package servers' public logs: distinct non-CI
    # addresses (`users`) and all successful requests.
    """CREATE TABLE IF NOT EXISTS downloads (
        uuid TEXT PRIMARY KEY, users INTEGER NOT NULL, requests INTEGER NOT NULL)""",
    # Directories holding unregistered packages of this machine, indexed with status
    # `local` (see `addlocal!`).
    "CREATE TABLE IF NOT EXISTS localroots (path TEXT PRIMARY KEY)",
    # One embedding per package (Float32, unit length), when an embedder made them;
    # see `embed_packages!`.
    "CREATE TABLE IF NOT EXISTS vectors (package INTEGER PRIMARY KEY REFERENCES packages(id), vec BLOB NOT NULL)",
    """CREATE TABLE IF NOT EXISTS problems (
        package INTEGER NOT NULL REFERENCES packages(id), kind TEXT NOT NULL,
        file TEXT NOT NULL, message TEXT NOT NULL)""",
    """CREATE VIRTUAL TABLE IF NOT EXISTS defs_fts USING fts5(
        name, words, signature, doc, content = 'defs', content_rowid = 'id',
        tokenize = "unicode61 tokenchars '_!'")""",
    # One document per package, for ranking packages by topic (see `described`): its
    # name, README and module docstring, docs pages, and its definitions' names and
    # docstring openings, stemmed. It keeps no text of its own; `reindex_text!` fills it.
    """CREATE VIRTUAL TABLE IF NOT EXISTS packages_fts USING fts5(
        name, about, docs, api, content = '', tokenize = "porter unicode61")""",
]

"""The index: its data directory, the SQLite file in it and the package server."""
struct Index
    dir::String
    sources::String
    db::SQLite.DB
    server::String
end

"""
    Index(dir; server = "https://pkg.julialang.org") -> Index

Open (or create) the index in `dir`: `dir/romeo.sqlite`, sources cached in `dir/sources`.
The on-disk filename is retained across the package rename so existing indexes reopen.
"""
function Index(dir::AbstractString; server = "https://pkg.julialang.org")
    mkpath(dir)
    db = SQLite.DB(joinpath(dir, "romeo.sqlite"))
    exec!(db, "PRAGMA journal_mode = WAL")
    exec!(db, "PRAGMA synchronous = NORMAL")
    foreach(s -> exec!(db, s), SCHEMA)
    return Index(String(dir), mkpath(joinpath(dir, "sources")), db, server)
end

# A statement whose rows nobody reads stays in progress until it is collected, and an
# open statement makes the next transaction fail ("cannot open savepoint"): close it.
exec!(db::SQLite.DB, sql::AbstractString, args = ()) =
    DBInterface.close!(DBInterface.execute(db, sql, args))

Base.show(io::IO, idx::Index) = print(io, "RomeoDB.Index(", repr(idx.dir), ")")

"""
    rows(idx, sql, args = ()) -> Vector{NamedTuple}

The result of a query, materialised: SQLite.jl rows are only valid while iterated.
"""
function rows(idx::Index, sql::AbstractString, args = ())
    out = NamedTuple[]
    for r in DBInterface.execute(idx.db, sql, args)
        names = Tuple(propertynames(r))
        push!(out, NamedTuple{names}(map(n -> getproperty(r, n), names)))
    end
    return out
end

"""Tree hashes already stored, whatever their status: a rebuild skips them."""
indexed(idx::Index) =
    Set(row.tree for row in DBInterface.execute(idx.db, "SELECT tree FROM packages"))

sketchbytes(s::NTuple{4,UInt64}) = collect(reinterpret(UInt8, collect(s)))
sketchof(b::AbstractVector{UInt8}) = Tuple(reinterpret(UInt64, b))::NTuple{4,UInt64}

"""
    store!(idx, p, status, src, deps = []; replace = Int[]) -> package id

Write one package, everything extracted from it and its dependencies (`(name, kind)`,
as `dependencies` reads them), in one transaction, which also forgets the packages with
ids in `replace`: a reader sees the old version or the new one.
"""
function store!(idx::Index, p::PackageVersion, status::AbstractString, src::PackageSource,
                deps = Tuple{String,String}[]; replace::Vector{Int} = Int[])
    db = idx.db
    pid = 0
    SQLite.transaction(db) do
        forget!(idx, replace)
        DBInterface.execute(db, """INSERT INTO packages (uuid, name, version, tree, repo, status, ndefs, summary, gpu)
                                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                            (string(p.uuid), p.name, string(p.version), string(p.tree), p.repo,
                             status, length(src.defs), packagesummary(src), Int(isgpu(src, deps))))
        pid = SQLite.last_insert_rowid(db)
        dep = DBInterface.prepare(db, "INSERT INTO deps (package, name, kind) VALUES (?, ?, ?)")
        for (name, kind) in deps
            DBInterface.execute(dep, (pid, name, kind))
        end
        ins = DBInterface.prepare(db, """INSERT INTO defs (package, module, kind, name, basename, words,
            signature, doc, file, line, nlines, decorators, generated, exact, renamed, ntokens,
            nodes, complexity, sketch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""")
        for d in src.defs
            c = d.canon
            DBInterface.execute(ins, (pid, d.modpath, string(d.kind), d.name, shortname(d.name), namewords(d.name),
                                      d.signature, d.doc, d.file, d.line, d.nlines, d.decorators,
                                      Int(d.generated), reinterpret(Int64, c.exact),
                                      reinterpret(Int64, c.renamed), c.ntokens, c.nodes,
                                      c.complexity, sketchbytes(c.sketch)))
        end
        exp = DBInterface.prepare(db, "INSERT INTO exports (package, module, name, public) VALUES (?, ?, ?, ?)")
        for (m, n, public) in src.exports
            DBInterface.execute(exp, (pid, m, n, Int(public)))
        end
        prob = DBInterface.prepare(db, "INSERT INTO problems (package, kind, file, message) VALUES (?, ?, ?, ?)")
        for (f, msg) in src.errors
            DBInterface.execute(prob, (pid, "parse", f, msg))
        end
        for u in src.unresolved
            DBInterface.execute(prob, (pid, "include", "", u))
        end
    end
    return pid
end

const GPUWORDS = r"\b(GPUs?|CUDA|AMDGPU|ROCm|KernelAbstractions|Metal\.jl|oneAPI)\b"

"""A package works on GPUs: it depends on, extends or tests with one, or its docs say so."""
isgpu(src::PackageSource, deps) =
    any(((n, _),) -> n in GPU_DEPS, deps) ||
    any(d -> d.kind in (:readme, :docs) && occursin(GPUWORDS, d.doc), src.defs)

"""Whether a README line is markup rather than prose."""
notprose(s::AbstractString) =
    startswith(s, '#') || startswith(s, '!') || startswith(s, '<') || startswith(s, '|') ||
    startswith(s, "[!") || occursin(r"^\[[^\]]+\]:", s) || occursin(r"badge|shields\.io"i, s) ||
    startswith(s, "SPDX-") || startswith(s, "---")

"""
The first paragraph of prose in the README (headings, badges, images, HTML, link
definitions, code blocks and paragraphs of fewer than five words such as a bare title
skipped; links reduced to their text, emphasis removed), else the first line of the top
module's docstring.
"""
packagesummary(src::PackageSource) =
    packagesummary([d.doc for d in src.defs if d.kind == :readme], [d.doc for d in src.defs if d.kind == :module])

function packagesummary(readmes::AbstractVector{<:AbstractString}, moduledocs::AbstractVector{<:AbstractString})
    for readme in readmes
        # HTML first, whole: a tag spread over lines (`<img` / `src="logo.svg"` / `/>`)
        # would otherwise leave its attributes behind as a paragraph.
        readme = replace(readme, r"<!--.*?-->"s => "", r"<[^>]*>" => " ")
        para = String[]
        infence = false
        for l in Iterators.flatten((eachline(IOBuffer(readme)), ("",)))
            s = strip(l)
            if startswith(s, "```")
                infence = !infence
                continue
            end
            infence && continue
            if isempty(s)
                text = replace(join(para, " "), r"\[([^\]]*)\]\([^)]*\)" => s"\1", r"[*`]" => "",
                               r"(?<!\w)_|_(?!\w)" => "")
                length(split(text)) >= 5 && return first(text, 300)
                empty!(para)
                continue
            end
            notprose(s) || push!(para, s)
        end
    end
    return isempty(moduledocs) ? "" : summary(first(moduledocs))
end

"""
    resummarize!(idx) -> number of packages

Recompute every package's summary from its stored README and module docstring, after a
change to `packagesummary`.
"""
function resummarize!(idx::Index)
    ps = rows(idx, "SELECT id FROM packages")
    upd = DBInterface.prepare(idx.db, "UPDATE packages SET summary = ? WHERE id = ?")
    SQLite.transaction(idx.db) do
        for p in ps
            docs = rows(idx, "SELECT kind, doc FROM defs WHERE package = ? AND kind IN ('readme', 'module') ORDER BY id", (p.id,))
            DBInterface.execute(upd, (packagesummary(String[d.doc for d in docs if d.kind == "readme"],
                                                     String[d.doc for d in docs if d.kind == "module"]), p.id))
        end
    end
    return length(ps)
end

"""
    forget!(idx, ids) -> number of packages removed

Remove packages (by id) and everything stored about them, so `build!` indexes them
again: after a fix to extraction, or to replace a version. Run `reindex_text!` after.
"""
function forget!(idx::Index, ids::AbstractVector{<:Integer})
    isempty(ids) && return 0
    list = join(Int.(ids), ", ")
    SQLite.transaction(idx.db) do
        for t in ("defs", "exports", "deps", "problems", "vectors")
            exec!(idx.db, "DELETE FROM $t WHERE package IN ($list)")
        end
        exec!(idx.db, "DELETE FROM packages WHERE id IN ($list)")
    end
    return length(ids)
end

"""Rebuild the full-text indexes, of definitions and of packages, from `defs`; run once after a build."""
function reindex_text!(idx::Index)
    db = idx.db
    exec!(db, "INSERT INTO defs_fts(defs_fts) VALUES ('rebuild')")
    SQLite.transaction(db) do
        exec!(db, "INSERT INTO packages_fts(packages_fts) VALUES ('delete-all')")
        ins = DBInterface.prepare(db, """INSERT INTO packages_fts (rowid, name, about, docs, api) SELECT ?1, ?2,
            (SELECT group_concat(doc, ' ') FROM defs WHERE package = ?1 AND kind IN ('readme', 'module')),
            (SELECT substr(group_concat(doc, ' '), 1, 100000) FROM defs WHERE package = ?1 AND kind = 'docs'),
            (SELECT substr(group_concat(words || ' ' || substr(doc, 1, 200), ' '), 1, 100000) FROM defs
             WHERE package = ?1 AND kind NOT IN ('readme', 'module', 'docs'))""")
        for r in rows(idx, "SELECT id, name FROM packages WHERE status IN ('ok', 'local')")
            DBInterface.execute(ins, (r.id, r.name * " " * namewords(r.name)))
        end
    end
    return
end
