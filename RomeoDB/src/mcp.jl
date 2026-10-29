# A Model Context Protocol server over stdio: JSON-RPC 2.0, one message per line. Each
# tool is a type answering `toolname`, `description`, `schema` and `call`; a tool that
# throws reports its error to the client as an `isError` result (with the backtrace on
# stderr), which is how the protocol carries tool failures.

const PROTOCOL = "2025-06-18"

# Read once, when RomeoDB is compiled. `pkgversion` takes the code-loading lock, which the
# main thread holds while it loads an embedder's packages, and `initialize` must not wait
# for that.
const ROMEODB_VERSION = TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))["version"]

const INSTRUCTIONS = """
RomeoDB indexes the source of every package in Julia's General registry (latest versions,
12k packages, 2.3M functions, types, macros and constants with docstrings), plus who
depends on whom and how many people use each package, and unregistered packages on this
machine (marked `local`, with their path). Use it BEFORE writing Julia code
that might already exist. Before implementing substantial Julia functionality, search
for its purpose and suitable packages. When checking drafted or existing functions, use
`find_existing` with their COMPLETE definitions (including the bodies), a short purpose
description and `exclude_packages` naming the current package. It combines body
comparison, purpose search and package discovery. Inspect promising results with
`definition` and `package_info` before recommending reuse; similarity is not proof of
equivalent behavior. Also use `search` for a function by what it does, `search_packages`
for a package covering a task (`gpu: true` for GPU ones; when unsure what the thing is
called, give several phrasings in `alternatives`), `similar_code` with the code
you are about to write (or found) to see existing implementations, `implementers` for
everyone extending a generic function, and `audit_package` on a local package to find
the functions it duplicates. Prefer reusing a widely used, exported function over
writing a new one."""

"""
An embedder on a task of its own that stays on its thread: Mantle submits from the
thread that created a device, so the embedder is made there, by `load()`, and every
query is embedded there. It loads in the background; [`ready`](@ref) says when.
"""
struct EmbedWorker
    requests::Channel{Tuple{String,Channel{Vector{Float32}}}}
    loaded::Threads.Atomic{Bool}
    task::Task
end

function EmbedWorker(load)
    requests = Channel{Tuple{String,Channel{Vector{Float32}}}}(Inf)
    loaded = Threads.Atomic{Bool}(false)
    task = Threads.@spawn :default begin
        current_task().sticky = true
        embedder = load()
        # `load` may have loaded the package that brings the `embedquery` method, after
        # this task began, hence `invokelatest`. A first call at a length compiles for
        # it, for half a minute; queries with their instruction are a few dozen tokens,
        # so those lengths are compiled now and the first search does not wait.
        Base.invokelatest(embedquery, embedder, "warm up")
        Base.invokelatest(embedquery, embedder, repeat("a longer query of several words ", 6))
        loaded[] = true
        @info "RomeoDB: semantic search ready"
        for (text, reply) in requests
            put!(reply, Base.invokelatest(embedquery, embedder, text))
        end
    end
    # A loader that throws leaves the server lexical, and says why on stderr.
    errormonitor(task)
    return EmbedWorker(requests, loaded, task)
end

ready(w::EmbedWorker) = w.loaded[]

"""
    loadqwen3embedding() -> loader

Load Qwen3EmbeddingRunner, RomeoDB's weak dependency, and return the function that loads
its model, for an [`EmbedWorker`](@ref): `serve(dir; embedder = loadqwen3embedding)`.

Two halves on two threads. Loading the package runs module initializers, and GLFW's
(under Mantle) insists on the main thread, so `serve` calls this there. The model is
made on the worker's thread, which then owns its device.
"""
function loadqwen3embedding()
    runner = Base.require(Base.PkgId(Base.UUID("a0da806b-184c-4dd8-a6a3-d2ae0c554ade"), "Qwen3EmbeddingRunner"))
    return () -> Base.invokelatest(runner.qwen3embedding)
end

function embedquery(w::EmbedWorker, text::AbstractString)
    reply = Channel{Vector{Float32}}(1)
    put!(w.requests, (String(text), reply))
    return take!(reply)
end

"""
The server's state: the index, its sketches once a similarity query needs them, the
embedder once it has loaded and the package vectors it ranks with, each with the
database version it was read at. `embedder` is set by `serve`'s main thread while the
request loop reads it on another, hence atomic.
"""
mutable struct Server
    idx::Index
    table::Union{Nothing,SketchTable}
    version::Int
    @atomic embedder::Union{Nothing,EmbedWorker}
    vectors::Union{Nothing,PackageVectors}
    vectorsversion::Int
