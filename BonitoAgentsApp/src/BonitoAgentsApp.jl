# BonitoAgents desktop app: one process that boots the BonitoAgents server on
# loopback, registers this machine as a local worker, and shows the dashboard
# in an ElectronCall window. Closing the window shuts everything down.
#
# This is the entry point AppBundler packages into the distributable bundles
# (`julia -m BonitoAgentsApp`, or the bundled launcher binary).
module BonitoAgentsApp

import Bonito
using BonitoAgents
using BonitoWorker
using ElectronCall
import Downloads
using URIs: URI
using Random: randstring
using PrecompileTools: @setup_workload, @compile_workload

export desktop
# AppBundler's launcher starts the app as `julia --eval="using BonitoAgentsApp" -- args…`:
# Julia invokes `Main.main` after the eval, and `main` only ends up bound in
# Main if we export it.
export main

# Platform-conventional persistent data root for the desktop app. Unlike
# `BonitoAgents.dev_server` (ephemeral tempdirs), the desktop app keeps its
# state across launches: projects, chats and the worker identity survive.
#
# USER_DATA is the AppBundler/AppEnv convention for the user data directory;
# the bundled launcher sets it to the same platform path so app state and the
# Julia depot cache live under the same root. Honour it here so --data-dir
# (which sets USER_DATA at runtime) moves all state consistently.
function data_root()
    haskey(ENV, "USER_DATA") && return ENV["USER_DATA"]
    base = if Sys.iswindows()
        get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    elseif Sys.isapple()
        joinpath(homedir(), "Library", "Application Support")
    else
        get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
    end
    return joinpath(base, "BonitoAgents")
end

mutable struct AppHandle
    url           :: String
    state         :: BonitoAgents.ServerState
    worker_id     :: String
    worker_proc   :: Base.Process   # the local worker runs as a SEPARATE process (`bonitoagents worker`)
    closed        :: Threads.Atomic{Bool}
end

