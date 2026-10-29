# The canonical form of a definition, and what is computed from it.
#
# A definition becomes a pre-order token stream over its syntax tree: each inner node is
# its kind and arity (which fixes the tree without closing tokens), each leaf its value.
# Two hashes come from it. `exact` keeps every identifier and literal, so equal hashes
# mean the same code up to whitespace and comments. `renamed` replaces the names a
# definition binds itself (arguments, locals, loop variables, type parameters, its own
# name) by their order of first use and literals by their kind, so equal hashes mean the
# same code up to renaming. The renamed stream also gives a 256-bit sketch, a one-
# permutation MinHash keeping one bit per bin, whose Hamming distance estimates the
# Jaccard similarity of two definitions' 4-token shingles.
#
# Hashes are FNV-1a and splitmix64 over token text, so they are stable across sessions
# and Julia versions, which a stored index needs and `Base.hash` does not promise.

"""What a definition hashes and measures to."""
struct Canon
    exact::UInt64
    renamed::UInt64
    ntokens::Int
    nodes::Int
    complexity::Int        # 1 + branches: if/elseif/while/for/&&/||/?/catch/filters
    sketch::NTuple{4,UInt64}
end

const SHINGLE = 4
const MINTOKENS = 16      # below this a definition gets no sketch: too few shingles

@inline function splitmix(x::UInt64)
    x += 0x9e3779b97f4a7c15
    x = (x ⊻ (x >> 30)) * 0xbf58476d1ce4e5b9
    x = (x ⊻ (x >> 27)) * 0x94d049bb133111eb
    return x ⊻ (x >> 31)
end

function fnv(s::AbstractString, h::UInt64 = 0xcbf29ce484222325)
    for b in codeunits(s)
        h = (h ⊻ b) * 0x00000100000001b3
    end
    return h
end

"""
    canonical(def::SyntaxNode, name) -> Canon

`name` is the name the definition defines; its occurrences are renamed like a local.
"""
function canonical(def::SyntaxNode, name::AbstractString)
    bound = Set{Symbol}()
    binders!(bound, def)
    selfname = Symbol(last(split(name, '.')))
    st = Stream(bound, selfname)
    tokens!(st, def)
    exact = reduce((h, t) -> splitmix(h ⊻ t), st.exact; init = UInt64(0))
    renamed = reduce((h, t) -> splitmix(h ⊻ t), st.renamed; init = UInt64(0))
    return Canon(exact, renamed, length(st.renamed), st.nodes, st.complexity, sketch(st.renamed))
end

mutable struct Stream
    bound::Set{Symbol}
    selfname::Symbol
    ids::Dict{Symbol,Int}     # bound name => order of first use
    exact::Vector{UInt64}
    renamed::Vector{UInt64}
    nodes::Int
    complexity::Int
end
Stream(bound, selfname) = Stream(bound, selfname, Dict{Symbol,Int}(), UInt64[], UInt64[], 0, 1)

const BRANCHES = (K"if", K"elseif", K"while", K"for", K"&&", K"||", K"?", K"catch", K"filter")

function tokens!(st::Stream, n::SyntaxNode)
    isleaf(n) && return leaf!(st, n)
    k = kind(n)
    cs = kids(n)
    interior!(st, k, length(cs))
    if k == K"." && length(cs) == 2 && kind(cs[2]) == K"Identifier"
        tokens!(st, cs[1])
        leaf!(st, cs[2]; rename = false)       # `a.b`: a field is named, not bound
    elseif k == K"function" || k == K"macro"
        signature!(st, cs[1])
        foreach(c -> tokens!(st, c), cs[2:end])
    elseif k in (K"call", K"dotcall", K"tuple", K"parameters")
        foreach(c -> keyed!(st, c, k == K"parameters"), cs)
    else
        foreach(c -> tokens!(st, c), cs)
    end
    return st
end