end
Server(idx::Index, embedder::Union{Nothing,EmbedWorker} = nothing) = Server(idx, nothing, 0, embedder, nothing, 0)

# An `update!` in another process changes the database under a running server; SQLite
# counts such commits in `data_version`, and the sketches are read again after one.
dataversion(idx::Index) = only(rows(idx, "PRAGMA data_version")).data_version

function sketchtable!(s::Server)
    v = dataversion(s.idx)
    if s.table === nothing || v != s.version
        s.table = sketches(s.idx)
        s.version = v
    end
    return s.table
end

"""The semantic ranking the server can offer: none without an embedder, or before it has loaded."""
function semantic!(s::Server)
    embedder = @atomic s.embedder
    (embedder === nothing || !ready(embedder)) && return nothing
    v = dataversion(s.idx)
    if s.vectors === nothing || v != s.vectorsversion
        s.vectors = packagevectors(s.idx)
        s.vectorsversion = v
    end
    return Semantic(embedder, s.vectors)
end

abstract type Tool end

function required(a, key::Symbol, ::Type{T}) where {T}
    haskey(a, key) || throw(ArgumentError("missing argument `$key`"))
    return convert(T, a[key])
end
optional(a, key::Symbol, default::T) where {T} = haskey(a, key) && a[key] !== nothing ? convert(T, a[key]) : default
optionalnames(a, key::Symbol) = haskey(a, key) && a[key] !== nothing ? String.(collect(a[key])) : String[]

intprop(desc, default) = Dict("type" => "integer", "description" => desc, "default" => default)
strprop(desc) = Dict("type" => "string", "description" => desc)
boolprop(desc) = Dict("type" => "boolean", "description" => desc, "default" => false)
listprop(desc) = Dict("type" => "array", "items" => Dict("type" => "string"), "description" => desc)
objschema(props, req) = Dict("type" => "object", "properties" => props, "required" => req)

struct SearchTool <: Tool end
toolname(::SearchTool) = "search"
description(::SearchTool) = """
    Find Julia functions, types, macros and constants across all registered packages by
    what they do: matches names, signatures and docstrings, best and most used first.
    Use before implementing anything generic (sorting, interpolation, a solver, a
    kernel, a parser). Put "exact phrases" in double quotes; words are OR-ed and common
    algorithm names are expanded with their synonyms; a function name lists its
    definitions first. When unsure what the thing is called, add other phrasings in
    `alternatives`. `kind: "readme"` or `"docs"` searches READMEs or Documenter pages
    instead of code."""
schema(::SearchTool) = objschema(Dict(
    "query" => strprop("What you are looking for, e.g. \"radix sort\" GPU, or a function name"),
    "alternatives" => listprop("Other phrasings of the same need, each searched on its own"),
    "kind" => Dict("type" => "string",
                   "enum" => ["function", "macro", "struct", "mutable", "abstract", "const", "module", "readme", "docs"],
                   "description" => "Only definitions of this kind"),
    "package" => strprop("Only definitions in this package"),
    "gpu" => boolprop(GPUPROP),
    "limit" => intprop("How many results", 10)), ["query"])
function call(::SearchTool, s::Server, a)
    kind = optional(a, :kind, "")
    package = optional(a, :package, "")
    texts = [required(a, :query, String); optionalnames(a, :alternatives)]
    hits = search(s.idx, length(texts) == 1 ? only(texts) : texts; limit = optional(a, :limit, 10),
                  kind = isempty(kind) ? nothing : kind, package = isempty(package) ? nothing : package,
                  gpu = optional(a, :gpu, false), semantic = semantic!(s))
    return isempty(hits) ? "no matches" : astext(render, hits)
end

const GPUPROP = """Only packages that work on GPUs: they depend on, extend or test with CUDA, AMDGPU,
    Metal, oneAPI, KernelAbstractions, … or their README/docs say GPU. Generic-array packages that
    run on GPU arrays without any such mention are not caught, so try without it too."""

