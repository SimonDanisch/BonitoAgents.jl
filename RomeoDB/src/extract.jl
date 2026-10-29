# Definitions read off a package's source with JuliaSyntax. Nothing here runs package
# code: the walk starts at `src/<Name>.jl` (and each extension's entry file), follows
# `include`s with a literal path so every definition gets the module it is evaluated in,
# and records functions, macros, types and constants with their docstrings.

"""One definition as written: a method, a macro, a type, a constant or a documented module."""
struct Def
    modpath::String        # "DataFrames" or "DataFrames.Submodule"
    kind::Symbol           # :function :macro :struct :mutable :abstract :primitive :const :module
    name::String           # as written: "f", "Base.show", "(::S)"
    signature::String
    doc::String
    file::String           # relative to the package root
    line::Int
    nlines::Int
    decorators::String     # macros wrapped around it, "@inline @generated"
    generated::Bool        # the file says it is generated (ProtoBuf, OpenAPI clients, …)
    canon::Canon
end

"""The name a definition extends, without its module: `show` for `Base.show`."""
shortname(name::AbstractString) = startswith(name, "(") ? name : String(last(split(name, '.')))

"""
The words in a name, lowercase: `point_edge_distance2_gradient` → "point edge distance2
gradient", `SparseMatrixAssembler` → "sparse matrix assembler", `HTTPServer` → "http
server". A name is one search token; its words are what someone looking for it types.
"""
function namewords(name::AbstractString)
    s = replace(shortname(name), r"([a-z0-9])([A-Z])" => s"\1 \2", r"([A-Z]+)([A-Z][a-z])" => s"\1 \2")
    return lowercase(strip(replace(s, r"[_\W]+" => " ")))
end

# Generated files say so in their first lines; their copies are not anybody's duplication.
const GENERATED = r"auto-?generated|generated (by|with|using|from)|do not edit"i
isgenerated(text::AbstractString) = any(l -> occursin(GENERATED, l), Iterators.take(eachline(IOBuffer(text)), 10))

const NOCANON = Canon(0, 0, 0, 0, 1, (UInt64(0), UInt64(0), UInt64(0), UInt64(0)))

"""Everything extracted from one package version."""
struct PackageSource
    defs::Vector{Def}
    exports::Vector{Tuple{String,String,Bool}}   # (modpath, name, public-only)
    unresolved::Vector{String}                   # include arguments the walk could not follow
    errors::Vector{Tuple{String,String}}         # (file, message) of files that did not parse
end
PackageSource() = PackageSource(Def[], Tuple{String,String,Bool}[], String[], Tuple{String,String}[])

"""
    extract(root, name; extensions, orphans = false) -> PackageSource

Walk the package whose source tree is at `root`. `extensions` are its extension module
names; an extension's entry file is `ext/<Ext>.jl` or `ext/<Ext>/<Ext>.jl`. The README
and the Documenter pages become definitions of kind `:readme` and `:docs`: they are not
code, but they are where a package says what it is for. With `orphans`, the Julia files
under `src/` and `ext/` that no `include` reaches are walked too, as part of the
package's module: a generator script or a file left behind is still code that may
duplicate someone else's.
"""
function extract(root::AbstractString, name::AbstractString; extensions = String[], orphans::Bool = false)
    root = normpath(root)     # `include`d paths are normalized; the orphans' must compare equal
    out = PackageSource()
    seen = Set{String}()
    entry = joinpath(root, "src", name * ".jl")
    isfile(entry) && walkfile!(out, root, entry, "", seen)
    for ext in extensions
        for f in (joinpath(root, "ext", ext * ".jl"), joinpath(root, "ext", ext, ext * ".jl"))
            isfile(f) || continue
            walkfile!(out, root, f, "", seen)
            break
        end
    end
    if orphans
        for dir in filter(isdir, [joinpath(root, "src"), joinpath(root, "ext")]), (path, _, files) in walkdir(dir), f in files
            endswith(f, ".jl") && walkfile!(out, root, joinpath(path, f), name, seen)
        end
    end
    for (file, text) in textdocs(root)
        isvalid(text) || (push!(out.errors, (file, "not valid UTF-8")); continue)
        k = startswith(uppercase(file), "README") ? :readme : :docs
        push!(out.defs, Def(name, k, file, file, first(text, MAXDOC), file, 1, countlines(IOBuffer(text)),
                            "", false, NOCANON))
    end
    return out
end

const MAXDOC = 40_000   # characters of a README or docs page kept for search

function walkfile!(out::PackageSource, root, file, modpath, seen)
    file in seen && return
    push!(seen, file)
    walktext!(out, root, dirname(file), relpath(file, root), read(file, String), modpath, seen)
    return
end

