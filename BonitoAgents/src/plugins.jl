# Opt-in app packages installed in the active server environment.
#
# A package is a BonitoAgents plugin when its Project.toml contains:
#
#     [bonitoagents]
#     plugin = true
#
# It is loaded only when it is a *direct* dependency of the active environment,
# never merely because it happens to be installed transitively. Its `__init__`
# registers app types with `register_app!`. This lets `Pkg.add("MyApp")` extend
# an ordinary `julia -m BonitoAgents` server without a wrapper or local source
# edit to BonitoAgents.

const REGISTERED_APPS = DataType[]
const REGISTERED_APPS_LOCK = ReentrantLock()

"Register an app type from an opt-in plugin package. Registering twice is harmless."
function register_app!(A::Type{<:AgentApp})
    app_id(A) # fail here, with the useful missing-method error, rather than at server startup
    lock(REGISTERED_APPS_LOCK) do
        A in REGISTERED_APPS || push!(REGISTERED_APPS, A)
    end
    return A
end

"The app types registered by packages loaded as BonitoAgents plugins."
@noinline function registered_apps()
    # Plugin `__init__` runs after this package's precompile image is restored.
    # Do not let inference fold the then-empty const vector into a permanent
    # empty tuple in `serve`.
    apps = Base.inferencebarrier(REGISTERED_APPS)
    return lock(REGISTERED_APPS_LOCK) do
        Tuple(apps)
    end
end

plugin_marker(project::AbstractString) = begin
    isfile(project) || return false
    parsed = TOML.parsefile(project)
    section = get(parsed, "bonitoagents", nothing)
    section isa AbstractDict && get(section, "plugin", false) === true
end

"""
    load_plugins!() -> Tuple

Load the direct dependencies of the active environment whose Project.toml marks
them as plugins, and return the app types they register. Only theirs: a package
that registered an app but is no plugin (one an admin's chat loaded, a test's)
doesn't start with the next server.
"""
load_plugins!() = load_plugins!(Base.active_project())
load_plugins!(::Nothing) = ()

function load_plugins!(active::AbstractString)
    # The desktop app's active project is a file in its data dir that nothing has
    # written yet on a first start: no file, no dependencies, so no plugins.
    isfile(active) || return ()
    # Read the active project's `[deps]` rather than Pkg.dependencies(): the
    # latter may hold the package's precompile-time context when called from a
    # server package. `locate_package` resolves each declared UUID against the
    # actual active manifest, including the service user's depot.
    dependencies = get(TOML.parsefile(active), "deps", Dict{String,Any}())
    plugins = Module[]
    for (raw_name, raw_uuid) in dependencies
        name = String(raw_name)
        source_file = Base.locate_package(Base.PkgId(UUID(String(raw_uuid)), name))
        source_file === nothing && continue
        source = dirname(dirname(source_file))
        plugin_marker(joinpath(source, "Project.toml")) || continue
        occursin(r"^[A-Za-z][A-Za-z0-9_]*$", name) ||
            error("BonitoAgents plugin has an invalid package name `$name`")
        try
            push!(plugins, Base.require(Main, Symbol(name)))
        catch e
            error("could not load BonitoAgents plugin `$name`: $(sprint(showerror, e))")
        end
    end
    return apps_of(plugins)
end

"The registered app types that the packages `mods` define."
apps_of(mods) = Tuple(A for A in registered_apps() if Base.moduleroot(parentmodule(A)) in mods)

# ── loading an app while the server runs ────────────────────────────────────

"""
    load_app!(server, path) -> NamedTuple

Load the app package in the folder `path` into the running server and start
the apps it registers (`register_app!` in its `__init__`): their tiles appear
on the dashboard, and their tools reach the chats. A package that is not a
direct dependency of the server's environment yet is added to it first, as a
development checkout of `path` (`Pkg.develop`, every loaded package kept at its
version). With the plugin marker it then loads again when the server restarts.

Returns `(apps, added, marked)`: the started apps, whether the environment
changed, and whether the package has the marker. A package loads once per
server process, so running changed code takes a restart.
"""
function load_app!(server::ServerState, path::AbstractString)
    path = abspath(expanduser(String(path)))
    id, project = package_at(path)
    name = id.name
    return lock(server.apps.loading) do
        added = !in_server_env(id, path)
        added && add_to_server_env!(path)
        try
            mod = Base.require(id)
            types = apps_of((mod,))
            isempty(types) && error("$name loaded, but it registered no app: its `__init__` should call " *
                                    "`BonitoAgents.register_app!` with its app type")
            new = filter(A -> !haskey(server.apps, Base.invokelatest(app_id, A)), types)
            isempty(new) && error("$name already runs on this server. Running changed code takes a server restart.")
            (apps = start_apps!(server, new), added, marked = plugin_marker(project))
        catch
            # A package that doesn't load must not stay in the environment: with
            # the plugin marker, the next server start would fail on it.
            added && remove_from_server_env!(id)
            rethrow()
        end
    end
end

# The package in the folder `path`, by its Project.toml.
function package_at(path::AbstractString)
    project = joinpath(path, "Project.toml")
    isfile(project) || error("there is no package at $path on the server's machine (no Project.toml)")
    toml = TOML.parsefile(project)
    name, uuid = get(toml, "name", nothing), get(toml, "uuid", nothing)
    (name isa String && uuid isa String) || error("$project names no package: it needs a `name` and a `uuid`")
    return Base.PkgId(UUID(uuid), name), project
end

# Is `id` a direct dependency of the server's environment, checked out at `path`?
function in_server_env(id::Base.PkgId, path::AbstractString)
    active = Base.active_project()
    (active === nothing || !isfile(active)) && return false
    get(get(TOML.parsefile(active), "deps", Dict{String,Any}()), id.name, nothing) == string(id.uuid) ||
        return false
    source = Base.locate_package(id)
    return source !== nothing && samefile(dirname(dirname(source)), path)