struct PackagesTool <: Tool end
toolname(::PackagesTool) = "search_packages"
description(::PackagesTool) = """
    Find Julia packages about a topic (README, docs and docstrings are searched), ranked
    by how well the package matches and how much it is used; shows each package's
    summary, GPU support and best matching definitions. Use to pick a dependency instead
    of writing a subsystem (FEM assembly, particle neighbour search, meshing, …). The
    words of `query` are one need: packages matching its rarer words rank first. When
    you are not sure what the thing is called, put other phrasings an expert might use
    (domain terms, method and algorithm names) in `alternatives`, e.g. "ocean
    simulation" with ["ocean model", "ocean circulation", "oceanography"]: packages
    found under several of them rank higher, and each hit says which found it. A hit
    matching only some words says which it lacks; one that has just the generic words
    ("simulation", "model") is no answer, and if no hit has the specific ones, the
    ecosystem likely has no package for it."""
schema(::PackagesTool) = objschema(Dict(
    "query" => strprop("The topic, e.g. \"finite element\" assembly, or \"smoothed particle\" SPH"),
    "alternatives" => listprop("Other phrasings of the same need, each searched on its own"),
    "gpu" => boolprop(GPUPROP),
    "uses" => listprop("Only packages depending on one of these packages"),
    "limit" => intprop("How many packages", 10)), ["query"])
function call(::PackagesTool, s::Server, a)
    uses = optionalnames(a, :uses)
    texts = [required(a, :query, String); optionalnames(a, :alternatives)]
    hits = packages(s.idx, length(texts) == 1 ? only(texts) : texts; uses = isempty(uses) ? nothing : uses,
                    gpu = optional(a, :gpu, false), limit = optional(a, :limit, 10), semantic = semantic!(s))
    return isempty(hits) ? "no packages match" : astext(render, hits)
end

struct SimilarCodeTool <: Tool end
toolname(::SimilarCodeTool) = "similar_code"
description(::SimilarCodeTool) = """
    Given Julia code (one or more function definitions, or an expression), list what the
    ecosystem already has like it: exact copies, copies up to renaming, near copies with
    an estimated similarity, and exported functions of the same name. Use on code you
    are about to write or have found, to reuse an existing implementation instead of
    duplicating it. It compares code structure: an implementation of the same thing
    written differently is found by `search` for its purpose, so do both."""
schema(::SimilarCodeTool) = objschema(Dict(
    "code" => strprop("Julia source"),
    "exclude_packages" => listprop("Packages to leave out, e.g. the one the code comes from"),
    "min_similarity" => Dict("type" => "number", "description" => "Lowest similarity to report (0–1)", "default" => 0.5),
    "limit" => intprop("Results per definition", 5)), ["code"])
function call(::SimilarCodeTool, s::Server, a)
    ms = similar_code(s.idx, sketchtable!(s), required(a, :code, String); limit = optional(a, :limit, 5),
                      minsimilarity = optional(a, :min_similarity, 0.5), exclude = optionalnames(a, :exclude_packages))
    return astext(render, ms)
end

struct FindExistingTool <: Tool end
toolname(::FindExistingTool) = "find_existing"
description(::FindExistingTool) = """
    Find existing Julia functionality before writing or keeping a substantial helper.
    Submit COMPLETE function definitions, including their bodies, and describe what
    they accomplish in `purpose`. Compares syntax across repositories and also searches
    definitions and packages by purpose. Exclude the current package. Results distinguish
    exact/renamed/structural matches from purpose matches and relevant packages. Scores
    measure structural resemblance, not correctness or equivalent behavior. Inspect
    candidates with `definition` and `package_info` before recommending reuse."""
schema(::FindExistingTool) = objschema(Dict(
    "code" => strprop("Complete Julia function definitions, including their bodies"),
    "purpose" => strprop("What the code accomplishes, described in plain language"),
    "alternatives" => listprop("Other phrasings of the same purpose"),
    "exclude_packages" => listprop("Packages to omit from every result group, usually the current package"),
    "min_similarity" => Dict("type" => "number", "minimum" => 0, "maximum" => 1,
                             "description" => "Lowest structural similarity to report", "default" => 0.5),
    "limit" => Dict("type" => "integer", "minimum" => 1, "maximum" => 20,
                    "description" => "Results per group (per definition for code matches)", "default" => 5)),
    ["code", "purpose"])
function call(::FindExistingTool, s::Server, a)
    result = find_existing(s.idx, sketchtable!(s), required(a, :code, String), required(a, :purpose, String);
        alternatives = optionalnames(a, :alternatives), exclude = optionalnames(a, :exclude_packages),
        limit = optional(a, :limit, 5), minsimilarity = optional(a, :min_similarity, 0.5), semantic = semantic!(s))
    return sprint() do io
        println(io, "Code matches (structural resemblance; inspect behavior before reusing):")
        foreach(m -> render(io, m), result.matches)
        println(io, "\nPossible implementations (matched by purpose):")
        isempty(result.definitions) ? println(io, "no matches") : foreach(h -> render(io, h), result.definitions)
        println(io, "\nRelevant packages (inspect with package_info):")
        isempty(result.packages) ? println(io, "no packages match") : foreach(p -> render(io, p), result.packages)
    end
