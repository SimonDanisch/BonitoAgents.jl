# Results as text for a reader that is usually a language model: one block per hit, the
# location first, then the signature, then the docstring's first informative line.

function human(n::Integer)
    n < 1000 && return string(n)
    n < 1_000_000 && return string(round(n / 1000; digits = 1), "k")
    return string(round(n / 1_000_000; digits = 1), "M")
end

"""How much a package is used, or that it is a local one (which has no download count)."""
usage(users::Integer, islocal::Bool) = islocal ? "local" : human(users) * " users"

oneline(s::AbstractString, n::Integer = 240) = first(replace(strip(s), r"\s+" => " "), n)

"""The first docstring line that says something: not an indented signature, not a fence."""
function summary(doc::AbstractString)
    for l in eachline(IOBuffer(doc))
        s = strip(l)
        (isempty(s) || startswith(l, "    ") || startswith(s, "```")) && continue
        return oneline(lstrip(s, '#'), 200)
    end
    return ""
end

function render(io::IO, h::Hit; doc::Bool = true)
    flags = [h.kind]
    h.exported && push!(flags, "exported")
    h.generated && push!(flags, "generated")
    println(io, h.package, ": ", relname(h.package, h.modpath, h.name), "  [", join(flags, ", "), "; ",
            usage(h.users, h.islocal), "]  ", h.islocal ? joinpath(h.repo, h.file) : h.file, ":", h.line,
            "  (id ", h.id, ")")
    h.kind == "module" || println(io, "    ", oneline(h.signature))
    s = summary(h.doc)
    doc && !isempty(s) && println(io, "    ", s)
    return
end

plural(n, word, words = word * "s") = n == 1 ? "1 $word" : "$n $words"

gpuline(gpu::Bool, deps) = !gpu ? "" : isempty(deps) ? "GPU: its README/docs say so" : "GPU: " * join(deps, ", ")

function render(io::IO, p::PackageHit)
    println(io, p.name, " ", p.version, "  [", usage(p.users, p.islocal), "]  ", p.repo)
    isempty(p.summary) || println(io, "    ", p.summary)
    g = gpuline(p.gpu, p.gpudeps)
    isempty(g) || println(io, "    ", g)
    println(io, "    ", plural(p.matches, "match", "matches"),
            isempty(p.examples) ? "" : ", e.g. " * join(p.examples, ", "))
    isempty(p.found) || println(io, "    found by: ", join(p.found, "; "))
    isempty(p.missed) || println(io, "    matches ", isempty(p.matched) ? "none of the words" : join(p.matched, ", "),
                                 "; not ", join(p.missed, ", "))
    return
end

function render(io::IO, m::Match)
    q = m.query
    println(io, "## ", q.name, ": ", oneline(q.signature, 160), "  (", q.file, ":", q.line, ")")
    if isempty(m.exact) && isempty(m.renamed) && isempty(m.near)
        println(io, "no copy or near copy in the index (code that does the same differently is ",
                "only found by `search` for its purpose)")
    end
    for (label, hits) in (("same code", m.exact), ("same code up to renaming", m.renamed))
        isempty(hits) && continue
        println(io, label, ":")
        foreach(h -> render(io, h), hits)
    end
    if !isempty(m.near)
        println(io, "similar:")
        for (h, s) in m.near
            print(io, "  ", round(Int, 100s), "% ")
            render(io, h)
        end
    end
    if !isempty(m.samename)
        println(io, "exported under the same name:")
        foreach(h -> render(io, h), m.samename)
    end
    return
end

"""Per local file, how many of its definitions have copies, and the files the closest copies are in."""
function byfile(io::IO, ms::Vector{Match})
    files = Dict{String,Dict{String,Int}}()
    for m in ms
        h = closest(m)
        counts = get!(files, m.query.file, Dict{String,Int}())
        counts[h.package * " " * h.file] = get(counts, h.package * " " * h.file, 0) + 1
    end
    for (file, counts) in sort!(collect(files); by = ((_, c),) -> -sum(values(c)))
        top = sort!(collect(counts); by = ((_, n),) -> -n)
        println(io, "  ", file, ": ", sum(values(counts)), ", like ",
                join(("$src ($n)" for (src, n) in top[1:min(end, 3)]), ", "), length(top) > 3 ? ", …" : "")
    end
    return
end

function render(io::IO, info::PackageInfo)
    println(io, info.name, " ", info.version, "  [", usage(info.users, info.islocal), ", ",
            plural(info.ndependents, "dependent"), ", ", plural(info.ndefs, "definition"), "]  ", info.repo)
    isempty(info.summary) || println(io, info.summary)
    isempty(info.doc) || println(io, "\n", first(strip(info.doc), 1500), "\n")
    g = gpuline(info.gpu, filter(in(GPU_DEPS), vcat(info.deps, info.weakdeps, info.testdeps)))
    isempty(g) || println(io, g)
    println(io, "deps: ", isempty(info.deps) ? "none" : join(info.deps, ", "))
    isempty(info.weakdeps) || println(io, "weak deps (extensions): ", join(info.weakdeps, ", "))
    isempty(info.testdeps) || println(io, "test deps: ", join(info.testdeps, ", "))
    println(io, "exports (", length(info.exports), "): ", join(info.exports[1:min(end, 150)], ", "),
            length(info.exports) > 150 ? ", …" : "")
    return
end

astext(f, xs) = sprint(io -> foreach(x -> f(io, x), xs))
astext(x) = sprint(io -> render(io, x))
