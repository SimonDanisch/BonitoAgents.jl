# "Does this already exist?" for code: a snippet, or a whole local package.

"""
What the index holds like one definition: copies by exact and renamed hash, near copies
by sketch, and exported functions of the same name. The last is not about the code: a
`meshgrid` written with comprehensions shares no structure with the nine `meshgrid`s
using `repeat`, and is still the same function.
"""
struct Match
    query::Def
    exact::Vector{Hit}                  # the same text up to whitespace and comments
    renamed::Vector{Hit}                # the same code up to renaming locals and literals
    near::Vector{Tuple{Hit,Float64}}    # similar by sketch, with the estimated similarity
    samename::Vector{Hit}               # exported functions of the same name, most used first
end

packageids(idx::Index, names) =
    isempty(names) ? Int[] : Int[r.id for r in rows(idx, "SELECT id FROM packages WHERE name IN ($(join(fill("?", length(names)), ", ")))", Tuple(names))]

# `exclude` holds package ids from this database, so they are spliced in as integers.
function hashhits(idx::Index, column::AbstractString, h::UInt64, exclude::Vector{Int}, limit)
    excl = isempty(exclude) ? "" : " AND d.package NOT IN ($(join(exclude, ", ")))"
    return Hit.(rows(idx, """SELECT $HITCOLUMNS FROM defs d JOIN packages p ON p.id = d.package
                             WHERE d.$column = ? AND d.generated = 0$excl ORDER BY users DESC LIMIT ?""",
                     (reinterpret(Int64, h), limit)))
end

"""
    findlike(idx, table, def; limit = 5, minsimilarity = 0.5, exclude = Int[]) -> Match

What exists like `def`, outside the packages with ids in `exclude`. Namesakes are only
looked up when there is no copy: next to a copy, they are noise.
"""
function findlike(idx::Index, t::SketchTable, d::Def; limit::Integer = 5, minsimilarity = 0.5,
                  exclude::Vector{Int} = Int[])
    c = d.canon
    exact = c.ntokens == 0 ? Hit[] : hashhits(idx, "exact", c.exact, exclude, limit)
    renamed = c.ntokens == 0 ? Hit[] :
              filter(h -> !any(e -> e.id == h.id, exact), hashhits(idx, "renamed", c.renamed, exclude, limit))
    seen = Set(h.id for h in Iterators.flatten((exact, renamed)))
    near = Tuple{Hit,Float64}[]
    if c.ntokens >= MINTOKENS
        for (i, s) in nearest(t, c.sketch; limit = limit + length(seen), minsimilarity, exclude)
            i in seen || push!(near, (definition(idx, i), s))
        end
    end
    foreach(((h, _),) -> push!(seen, h.id), near)
    named = isempty(exact) && isempty(renamed) ? samename(idx, d, seen, exclude, limit) : Hit[]
    return Match(d, exact, renamed, near[1:min(end, limit)], named)
end

"""The hit closest to the query: a copy before a near copy."""
closest(m::Match) = !isempty(m.exact) ? first(m.exact) : !isempty(m.renamed) ? first(m.renamed) : first(m.near)[1]

"""Exported functions named like `d` (unqualified: `Base.show` methods are not "the same"), not in `seen`."""
function samename(idx::Index, d::Def, seen, exclude::Vector{Int}, limit)
    (d.kind in (:function, :macro) && !occursin('.', d.name) && d.name != "snippet") || return Hit[]
    excl = isempty(exclude) ? "" : " AND d.package NOT IN ($(join(exclude, ", ")))"
    rs = rows(idx, """SELECT $HITCOLUMNS FROM defs d JOIN packages p ON p.id = d.package
                      WHERE d.name = ? AND d.kind = ? AND d.generated = 0$excl
                      AND EXISTS (SELECT 1 FROM exports e WHERE e.package = d.package AND e.module = d.module
                                  AND e.name = d.name)
                      ORDER BY users DESC LIMIT ?""", (d.name, string(d.kind), limit + length(seen)))
    hits = Hit[]
    have = Set{String}()          # one method per package is enough to point at it
    for r in rs
        (r.id in seen || r.package in have) && continue
        push!(have, r.package)
        push!(hits, Hit(r))
    end
    return hits[1:min(end, limit)]