end

struct DefinitionTool <: Tool end
toolname(::DefinitionTool) = "definition"
description(::DefinitionTool) = """
    The full docstring and source of a definition: every method named `name` in
    `package` (or one definition by the `id` other results show)."""
schema(::DefinitionTool) = objschema(Dict(
    "package" => strprop("Package name"),
    "name" => strprop("Function, type, macro or constant name, as written (`Base.show`) or bare (`show`)"),
    "id" => intprop("A definition id from another result", 0),
    "limit" => intprop("At most this many methods", 8)), String[])
function call(::DefinitionTool, s::Server, a)
    id = optional(a, :id, 0)
    hits = id != 0 ? [definition(s.idx, id)] :
           definition(s.idx, required(a, :package, String), required(a, :name, String))
    isempty(hits) && return "no definition of that name in that package"
    return sprint() do io
        for h in hits[1:min(end, optional(a, :limit, 8))]
            render(io, h; doc = false)
            isempty(h.doc) || println(io, "\n", first(strip(h.doc), 3000))
            src = source(s.idx, h)
            lines = split(src, '\n')
            println(io, "\n```julia\n", join(lines[1:min(end, 80)], '\n'),
                    length(lines) > 80 ? "\n# … $(length(lines) - 80) more lines" : "", "\n```\n")
        end
    end
end

struct ImplementersTool <: Tool end
toolname(::ImplementersTool) = "implementers"
description(::ImplementersTool) = """
    Methods of a generic function across the ecosystem, most used packages first: who
    implements `Tables.rows`, `Adapt.adapt_structure`, `Base.getindex`, … Use to find
    the interface packages follow and examples of implementing it."""
schema(::ImplementersTool) = objschema(Dict(
    "function" => strprop("The function, qualified by its owner (`Tables.rows`) or bare"),
    "limit" => intprop("How many methods", 30)), ["function"])
function call(::ImplementersTool, s::Server, a)
    hits = implementers(s.idx, required(a, :function, String); limit = optional(a, :limit, 30))
    return isempty(hits) ? "no methods found" : astext((io, h) -> render(io, h; doc = false), hits)
end

struct PackageInfoTool <: Tool end
toolname(::PackageInfoTool) = "package_info"
description(::PackageInfoTool) = "What a package is: description, users, dependencies, extensions and exports."
schema(::PackageInfoTool) = objschema(Dict("package" => strprop("Package name")), ["package"])
call(::PackageInfoTool, s::Server, a) = astext(package_info(s.idx, required(a, :package, String)))

struct DependentsTool <: Tool end
toolname(::DependentsTool) = "dependents"
description(::DependentsTool) = "Packages depending on a package (directly, or weakly through an extension), the most used first."
schema(::DependentsTool) = objschema(Dict("package" => strprop("Package name"),
                                          "limit" => intprop("How many", 50)), ["package"])
function call(::DependentsTool, s::Server, a)
    ds = dependents(s.idx, required(a, :package, String); limit = optional(a, :limit, 50))
    isempty(ds) && return "no registered package depends on it"
    return join(("$(d.name)  [$(d.kind), $(usage(d.users, d.islocal == 1))]" for d in ds), "\n")
end

struct AuditTool <: Tool end
toolname(::AuditTool) = "audit_package"
description(::AuditTool) = """
    Scan a local Julia package (its source directory) for functions that already exist
    elsewhere in the ecosystem as copies or near copies. Use on a package you work on to
    find duplicated code that a dependency could replace. Takes a while on big packages."""
schema(::AuditTool) = objschema(Dict(
    "path" => strprop("The package's root directory (containing src/)"),
    "name" => strprop("The package name, if it differs from the directory name"),
    "min_similarity" => Dict("type" => "number", "description" => "Lowest similarity to report (0–1)", "default" => 0.8),
    "limit" => intprop("How many functions to report", 30)), ["path"])
