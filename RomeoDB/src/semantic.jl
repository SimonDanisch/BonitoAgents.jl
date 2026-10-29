# Ranking by meaning: one embedding per package, and the query's, compared by cosine.
# RomeoDB does not compute embeddings itself; an embedder is any value with methods for
# `embeddocument` and `embedquery` (the Qwen3EmbeddingRunner extension defines them for
# `Qwen3Embedding`), so the index stays usable, and lexical, without one.

"""
    embeddocument(embedder, text) -> Vector{Float32}

The unit-length embedding of a document. Methods come with an embedder.
"""
function embeddocument end

"""
    embedquery(embedder, text) -> Vector{Float32}

The unit-length embedding of a search query, comparable with `embeddocument`'s.
"""
function embedquery end

"""What a package is embedded as: its name, summary, module docstring and README opening."""
function packagetexts(idx::Index; missing_only::Bool = true)
    absent = missing_only ? " AND NOT EXISTS (SELECT 1 FROM vectors v WHERE v.package = p.id)" : ""
    rs = rows(idx, """SELECT p.id, p.name, p.summary,
                      coalesce((SELECT substr(doc, 1, 600) FROM defs WHERE package = p.id AND kind = 'module'
                                ORDER BY length(module) LIMIT 1), '') AS moddoc,
                      coalesce((SELECT substr(doc, 1, 1500) FROM defs WHERE package = p.id AND kind = 'readme'
                                LIMIT 1), '') AS readme
                      FROM packages p WHERE p.status IN ('ok', 'local')$absent ORDER BY p.id""")
    return [r.id => join(filter(!isempty, [r.name, r.summary, r.moddoc, r.readme]), "\n") for r in rs]
end

"""
    embed_packages!(idx, embedder; missing_only = true, progress = (done, total) -> nothing) -> count

Embed every package (by default only those without a vector yet) and store the vectors.
"""
function embed_packages!(idx::Index, embedder; missing_only::Bool = true, progress = (done, total) -> nothing)
    texts = packagetexts(idx; missing_only)
    ins = DBInterface.prepare(idx.db, "INSERT OR REPLACE INTO vectors (package, vec) VALUES (?, ?)")
    for (i, (id, text)) in enumerate(texts)
        v = embeddocument(embedder, text)
        DBInterface.execute(ins, (id, collect(reinterpret(UInt8, v))))
        progress(i, length(texts))
    end
    return length(texts)
end

"""Every package vector, in memory: what semantic ranking scans."""
struct PackageVectors
    ids::Vector{Int}
    mat::Matrix{Float32}      # (dims, packages), unit columns
end

function packagevectors(idx::Index)
    rs = rows(idx, "SELECT package, vec FROM vectors ORDER BY package")
    isempty(rs) && return PackageVectors(Int[], zeros(Float32, 0, 0))
    mat = reduce(hcat, [collect(reinterpret(Float32, r.vec)) for r in rs])
    return PackageVectors(Int[r.package for r in rs], mat)
end

"""An embedder and the package vectors it made: what `rankpackages` ranks by meaning with."""
struct Semantic{E}
    embedder::E
    vectors::PackageVectors
end

"""
    semanticrank(semantic, idx, text; uses = nothing, gpu = false, limit = 300) -> Vector{Int}

Package ids by cosine similarity of their vector to `text`'s, best first, among the
packages `uses` and `gpu` admit.
"""
function semanticrank(s::Semantic, idx::Index, text::AbstractString; uses = nothing, gpu::Bool = false,
                      limit::Integer = 300)
    isempty(s.vectors.ids) && return Int[]
    scores = s.vectors.mat' * embedquery(s.embedder, text)
    order = sortperm(scores; rev = true)
    uclause, uargs = filterclause(uses, gpu, "p.id")
    admitted = isempty(uclause) ? nothing :
               Set(r.id for r in rows(idx, "SELECT p.id FROM packages p WHERE 1 = 1$uclause", uargs))
    out = Int[]
    for i in order
        id = s.vectors.ids[i]
        admitted === nothing || id in admitted || continue
        push!(out, id)
        length(out) == limit && break
    end
    return out
end
