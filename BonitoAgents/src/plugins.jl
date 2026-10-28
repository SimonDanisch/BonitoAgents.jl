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

"Load direct dependencies whose Project.toml explicitly marks them as plugins."
function load_plugins!()
    # Read the active project's `[deps]` rather than Pkg.dependencies(): the
    # latter may hold the package's precompile-time context when called from a
    # server package. `locate_package` resolves each declared UUID against the
    # actual active manifest, including the service user's depot.
    active = Base.active_project()
    active === nothing && return registered_apps()
    dependencies = get(TOML.parsefile(active), "deps", Dict{String,Any}())
    for (raw_name, raw_uuid) in dependencies
        name = String(raw_name)
        source_file = Base.locate_package(Base.PkgId(UUID(String(raw_uuid)), name))
        source_file === nothing && continue
        source = dirname(dirname(source_file))
        plugin_marker(joinpath(source, "Project.toml")) || continue
        occursin(r"^[A-Za-z][A-Za-z0-9_]*$", name) ||
            error("BonitoAgents plugin has an invalid package name `$name`")
        try
            Base.require(Main, Symbol(name))
        catch e
            error("could not load BonitoAgents plugin `$name`: $(sprint(showerror, e))")
        end
    end
    return registered_apps()
end