function call(::AuditTool, s::Server, a)
    root = required(a, :path, String)
    name = optional(a, :name, basename(normpath(root)))
    ms = audit(s.idx, sketchtable!(s), root; name, minsimilarity = optional(a, :min_similarity, 0.8))
    isempty(ms) && return "no function of $name has a copy or near copy in the index"
    n = optional(a, :limit, 30)
    return "$(length(ms)) functions of $name have copies or near copies. By file, with the files the closest copies are in:\n" *
           sprint(byfile, ms) * "\nThe $(min(n, length(ms))) closest:\n\n" * astext(render, ms[1:min(end, n)])
end

const TOOLS = (SearchTool(), PackagesTool(), SimilarCodeTool(), FindExistingTool(), DefinitionTool(), ImplementersTool(),
               PackageInfoTool(), DependentsTool(), AuditTool())

tooldict(t::Tool) = Dict("name" => toolname(t), "description" => description(t), "inputSchema" => schema(t))

# A bad argument or an unknown name is the caller's to fix, and the result says so;
# anything else is a bug here and goes to stderr with its backtrace.
logfailure(::Union{ArgumentError,KeyError}, bt, name) = nothing
logfailure(e, bt, name) = @error "romeodb: tool $name failed" exception = (e, bt)

reply(id, result) = Dict("jsonrpc" => "2.0", "id" => id, "result" => result)
replyerror(id, code, message) = Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => code, "message" => message))

"""
    handle(server, message) -> response or nothing

One JSON-RPC message; notifications (no `id`) get no response.
"""
function handle(s::Server, msg)
    method = get(msg, :method, "")
    id = get(msg, :id, nothing)
    if method == "initialize"
        client = get(get(msg, :params, Dict()), :protocolVersion, PROTOCOL)
        return reply(id, Dict("protocolVersion" => client, "capabilities" => Dict("tools" => Dict()),
                              "serverInfo" => Dict("name" => "romeodb", "version" => ROMEODB_VERSION),
                              "instructions" => INSTRUCTIONS))
    elseif id === nothing
        return nothing
    elseif method == "ping"
        return reply(id, Dict())
    elseif method == "tools/list"
        return reply(id, Dict("tools" => [tooldict(t) for t in TOOLS]))
    elseif method == "tools/call"
        params = msg[:params]
        name = String(params[:name])
        i = findfirst(t -> toolname(t) == name, TOOLS)
        i === nothing && return replyerror(id, -32602, "unknown tool $name")
        args = get(params, :arguments, Dict())
        text, iserror = try
            indexed = only(rows(s.idx, "SELECT EXISTS(SELECT 1 FROM packages WHERE status IN ('ok', 'local')) AS ready")).ready
            indexed == 1 || throw(ArgumentError(
                "RomeoDB's code index has not been downloaded or built yet ($(s.idx.dir)). " *
                "This is not evidence that the requested functionality does not exist."))
            call(TOOLS[i], s, args === nothing ? Dict() : args), false
        catch e
            e isa InterruptException && rethrow()
            logfailure(e, catch_backtrace(), name)
            sprint(showerror, e), true
        end
        return reply(id, Dict("content" => [Dict("type" => "text", "text" => text)], "isError" => iserror))
    else
        return replyerror(id, -32601, "method not found: $method")
    end
end

"""
    serve(dir; input = stdin, output = stdout, embedder = nothing)

Run the MCP server on the index in `dir` until `input` ends. Logs go to stderr; only
protocol messages are written to `output`.

`embedder`, such as [`loadqwen3embedding`](@ref), runs on the main thread and returns
the loader an [`EmbedWorker`](@ref) runs on a thread of its own; searches rank by
meaning too once that has finished. Requests are answered meanwhile: the loop runs on a
thread of its own, which leaves the main thread to package loading, whose initializers
may insist on it (GLFW's, under Mantle). An embedder that fails to load is logged and
the server stays lexical.
"""
function serve(dir::AbstractString; input::IO = stdin, output::IO = stdout, embedder = nothing)
    s = Server(Index(dir))
    loop = Threads.@spawn serveloop(s, input, output)
    if embedder !== nothing
        loader = try
            embedder()
        catch e
            @error "RomeoDB: the embedder did not load; searches stay lexical" exception = (e, catch_backtrace())
            nothing
        end
        loader === nothing || (@atomic s.embedder = EmbedWorker(loader))
    end
    wait(loop)
    return
end

function serveloop(s::Server, input::IO, output::IO)
    while !eof(input)
        line = readline(input)
        isempty(strip(line)) && continue
        resp = handle(s, JSON3.read(line))
        resp === nothing && continue
        println(output, JSON3.write(resp))
        flush(output)
    end
    return
end