"""
    start_app(; port = nothing) -> AppHandle

Start the BonitoAgents server on loopback and launch a local worker process
(`bonitoagents worker`) against it. State persists under [`data_root`](@ref)
across launches:

  - `state/`         workers.json / projects.json + chat persistence
  - `working/`       canonical project copies (server side)
  - `projects/`      worker-side project checkouts
  - `worker-config/` stable worker identity (`worker_id`)

`port = nothing` picks a free ephemeral port. Returns an [`AppHandle`](@ref);
`close(handle)` kills the worker process, then stops the server.
"""
# In an AppBundler bundle, AppEnv configures the package environment by
# mutating THIS process's LOAD_PATH/DEPOT_PATH arrays only. Child julia
# processes (the BonitoMCP session the worker spawns per chat) run with
# --startup-file=no and would start with default paths — unable to find any
# bundled package. Exporting the resolved paths makes children inherit them;
# in a plain dev run this is a no-op-ish reaffirmation of the same paths.
function export_julia_env!()
    sep = Sys.iswindows() ? ';' : ':'
    # `Base.load_path()` — the RESOLVED absolute project paths — not the raw
    # `LOAD_PATH` tokens. A child that inherits `JULIA_LOAD_PATH="@:@v#.#:@stdlib"`
    # but sets no `--project` resolves `@` to *its own* (empty) active project and
    # can't find our packages — exactly what broke the spawned worker
    # (`-m BonitoAgentsApp worker` → "Package BonitoAgentsApp not found"). The
    # expanded paths resolve identically in any child.
    ENV["JULIA_LOAD_PATH"]  = join(Base.load_path(), sep)
    ENV["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, sep)
    return
end

# Command that re-execs THIS process as `bonitoagents worker`. `Base.julia_cmd()`
# carries the same interpreter + sysimage (`-J`), so in a bundle the worker reuses
# the app's baked-in precompilation instead of compiling from scratch; LOAD_PATH/
# DEPOT_PATH are exported into ENV by `export_julia_env!` and inherited by the
# child, so `-m BonitoAgentsApp` resolves to the same code. One binary, two roles.
function worker_command(; server_url, secret, worker_id, projects_root, data_dir)
    return `$(Base.julia_cmd()) --startup-file=no -m BonitoAgentsApp worker
            --server-url=$server_url --secret=$secret --worker-id=$worker_id
            --projects-root=$projects_root --data-dir=$data_dir`
end

# Stop the worker subprocess: SIGTERM, a short grace, then SIGKILL. A worker
# parked in its control-WS receive loop acts on a queued SIGTERM only sluggishly
# (like the production install), so escalate once the grace lapses. IOError from
# kill = it already exited, which is the goal; anything else surfaces.
function stop_worker_proc!(proc::Base.Process; grace_s::Real = 1.5)
    process_exited(proc) && return
    try; kill(proc); catch e; e isa Base.IOError || rethrow(); end
    for _ in 1:ceil(Int, grace_s / 0.05)
        process_exited(proc) && return
        sleep(0.05)
    end
    try; kill(proc, Base.SIGKILL); catch e; e isa Base.IOError || rethrow(); end
    for _ in 1:40
        process_exited(proc) && return
        sleep(0.05)
    end
    process_exited(proc) || @warn "BonitoAgents app: worker still alive after SIGKILL" pid = getpid(proc)
    return
end

function start_app(; port::Union{Int,Nothing} = nothing)
    export_julia_env!()
    root        = data_root()
    state_dir   = mkpath(joinpath(root, "state"))
    working_dir = mkpath(joinpath(root, "working"))
    worker_cfg  = mkpath(joinpath(root, "worker-config"))
    projects    = mkpath(joinpath(root, "projects"))

    # Fresh secret per run: server and worker live in the same process, nobody
    # else ever needs to know it.
    secret = randstring(64)
    state  = BonitoAgents.serve(; host = "127.0.0.1",
                                  port = something(port, 0),
                                  worker_secret = secret,
                                  state_dir     = state_dir,
                                  working_dir   = working_dir)
    url = "http://127.0.0.1:$(state.srv.port)"

    # Persist the worker identity in our data root (instead of a scratchspace)
    # so the dashboard recognises this machine across launches.
    ENV["BONITOAGENTS_CONFIG_DIR"] = worker_cfg
    worker_id = BonitoWorker.load_or_generate_worker_id()
    # Launch the worker as a SEPARATE process (`bonitoagents worker`), not an
    # in-process task: a worker crash / wedge can't take down the dashboard, and
    # it mirrors the production install (the worker is always its own process).
    # Reuses this bundle's binary + sysimage via `worker_command`, so there's no
    # extra compilation and `./bonitoagents` is still the single command to run.
    # Worker output → its own log under the data root (not interleaved with the
    # desktop's stdout), mirroring the production install's worker.log.
    worker_log = joinpath(worker_cfg, "worker.log")
    worker_cmd = worker_command(; server_url = url, secret = secret,
                                  worker_id = worker_id,
                                  projects_root = projects, data_dir = root)
    worker_proc = run(pipeline(worker_cmd; stdout = worker_log, stderr = worker_log,
                               append = true); wait = false)
    @info "BonitoAgents app: worker process started" pid = getpid(worker_proc) log = worker_log

    return AppHandle(url, state, worker_id, worker_proc, Threads.Atomic{Bool}(false))
end

# Idempotent: first close stops the Bonito server (bounded drain, mirroring
# dev_server's close); the worker subprocess is killed in close() above.
function Base.close(h::AppHandle)
    prev = Threads.atomic_cas!(h.closed, false, true)
    prev && return h
    @info "BonitoAgents app: shutting down" url = h.url
    # Kill the worker process FIRST: its control WS then drops so the server
    # close below can drain its WS handlers (a still-connected worker would
    # deadlock that drain — the worker only disconnects when the server goes
    # away), and its reconnect loop stops retrying against the closing server.
    stop_worker_proc!(h.worker_proc)
    close_task = Base.errormonitor(@async close(h.state.srv))
    for _ in 1:200
        istaskdone(close_task) && break
        sleep(0.05)
    end
    istaskdone(close_task) ||
        @warn "BonitoAgents app: server close did not finish in time"
    delete!(ENV, "BONITOAGENTS_CONFIG_DIR")
    return h
end

# Block until close(h) from elsewhere or Ctrl+C (used by --no-window mode).
function BonitoAgents.wait!(h::AppHandle)
    try
        while !h.closed[]
            sleep(1.0)
        end
    catch e
        e isa InterruptException || rethrow()
    end
    return h
end

# Open the dashboard in an ElectronCall window and block until the user closes
# it (or the Electron process dies, or Ctrl+C).
function run_window(url::String)
    app = ElectronCall.Application(; name = "BonitoAgents")
    win = ElectronCall.Window(app, URI(url);
                              width = 1600, height = 1000,
                              title = "BonitoAgents")
    try
        while isopen(win) && app.exists
            sleep(0.25)
        end
    catch e
        e isa InterruptException || rethrow()
    finally
        # `close(app)` errors on an already-closed app, and the loop above can
        # end exactly because the Electron process went away.
        app.exists && close(app)
    end
    return
end

"""
    desktop(; port = nothing, window = true)

Run the BonitoAgents desktop app: server + local worker + dashboard window.
Blocks until the window is closed (or Ctrl+C with `window = false`), then
shuts the server down. This is what `julia -m BonitoAgentsApp` runs.
"""
function desktop(; port::Union{Int,Nothing} = nothing, window::Bool = true)
    h = start_app(; port)
    try
        if window
            run_window(h.url)
        else
            println("BonitoAgents running at $(h.url) — Ctrl+C to stop.")
            BonitoAgents.wait!(h)
        end
    finally
        close(h)
    end
    return
end

const USAGE = """
BonitoAgents — one bundle, three roles.

Usage: bonitoagents [MODE] [options]

Modes (default: desktop):
  desktop                 server + local worker + dashboard window
  server                  headless dashboard server (workers dial back to it)
  worker                  connect this machine to a remote server as a worker

Desktop options:
  --port=N                bind the dashboard to a fixed port (default: ephemeral)
  --no-window             run server + local worker only; print the URL
  --data-dir=PATH         store all app state under PATH

Server options:
  --port=N                listen port (default: 8038)
  --host=HOST             bind host (default: 0.0.0.0)
  --public-url=URL        base URL workers dial back to (default: auto)
  --secret=HEX            shared worker secret (default: persisted/generated)
  --state-dir=PATH        workers.json / projects.json / chats
  --working-dir=PATH      canonical project copies
  --data-dir=PATH         store all server state under PATH

Worker options:
  --server-url=URL        dashboard server to connect to (required)
  --secret=HEX            shared worker secret (required)
  --worker-id=ID          stable worker id (default: persisted/generated)
  --projects-root=PATH    where project checkouts live
  --data-dir=PATH         store all worker state under PATH

Default data dir: ~/.local/share/BonitoAgents (Linux),
~/Library/Application Support/BonitoAgents (macOS),
%LOCALAPPDATA%\\BonitoAgents (Windows).
"""

# --key=value → opts["key"]="value"; bare --flag → opts["flag"]="". Errors on
# anything not starting with `--`, so a typo fails loudly instead of being
# silently ignored.
function parse_opts(args)
    opts = Dict{String,String}()
    for a in args
        startswith(a, "--") || error("unexpected argument `$a` (use --key=value)")
        body = a[3:end]
        if occursin('=', body)
            k, v = split(body, '='; limit = 2)
            opts[String(k)] = String(v)
        else
            opts[body] = ""
        end
    end
    return opts
end

# `desktop`: the original behaviour — server + local worker + Electron window.
function run_desktop(args)
    port = nothing
    window = true
    for arg in args
        if arg == "--no-window"
            window = false
        elseif startswith(arg, "--port=")
            port = parse(Int, split(arg, '='; limit = 2)[2])
        elseif startswith(arg, "--data-dir=")
            ENV["USER_DATA"] = split(arg, '='; limit = 2)[2]
        else
            println(stderr, "Unknown desktop argument: $arg\n")
            print(stderr, USAGE)
            return 1
        end
    end
    desktop(; port, window)
    return 0
end

# `server`: headless dashboard, mirroring `BonitoAgents`'s own entry point but
# rooting its state under our shared data dir by default.
function run_server(args)
    opts = parse_opts(args)
    haskey(opts, "data-dir") && (ENV["USER_DATA"] = opts["data-dir"])
    root        = data_root()
    state_dir   = get(opts, "state-dir",   mkpath(joinpath(root, "state")))
    working_dir = get(opts, "working-dir", mkpath(joinpath(root, "working")))
    secret = get(opts, "secret", "")
    isempty(secret) && (secret = BonitoAgents.persisted_worker_secret(state_dir))
    export_julia_env!()
    BonitoAgents.serve(;
        host          = get(opts, "host", "0.0.0.0"),
        port          = parse(Int, get(opts, "port", "8038")),
        public_url    = get(opts, "public-url", ""),
        worker_secret = secret,
        state_dir     = state_dir,
        working_dir   = working_dir)
    block_until_interrupt()
    return 0
end

# `worker`: dial back to a remote server. connect_and_serve loops internally
# (reconnect-forever), so it blocks until interrupted.
function run_worker(args)
    opts = parse_opts(args)
    haskey(opts, "data-dir") && (ENV["USER_DATA"] = opts["data-dir"])
    for req in ("server-url", "secret")
        haskey(opts, req) && !isempty(opts[req]) && continue
        println(stderr, "worker: --$req is required\n")
        print(stderr, USAGE)
        return 1
    end
    root     = data_root()
    projects = get(opts, "projects-root", mkpath(joinpath(root, "projects")))
    ENV["BONITOAGENTS_CONFIG_DIR"] = mkpath(joinpath(root, "worker-config"))
    worker_id = get(opts, "worker-id", "")
    isempty(worker_id) && (worker_id = BonitoWorker.load_or_generate_worker_id())
    export_julia_env!()
    BonitoWorker.connect_and_serve(;
        server_url    = opts["server-url"],
        secret        = opts["secret"],
        worker_id     = worker_id,
        projects_root = projects)
    return 0
end

function block_until_interrupt()
    try
        while true
            sleep(3600)
        end
    catch e
        e isa InterruptException || rethrow()
    end
    return
end

function (@main)(args)
    args = collect(String, args)
    # Help is matched before mode-defaulting so `--help`/`-h` (which start with
    # `-`, and would otherwise fall through to desktop) print usage.
    if !isempty(args) && first(args) in ("-h", "--help", "help")
        print(USAGE)
        return 0
    end
    # First non-flag token selects the mode; default is `desktop`.
    mode = (!isempty(args) && !startswith(first(args), "-")) ? popfirst!(args) : "desktop"
    if mode == "desktop"
        return run_desktop(args)
    elseif mode == "server"
        return run_server(args)
    elseif mode == "worker"
        return run_worker(args)
    else
        println(stderr, "Unknown mode: $mode\n")
        print(stderr, USAGE)
        return 1
    end
end

@setup_workload begin
    @compile_workload begin
        mktempdir() do dir
            state = BonitoAgents.serve(;
                host          = "127.0.0.1",
                port          = 0,
                worker_secret = "precompile-secret",
                state_dir     = mkpath(joinpath(dir, "state")),
                working_dir   = mkpath(joinpath(dir, "working")))
            url = "http://127.0.0.1:$(state.srv.port)"
            # Fetch the dashboard via Downloads (libcurl), NOT HTTP/Reseau: the
            # HTTP client spins up Reseau's global event loop, whose timer is
            # still alive when the precompile image is serialized ("waiting for
            # IO to finish" — a leaked uv handle). libcurl keeps its handles
            # internal and releases them when the download returns, so the
            # render path still precompiles (fast first paint) without leaking.
            # `grace = 0`: the default Downloader keeps its libcurl event loop
            # alive for 30s after the last request via a Timer — which would be
            # the lingering handle. grace=0 tears it down immediately.
            try
                Downloads.download(url, devnull;
                                   headers = ["Connection" => "close"],
                                   downloader = Downloads.Downloader(; grace = 0))
            catch e
                @debug "precompile workload: dashboard fetch failed" exception = e
            end
            # Close the sessions the render created (compiles teardown paths too),
            # then the server — which stops its accept loop AND its 1-Hz cleanup
            # task (whose `sleep(1)` would otherwise be a lingering timer).
            for (_, v) in state.srv.routes.table
                v isa Bonito.App && !isnothing(v.session[]) && close(v.session[])
            end
            close(state.srv)
        end
        # Stop Bonito's global cleanup machinery + clear server globals, then run
        # finalizers and yield so no background task / libuv handle survives into
        # the precompile image.
        Bonito.cleanup_globals()
        GC.gc()
        yield()
    end
end

end # module BonitoAgentsApp