function walktext!(out::PackageSource, root, dir, rel, text, modpath, seen)
    isvalid(text) || return push!(out.errors, (rel, "not valid UTF-8"))
    tree = JuliaSyntax.parseall(SyntaxNode, text; filename = rel, ignore_errors = true)
    walk!(WalkContext(out, root, dir, rel, seen, isgenerated(text), split(text, '\n')), tree, modpath, "", "")
    return
end

"""
    extract_code(code; modpath = "Main") -> PackageSource

The definitions in a piece of code, recorded as `extract` records a package's. Its
`include`s are not followed: there is no directory they could be relative to.
"""
function extract_code(code::AbstractString; modpath::AbstractString = "Main")
    out = PackageSource()
    walktext!(out, "", "", "snippet", String(code), modpath, Set{String}())
    return out
end

struct WalkContext
    out::PackageSource
    root::String
    dir::String       # directory `include` paths are relative to
    file::String      # current file, relative to `root`
    seen::Set{String}
    generated::Bool
    lines::Vector{SubString{String}}   # the file's, for the comments above definitions
end

"""
The comment block directly above line `line` (no blank line between), as text: what a
definition without a docstring says about itself, as Krylov's solvers and many others
do. Banner lines (`####`, `# ----`) are dropped.
"""
function leadingcomment(lines, line::Integer)
    out = String[]
    i = line - 1
    while i >= 1
        s = strip(lines[i])
        (startswith(s, '#') && !startswith(s, "#=")) || break
        push!(out, strip(lstrip(s, '#')))
        i -= 1
    end
    filter!(l -> !isempty(l) && !all(in("=-#*~_ "), l), reverse!(out))
    return join(out, "\n")
end

isleaf(n::SyntaxNode) = JuliaSyntax.is_leaf(n)
kids(n::SyntaxNode) = isleaf(n) ? SyntaxNode[] : children(n)

"""Visit `n`, a statement at module level of `modpath`. `doc` and `deco` are what wraps it."""
function walk!(ctx::WalkContext, n::SyntaxNode, modpath, doc, deco)
    k = kind(n)
    if k == K"toplevel" || k == K"block"
        # JuliaSyntax makes a `doc` node for a plain string before a definition, but a
        # `raw"…"`/`doc"…"`/`md"…"` docstring stays a statement of its own.
        cs = kids(n)
        i = 1
        while i <= length(cs)
            if i < length(cs) && isdocmacro(cs[i]) && documentable(cs[i+1])
                walk!(ctx, cs[i+1], modpath, docstring(cs[i]), "")
                i += 2
            else
                walk!(ctx, cs[i], modpath, "", "")
                i += 1
            end
        end
    elseif k == K"module"
        cs = kids(n)
        sub = isempty(modpath) ? identname(cs[1]) : modpath * "." * identname(cs[1])
        # A module's docstring is what describes the package; it is kept as a definition.
        isempty(doc) || push!(ctx.out.defs, Def(sub, :module, identname(cs[1]), "module " * identname(cs[1]),
                                               doc, ctx.file, JuliaSyntax.source_line(n), 1, "",
                                               ctx.generated, NOCANON))
        for c in cs[2:end]
            walk!(ctx, c, sub, "", "")
        end
    elseif k == K"doc"
        cs = kids(n)
        length(cs) == 2 && walk!(ctx, cs[2], modpath, docstring(cs[1]), deco)
    elseif k == K"macrocall"
        macrocall!(ctx, n, modpath, doc, deco)
    elseif k == K"if" || k == K"elseif"
        # `if VERSION >= v"1.x" … end` at module level: every branch defines something
        for c in kids(n)[2:end]
            walk!(ctx, c, modpath, "", "")
        end
    elseif k == K"export" || k == K"public"
        for c in kids(n)
            push!(ctx.out.exports, (modpath, sourcetext(c), k == K"public"))
        end
    elseif k == K"call"
        include!(ctx, n, modpath)
    elseif k in DEFKINDS
        define!(ctx, n, modpath, doc, deco)
    end
    return
end

const DEFKINDS = (K"function", K"macro", K"struct", K"abstract", K"primitive", K"const")

const DOCMACROS = (Symbol("@raw_str"), Symbol("@doc_str"), Symbol("@md_str"))
isdocmacro(n::SyntaxNode) = kind(n) == K"macrocall" && kind(kids(n)[1]) == K"StringMacroName" &&
                            kids(n)[1].val in DOCMACROS
documentable(n::SyntaxNode) = kind(n) in DEFKINDS || kind(n) in (K"module", K"macrocall")

# A `MacroName` leaf's source text has no `@`; its value does. `Base.@kwdef` is a `.` node.
macroname(n::SyntaxNode) = isleaf(n) ? string(n.val) : sourcetext(n)