function interior!(st::Stream, k, nkids)
    st.nodes += 1
    k in BRANCHES && (st.complexity += 1)
    t = splitmix(fnv(string(k)) ⊻ UInt64(nkids))
    push!(st.exact, t)
    push!(st.renamed, t)
    return
end

# With `rename`, a name the definition binds becomes the order of its first use; one it
# does not bind (a global, a callee) stays as written.
function leaf!(st::Stream, n::SyntaxNode; rename::Bool = true)
    st.nodes += 1
    k = kind(n)
    kt = fnv(string(k))
    if k == K"Identifier" || k == K"MacroName"
        v = n.val::Symbol
        raw = fnv(string(v), kt)
        push!(st.exact, raw)
        if v === st.selfname
            push!(st.renamed, fnv("SELF", kt))
        elseif rename && v in st.bound
            push!(st.renamed, splitmix(kt ⊻ UInt64(get!(st.ids, v, length(st.ids) + 1))))
        else
            push!(st.renamed, raw)
        end
    else
        push!(st.exact, fnv(repr(n.val), kt))
        push!(st.renamed, kt)
    end
    return st
end

"""
A keyword or a field keeps its name, like a field after a dot: `name = value` in a call
or a named tuple, and after `;` (`params`) also `name`, `name::T` and `name::T = value`.
"""
function keyed!(st::Stream, c::SyntaxNode, params::Bool)
    k = kind(c)
    if params && keyname(c)
        k == K"Identifier" && return leaf!(st, c; rename = false)
        interior!(st, k, 2)
        leaf!(st, kids(c)[1]; rename = false)
        tokens!(st, kids(c)[2])
    elseif k == K"=" && numchildren(c) == 2 && (kind(kids(c)[1]) == K"Identifier" || params && keyname(kids(c)[1]))
        interior!(st, k, 2)
        keyed!(st, kids(c)[1], true)
        tokens!(st, kids(c)[2])
    else
        tokens!(st, c)
    end
    return st
end

keyname(n::SyntaxNode) = kind(n) == K"Identifier" ||
                         (kind(n) == K"::" && numchildren(n) == 2 && kind(kids(n)[1]) == K"Identifier")

# A signature's positional arguments are bound, defaults included (`f(x = 1)`); only its
# keywords, after the `;`, are named.
function signature!(st::Stream, sig::SyntaxNode)
    k = kind(sig)
    if !isleaf(sig) && k in (K"call", K"dotcall", K"where", K"::")
        cs = kids(sig)
        interior!(st, k, length(cs))
        k in (K"where", K"::") ? signature!(st, cs[1]) : tokens!(st, cs[1])
        foreach(c -> tokens!(st, c), cs[2:end])
    else
        tokens!(st, sig)
    end
    return st
end

"""
Names the definition binds: arguments, type parameters, assignment targets, loop and
comprehension variables, `let`/`local`/`do`/`->`/`catch` variables.
"""
function binders!(bound::Set{Symbol}, n::SyntaxNode)
    isleaf(n) && return bound
    k = kind(n)
    cs = kids(n)
    if k == K"call" || k == K"dotcall" || k == K"tuple"
        # `f(x; dims = 1)`, `(a = 1,)`: an `=` here names a keyword or a field and binds
        # nothing; only its value can contain bindings. (A signature's defaults are
        # bound by `argbinders!` from the `function` above.)
        for c in cs
            if kind(c) == K"parameters"
                foreach(p -> kwvalue!(bound, p), kids(c))
            else
                kwvalue!(bound, c)
            end
        end
        return bound
    elseif k == K"function" || k == K"macro" || k == K"->"
        argbinders!(bound, cs[1])
    elseif k == K"=" || k == K"op=" || k == K"local" || k == K"global"
        # `f(x) = …` arrives as `function`; here `=` is an assignment or a keyword default
        for c in (k == K"local" || k == K"global" ? cs : cs[1:1])
            targets!(bound, c)
        end
    elseif k == K"in" || k == K"iteration"
        kind(cs[1]) == K"in" || targets!(bound, cs[1])
    elseif k == K"do"
        length(cs) >= 2 && argbinders!(bound, cs[2])
    elseif k == K"catch"
        isempty(cs) || kind(cs[1]) != K"Identifier" || push!(bound, cs[1].val)
    elseif k == K"where"
        for c in cs[2:end]
            typevars!(bound, c)
        end
    end
    for c in cs
        binders!(bound, c)
    end
    return bound