end

"""
    similar_code(idx, table, code; limit = 5, minsimilarity = 0.5, exclude = String[]) -> Vector{Match}

For each definition in `code`, what the ecosystem already has like it. Code without a
definition (a bare expression) is matched as the body of a function. `exclude` names
packages to leave out, typically the one the code is from.
"""
function similar_code(idx::Index, t::SketchTable, code::AbstractString; limit::Integer = 5,
                      minsimilarity = 0.5, exclude = String[])
    isempty(strip(code)) && throw(ArgumentError("no code to compare"))
    src = extract_code(code)
    defs = filter(d -> d.kind != :module, src.defs)
    if isempty(defs)
        defs = extract_code("function snippet()\n" * code * "\nend").defs
        isempty(defs) && throw(ArgumentError("the code does not parse into a definition or expression"))
    end
    ex = packageids(idx, exclude)
    return [findlike(idx, t, d; limit, minsimilarity, exclude = ex) for d in defs]
end

"""
    find_existing(idx, table, code, purpose; alternatives = [], exclude = [], limit = 5, semantic = nothing)

Compare complete function definitions with indexed code, and search for implementations
and packages by their purpose. Structural similarity and relevance are separate evidence;
neither establishes equivalent behavior. `exclude` applies to all three result groups.
"""
function find_existing(idx::Index, table::SketchTable, code::AbstractString, purpose::AbstractString;
                       alternatives = String[], exclude = String[], limit::Integer = 5,
                       minsimilarity = 0.5, semantic::Union{Nothing,Semantic} = nothing)
    isempty(strip(purpose)) && throw(ArgumentError("purpose must describe what the code accomplishes"))
    1 <= limit <= 20 || throw(ArgumentError("limit must be between 1 and 20"))
    0 <= minsimilarity <= 1 || throw(ArgumentError("min_similarity must be between 0 and 1"))
    matches = similar_code(idx, table, code; limit, minsimilarity, exclude)
    texts = unique(filter(!isempty, strip.([purpose; alternatives])))
    definitions = search(idx, texts; limit, exclude, semantic)
    candidates = packages(idx, texts; limit, exclude, semantic)
    return (; matches, definitions, packages = candidates)
end

"""
    audit(idx, table, root; name = basename(root), mintokens = 40, minsimilarity = 0.8, limit = 3)
        -> Vector{Match}

Every definition of the local package at `root` (entry `src/<name>.jl`, and the files
under `src/` and `ext/` no `include` reaches) with at least `mintokens` tokens that has
a copy or near copy elsewhere in the ecosystem, the package itself (if registered) left
out. Largest, closest first.
"""
function audit(idx::Index, t::SketchTable, root::AbstractString; name::AbstractString = basename(normpath(root)),
               mintokens::Integer = 40, minsimilarity = 0.8, limit::Integer = 3)
    name = replace(name, r"\.jl$" => "")
    isfile(joinpath(root, "src", name * ".jl")) ||
        throw(ArgumentError("no package entry file $(joinpath(root, "src", name * ".jl"))"))
    src = extract(root, name; extensions = extensions(root), orphans = true)
    ex = packageids(idx, [name])
    found = Match[]
    for d in src.defs
        (d.canon.ntokens >= mintokens && !d.generated && d.kind in (:function, :macro)) || continue
        m = findlike(idx, t, d; limit, minsimilarity, exclude = ex)
        isempty(m.exact) && isempty(m.renamed) && isempty(m.near) || push!(found, m)
    end
    best(m) = isempty(m.exact) && isempty(m.renamed) ? first(m.near)[2] : 1.0
    sort!(found; by = m -> (best(m), m.query.canon.ntokens), rev = true)
    return found
end