function macrocall!(ctx, n, modpath, doc, deco)
    cs = kids(n)
    mname = macroname(cs[1])
    if mname == "@doc" && length(cs) >= 3
        walk!(ctx, cs[3], modpath, docstring(cs[2]), deco)
        return
    end
    # The definition a macro decorates (`@inline f(x) = …`, `@kernel function …`), and
    # the code it wraps: `@static if …` around a module's body, `@require Pkg="…"
    # include("glue.jl")`.
    for c in cs[2:end]
        kind(c) in DEFKINDS || kind(c) in (K"macrocall", K"doc", K"if", K"block", K"call") || continue
        walk!(ctx, c, modpath, doc, isempty(deco) ? mname : deco * " " * mname)
    end
    return
end

"""Follow `include("file.jl")` and `include(joinpath(@__DIR__, …))` with literal parts."""
function include!(ctx, n, modpath)
    cs = kids(n)
    (length(cs) == 2 && kind(cs[1]) == K"Identifier" && cs[1].val === :include) || return
    isempty(ctx.dir) && return      # a snippet (`extract_code`): nothing to include from
    path = includepath(cs[2])
    if path === nothing
        push!(ctx.out.unresolved, ctx.file * ": " * sourcetext(cs[2]))
        return
    end
    f = normpath(joinpath(ctx.dir, path))
    isfile(f) && walkfile!(ctx.out, ctx.root, f, modpath, ctx.seen)
    return
end

function includepath(a::SyntaxNode)
    s = literalstring(a)
    s === nothing || return s
    kind(a) == K"call" || return nothing
    cs = kids(a)
    (kind(cs[1]) == K"Identifier" && cs[1].val === :joinpath) || return nothing
    parts = String[]
    for c in cs[2:end]
        if kind(c) == K"MacroName" || (kind(c) == K"macrocall" && sourcetext(c) == "@__DIR__")
            continue
        end
        s = literalstring(c)
        s === nothing && return nothing
        push!(parts, s)
    end
    return isempty(parts) ? nothing : joinpath(parts...)
end

function literalstring(n::SyntaxNode)
    kind(n) == K"string" || return nothing
    cs = kids(n)
    all(c -> kind(c) == K"String", cs) || return nothing
    return join(String(c.val) for c in cs)
end

"""The docstring text, interpolations kept as source; `raw"…"`, `doc"…"` and `md"…"` unwrapped."""
function docstring(n::SyntaxNode)
    if kind(n) == K"macrocall"
        for c in kids(n)
            kind(c) == K"string" && return docstring(c)
        end
        return sourcetext(n)
    end
    kind(n) == K"string" || return sourcetext(n)
    io = IOBuffer()
    for c in kids(n)
        kind(c) == K"String" ? print(io, c.val) : print(io, "\$(", sourcetext(c), ")")
    end
    return String(take!(io))
end

function define!(ctx, n, modpath, doc, deco)
    k = kind(n)
    cs = kids(n)
    isempty(cs) && return
    sig = cs[1]
    defkind, name = if k == K"function"
        :function, callname(sig)
    elseif k == K"macro"
        :macro, "@" * callname(sig)
    elseif k == K"struct"
        (JuliaSyntax.has_flags(n, JuliaSyntax.MUTABLE_FLAG) ? :mutable : :struct), typename(sig)
    elseif k == K"abstract"
        :abstract, typename(sig)
    elseif k == K"primitive"
        :primitive, typename(sig)
    else # const
        lhs = kind(sig) == K"=" ? kids(sig)[1] : sig
        :const, sourcetext(lhs)
    end
    line = JuliaSyntax.source_line(n)
    lastline = JuliaSyntax.source_line(n.source, JuliaSyntax.last_byte(n))
    signature = k == K"const" ? name : sourcetext(sig)
    isempty(doc) && (doc = leadingcomment(ctx.lines, line))
    push!(ctx.out.defs, Def(modpath, defkind, name, signature, doc, ctx.file, line,
                            lastline - line + 1, deco, ctx.generated, canonical(n, name)))
    return
end

"""The name a method is defined for, as written: `f`, `Base.show`, `(::S)`, `S{T}`."""
function callname(sig::SyntaxNode)
    k = kind(sig)
    if k == K"where" || k == K"::" && !isleaf(sig) && kind(kids(sig)[1]) in (K"call", K"where")
        return callname(kids(sig)[1])
    elseif k == K"call" || k == K"dotcall"
        cs = kids(sig)
        callee = JuliaSyntax.is_infix_op_call(sig) ? cs[2] : cs[1]
        kind(callee) == K"::" && return "(" * sourcetext(callee) * ")"
        return sourcetext(callee)
    else
        return sourcetext(sig)   # `function f end`
    end
end

"""The type a `struct`/`abstract`/`primitive` declares, without parameters or supertype."""
function typename(sig::SyntaxNode)
    k = kind(sig)
    if k == K"<:" || k == K"curly"
        return typename(kids(sig)[1])
    end
    return sourcetext(sig)
end

identname(n::SyntaxNode) = isleaf(n) ? string(n.val) : sourcetext(n)