end

kwvalue!(bound, c::SyntaxNode) =
    kind(c) == K"=" ? foreach(x -> binders!(bound, x), kids(c)[2:end]) : binders!(bound, c)

"""Arguments in a signature (or a `->`/`do` argument list); the callee is not one."""
function argbinders!(bound, sig::SyntaxNode)
    k = kind(sig)
    if k == K"where"
        argbinders!(bound, kids(sig)[1])
        foreach(c -> typevars!(bound, c), kids(sig)[2:end])
    elseif k == K"::" && !isleaf(sig) && kind(kids(sig)[1]) in (K"call", K"where")
        argbinders!(bound, kids(sig)[1])     # `f(x)::T`
    elseif k == K"call"
        cs = kids(sig)
        args = JuliaSyntax.is_infix_op_call(sig) ? cs[[1, 3]] : cs[2:end]
        foreach(c -> targets!(bound, c), args)
    else
        targets!(bound, sig)
    end
    return bound
end

"""Identifiers an assignment target or argument binds: `x`, `x::T`, `x = d`, `(a, b)`, `x...`."""
function targets!(bound, n::SyntaxNode)
    k = kind(n)
    if k == K"Identifier"
        push!(bound, n.val)
    elseif k == K"::" || k == K"=" || k == K"..."
        cs = kids(n)
        length(cs) >= 1 && (k != K"::" || length(cs) == 2) && targets!(bound, cs[1])
    elseif k == K"tuple" || k == K"parameters"
        foreach(c -> targets!(bound, c), kids(n))
    end
    return bound
end

function typevars!(bound, n::SyntaxNode)
    k = kind(n)
    if k == K"Identifier"
        push!(bound, n.val)
    elseif k == K"<:" || k == K">:"
        typevars!(bound, kids(n)[1])
    elseif k == K"braces"
        foreach(c -> typevars!(bound, c), kids(n))
    end
    return bound
end

"""
256-bin one-permutation MinHash of the 4-token shingles, one bit per bin. Empty bins
borrow from the next non-empty one (rotation densification), so short streams still give
comparable sketches.
"""
function sketch(tokens::Vector{UInt64})
    length(tokens) < MINTOKENS && return (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    mins = fill(typemax(UInt64), 256)
    for i in 1:(length(tokens) - SHINGLE + 1)
        h = UInt64(0)
        for j in 0:(SHINGLE - 1)
            h = splitmix(h ⊻ tokens[i + j])
        end
        bin = (h >> 56) + 1
        mins[bin] = min(mins[bin], h)
    end
    for b in 1:256
        mins[b] == typemax(UInt64) || continue
        d = 1
        while mins[mod1(b + d, 256)] == typemax(UInt64)
            d += 1
        end
        mins[b] = splitmix(mins[mod1(b + d, 256)] ⊻ UInt64(d))
    end
    words = zeros(UInt64, 4)
    for b in 1:256
        isodd(mins[b] >> 1) && (words[(b - 1) ÷ 64 + 1] |= UInt64(1) << ((b - 1) % 64))
    end
    return (words[1], words[2], words[3], words[4])
end

"""Jaccard similarity two sketches estimate: P(bits agree) = (1 + J) / 2."""
similarity(a::NTuple{4,UInt64}, b::NTuple{4,UInt64}) =
    max(0.0, 2 * (1 - sum(count_ones.(a .⊻ b)) / 256) - 1)