end

# Add the package at `path` to the server's environment as a development
# checkout. Every package the server has loaded keeps its version.
function add_to_server_env!(path::AbstractString)
    active = Base.active_project()
    active === nothing && error("the server runs without an active Julia environment to add the package to")
    io = IOBuffer()
    try
        Pkg.develop(Pkg.PackageSpec(path = path); preserve = Pkg.PRESERVE_ALL, io)
    catch e
        # What can go wrong here: the resolver, or an environment the server
        # may not write (a service user's server runs on its admin's checkout).
        e isa Union{Pkg.Types.PkgError, Base.IOError, SystemError} || rethrow()
        error("could not add $path to the server's environment $active: $(sprint(showerror, e))\n" *
              String(take!(io)))
    end
    return nothing
end

remove_from_server_env!(id::Base.PkgId) =
    Pkg.rm(Pkg.PackageSpec(name = id.name, uuid = id.uuid); io = IOBuffer())

# ── a person approves every load ────────────────────────────────────────────
# An agent asks (`bt_load_app`), a person decides. The chat shows the request as
# a card, and only a click on it in an admin's tab answers it. Nothing on the
# agent's side can: its MCP has no op for answering, and the agent's permission
# settings (Yolo, an allow-list) never see the question, because the server
# asks it, after the tool call has started.

"""
    await_load_approval(server, project, path; timeout = 600) -> Symbol

Ask the people in `project`'s chat whether the package at `path` may be loaded
into the server, and wait for their answer: `:approved`, `:denied`, or
`:expired` once `timeout` seconds pass without one.
"""
function await_load_approval(server::ServerState, p::ProjectInfo, path::AbstractString;
                             timeout::Real = 600.0)
    id, _ = package_at(path)
    r = root_state(server).apps
    req = AppLoadRequest("app_load:" * string(uuid4()), p.id, id.name, path,
                         !in_server_env(id, path), Channel{Symbol}(1))
    lock(() -> (r.pending[req.key] = req), r.lock)
    timer = Timer(_ -> decide!(r, req.key, :expired), timeout)
    show_prompts!(server, p.id)
    try
        return take!(req.decision)
    finally
        close(timer)
        lock(() -> delete!(r.pending, req.key), r.lock)
        show_prompts!(server, p.id)
    end
end

# The first answer counts. A later one (another tab, the timer) finds it decided.
function decide!(r::AppRegistry, key::AbstractString, decision::Symbol)
    lock(r.lock) do
        req = get(r.pending, key, nothing)
        (req === nothing || isready(req.decision)) && return false
        put!(req.decision, decision)
        return true
    end
end

"""
    answer_app_load!(viewer, project_id, key, approve) -> Bool

A person's answer to the load request `key` from `project_id`'s card. `viewer`
is their tab's state: approving takes an admin. Returns whether it decided.
"""
function answer_app_load!(viewer::ServerState, project_id::AbstractString, key::AbstractString, approve::Bool)
    r = root_state(viewer).apps
    req = lock(() -> get(r.pending, key, nothing), r.lock)
    (req === nothing || req.project_id != project_id) && error("this request was already answered or has expired")
    approve && !is_admin(viewer) && error("only an admin can approve loading an app into the server")
    return decide!(r, key, approve ? :approved : :denied)
end

# The open requests of a chat, as cards next to its password questions.
function app_load_cards(state::ServerState, pid::AbstractString)
    r = root_state(state).apps
    reqs = lock(() -> [q for q in values(r.pending) if q.project_id == pid && !isready(q.decision)], r.lock)
    return [Dict{String,Any}("key" => q.key, "kind" => "app_load", "job" => q.package, "cwd" => q.path,
                             "worker" => "", "host" => "",
                             "text" => "From $(q.path)\nIt runs inside the BonitoAgents server, with the server's " *
                                       "permissions." * (q.adds ? " It is added to the server's Julia environment." : ""))
            for q in reqs]
end

# A chat asks for it (`bt_load_app`). Loading puts code into the server process,
# so only an admin's chat may ask, and a person has to approve it.
function dev_op(server::ServerState, ::Val{:app_load}, args::AbstractDict, caller::String)
    p = caller_project(server, caller)
    p === nothing && error("loading an app needs a chat (this control channel carries no project id)")
    user = owner_user(server, p.owner)
    (user !== nothing && is_admin(user)) || error("only an admin's chat may load an app into the server")
    path = String(strip(String(get(args, "path", ""))))
    isempty(path) && error("`path` (the app package's folder) is required")
    # A worker path; the server reads it as its own, so the chat's worker has to
    # be on the server's machine (`package_at` says so when the folder isn't there).
    path = worker_isabspath(path) ? normalize_worker_path(path) : worker_join(p.worker_path, path)
    path = abspath(expanduser(path))
    decision = await_load_approval(server, p, path)
    decision === :denied && error("the user declined loading the app at $path. Don't ask again unless they say so.")
    decision === :expired && error("nobody answered the request to load the app at $path. Ask the user to " *
                                   "approve it in the chat, then call bt_load_app again.")
    r = load_app!(server, path)
    # The apps' methods are newer than this call, which began before the load.
    return Dict{String,Any}(
        "apps" => [Base.invokelatest(app_summary, a) for a in r.apps],
        "added" => r.added, "marked" => r.marked, "environment" => something(Base.active_project(), ""))
end

app_summary(app::AgentApp) = Dict{String,Any}("id" => app_id(app), "title" => app_title(app),
                                               "tools" => [String(t.name) for t in app_tools(app)])
