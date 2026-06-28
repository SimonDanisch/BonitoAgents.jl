# Self-contained dev server + local worker, no systemd / no install steps.
# Used to bring the dashboard up against ephemeral state for development,
# manual UX poking, or one-off scripted demos. Everything lives in
# tempdirs that get rm-rf'd on close.
#
# Usage:
#   handle = BonitoAgents.dev_server()
#   # ... open handle.url in a browser, click around ...
#   close(handle)
#
# Or as a do-block for guaranteed cleanup on Ctrl+C:
#   BonitoAgents.dev_server() do h
#       BonitoAgents.wait!(h)
#   end

using Random

mutable struct DevHandle
    url         :: String
    secret      :: String
    state         :: ServerState
    worker_proc   :: Union{Base.Process,Nothing}  # the worker runs as a SEPARATE process (see dev_server)
    state_dir     :: String
    working_dir   :: String
    worker_root   :: String
    worker_config :: String                       # throwaway BonitoWorker config dir (removed on close)
    closed        :: Threads.Atomic{Bool}
end

"""
    dev_server(; port=nothing, name="dev", auto_open=false) -> DevHandle

Boot a self-contained BonitoAgents server + a local worker in this
process. All state lives in `mktempdir()`-allocated directories and is
removed when you call `close(handle)` (or when the Julia process exits
— an atexit hook is registered).

The worker is an in-process `BonitoWorker.connect_and_serve` task: it
dials the server's `/worker-ws` over loopback with a freshly-generated
secret. No systemd, no install script.

If `claude-agent-acp` isn't on PATH the dashboard still works (worker
registration, sidebar, project import, file pickers); only opening a
chat session against the worker will fail at the agent spawn step.

```julia
h = BonitoAgents.dev_server(; port = 8138, auto_open = true)
# Click around in the browser...
close(h)
```

Or as a do-block (recommended, cleans up on exception / Ctrl+C):

```julia
BonitoAgents.dev_server() do h
    BonitoAgents.wait!(h)   # blocks until Ctrl+C
end
```
"""
function dev_server(; port::Union{Int,Nothing}             = nothing,
                      name::Union{String,Nothing}          = nothing,
                      auto_open::Bool                      = false,
                      agent_bin::Union{String,Nothing}     = nothing,
                      agent_env::Dict{String,String}       = Dict{String,String}())
    # port=0 lets the kernel pick a free ephemeral port; Bonito.Server
    # writes the real port back to srv.port after start.
    chosen_port = port === nothing ? 0 : port
    secret      = randstring(64)
    state_dir   = mktempdir(; prefix = "bonitoagents-dev-state-")
    working_dir = mktempdir(; prefix = "bonitoagents-dev-work-")
    worker_root = mktempdir(; prefix = "bonitoagents-dev-worker-")
    worker_id   = "dev-" * randstring(8)
    # Route through `default_worker_name` so a machine whose
    # `friendly_hostname()` is empty (no `hostnamectl --pretty` configured,
    # `gethostname()` = "localhost") falls back to `<user>-<4 chars>` —
    # otherwise dev_server registered every worker as "localhost".
    actual_name = name === nothing ? BonitoWorker.default_worker_name(worker_id) : name

    state = serve(; host          = "127.0.0.1",
                    port          = chosen_port,
                    worker_secret = secret,
                    state_dir     = state_dir,
                    working_dir   = working_dir)
    server_url = "http://127.0.0.1:$(state.srv.port)"

    # Stand the worker up exactly like a real install: write the SAME
    # `config.json` and launch the SAME detached `BonitoWorker.start()` process
    # via `spawn_worker`. The ONLY differences from a production install are
    # (1) it's localhost and (2) the config lives in a throwaway dir, so we
    # don't collide with a real install on this machine and can delete it on
    # cleanup — we deliberately do NOT touch the systemd service. The detached
    # worker inherits this process's env, so the config-dir override + the test
    # agent (CLAUDE_AGENT_ACP + agent_env) reach it and the BonitoMCP it spawns.
    resolved_agent_bin = agent_bin === nothing ? BonitoWorker.find_agent_bin() :
                          String(agent_bin)
    worker_config = mktempdir(; prefix = "bonitoagents-dev-wcfg-")
    ENV["BONITOAGENTS_CONFIG_DIR"] = worker_config
    write(joinpath(worker_config, "worker_id"), worker_id)   # pin the ephemeral dev id
    resolved_agent_bin === nothing || (ENV["CLAUDE_AGENT_ACP"] = resolved_agent_bin)
    for (k, v) in agent_env; ENV[k] = v; end
    # Build the provider singleton list ONCE here, on the uncontended startup path
    # (ENV is now fully configured; no browser is attached yet). Without this the
    # list is built lazily on the FIRST chat bind — and that first build compiles
    # four descriptor constructors, reached concurrently from the bind path
    # (`default_provider`) AND the provider-dropdown render (`current_providers`).
    # Under nworkers=4 load that concurrent first-build stalled the bind for >90 s
    # ("chat view opened" timeout); worse, since the memo only caches AFTER a full
    # build, a stalled build was never cached, so every later bind on that worker
    # re-entered the build and re-hung. `refresh_providers!` builds + first-compiles
    # the four descriptor constructors once here, uncontended, so no bind ever
    # first-builds it; it also rebuilds from the now-complete ENV, so a list
    # memoised earlier (before `BT_ENABLE_MOCK_AGENT` was set) can't hide the mock.
    refresh_providers!()
    # …and first-compile the rest of the resolver chain the bind walks
    # (`default_provider` → `find_provider`) here too, so NONE of it first-compiles
    # on a bind concurrently with the dropdown render. The list is correct now, so
    # this resolves cleanly (a genuinely misconfigured default would surface here,
    # which is the right place for it).
    default_provider()
    # Tie the worker's lifetime to OURS: `dev_server` is ephemeral (we already
    # atexit-cleanup), so a worker it spawns must not outlive us. We pass our PID;
    # the worker arms `PR_SET_PDEATHSIG` so the KERNEL reaps it when we die — even
    # on an OOM-kill / SIGKILL that skips atexit. Without it, an abnormally-killed
    # test runner (nworkers=N, OOM) orphans its detached worker subtree. The worker
    # inherits this var at spawn.
    ENV["BONITOAGENTS_DIE_WITH_PARENT"] = string(getpid())
    BonitoWorker.write_config!(; server_url = server_url, secret = secret,
                                projects_root = worker_root, name = actual_name)
    worker_proc, _ = BonitoWorker.spawn_worker()

    # `closed` guards close() idempotency (the worker lifecycle is the process).
    closed = Threads.Atomic{Bool}(false)
    handle = DevHandle(server_url, secret, state, worker_proc,
                       state_dir, working_dir, worker_root, worker_config, closed)

    # Best-effort cleanup if the Julia process exits without explicit close.
    Base.atexit(() -> close(handle))

    println()
    @info "BonitoAgents dev server running" url=server_url worker_name=actual_name
    println("  State dirs (auto-cleaned on close):")
    println("    state    $state_dir")
    println("    working  $working_dir")
    println("    worker   $worker_root")
    println()
    println("  Call close(h) to stop, or BonitoAgents.wait!(h) to block " *
            "until Ctrl+C.")
    println()

    auto_open && open_in_browser(server_url)

    return handle
end

# Do-block form: f(handle) is called with a live DevHandle and the
# server is torn down + tempdirs removed even on exception (Ctrl+C
# included, since InterruptException propagates through finally).
function dev_server(f::Function; kwargs...)
    h = dev_server(; kwargs...)
    try
        f(h)
    finally
        close(h)
    end
end

# Stop a detached worker process: SIGTERM, wait out a grace window, then SIGKILL
# if it's still alive. Returns once the process is gone (or we've given up). The
# `kill` calls can throw `IOError` if the process died between our check and the
# signal — that's the outcome we want, so it's tolerated; anything else surfaces.
# grace_s is short by design: a *connected* worker is parked in a libuv socket
# read and won't act on a queued SIGTERM before we'd give up anyway, so a long
# grace just delays every close. An idle/reconnecting worker exits on SIGTERM in
# ~0.2s and returns early, well under this window.
function stop_worker_proc!(proc::Base.Process; grace_s::Real = 1.5)
    process_exited(proc) && return
    try
        kill(proc)                       # SIGTERM
    catch e
        e isa Base.IOError || rethrow()
    end
    deadline = grace_s / 0.05
    for _ in 1:ceil(Int, deadline)
        process_exited(proc) && return
        sleep(0.05)
    end
    @warn "dev_server: worker ignored SIGTERM within grace window; sending SIGKILL" grace_s
    try
        kill(proc, Base.SIGKILL)
    catch e
        e isa Base.IOError || rethrow()
    end
    for _ in 1:40
        process_exited(proc) && return
        sleep(0.05)
    end
    process_exited(proc) ||
        @warn "dev_server: worker still alive after SIGKILL" pid=getpid(proc)
    return
end

# Idempotent close: stops the server, lets the worker WS drop, removes
# every tempdir we allocated. Safe to call multiple times — only the
# first call does anything.
function Base.close(h::DevHandle)
    # atomic_cas! returns the PRIOR value. We want "exit early iff it
    # was already true", i.e. iff we weren't the first to set it.
    prev = Threads.atomic_cas!(h.closed, false, true)
    prev && return h
    @info "dev_server: shutting down" url=h.url
    # Kill the worker subprocess FIRST: its WS then drops so the server's drain
    # below isn't waiting on a live worker, and its connect_and_serve loop stops
    # retrying against the closing server (no shutdown retry-spam).
    #
    # SIGTERM → grace → SIGKILL. A worker blocked in the WS `receive()` (a libuv
    # socket read) processes a queued SIGTERM only sluggishly, so a bare
    # `kill(proc)` can leave it alive for many seconds. SIGKILL can't be delayed
    # or blocked, so escalate once the grace window lapses — exactly what
    # systemd's TimeoutStopSec does for the production service.
    if h.worker_proc !== nothing
        stop_worker_proc!(h.worker_proc)
    end
    # Drop the env we set so this process is left as we found it (the detached
    # worker already inherited it at spawn; this just prevents leakage into
    # later dev_server / test runs in the same Julia session).
    for k in ("BONITOAGENTS_CONFIG_DIR", "CLAUDE_AGENT_ACP", "BONITOAGENTS_DIE_WITH_PARENT")
        haskey(ENV, k) && delete!(ENV, k)
    end
    # Bonito.Server.close blocks waiting for accept loops + WS handlers to
    # drain. Run it in a task so a slow/throwing drain doesn't hold cleanup
    # hostage; failures (Bonito occasionally throws in background route
    # handlers) go to stderr via errormonitor. The accept-listener's ephemeral
    # port is reclaimed by the OS on exit either way.
    #
    # We WAIT for this to finish before removing the tempdirs below: killing the
    # worker makes its control socket drop, and the server's teardown handler
    # then persists `discovered.json` into `state_dir`. If we rm'd before that
    # write landed, the dir would reappear holding that one file. The drain
    # completes in well under a second normally; the generous bound only guards
    # a genuinely wedged handler (logged, then we rm anyway).
    close_task = Base.errormonitor(@async close(h.state.srv))
    for _ in 1:200
        istaskdone(close_task) && break
        sleep(0.05)
    end
    istaskdone(close_task) ||
        @warn "dev_server: server close did not finish in time; removing tempdirs anyway"
    # `force = true` already makes "doesn't exist" a no-op, so the only
    # remaining failure modes are permission / filesystem errors — those
    # we DO want surfaced rather than silently dropping the tempdir.
    for d in (h.state_dir, h.working_dir, h.worker_root, h.worker_config)
        try
            rm(d; recursive = true, force = true)
        catch e
            @warn "dev_server: cleanup rm failed" path=d exception=e
        end
    end
    return h
end

# Block until Ctrl+C. Useful from scripts and bin wrappers; from the
# REPL just keep the handle and run other code in parallel.
function wait!(h::DevHandle)
    try
        # Long sleep on the main task; Ctrl+C delivers InterruptException
        # which we catch + return cleanly so the caller's finally runs.
        while !h.closed[]
            sleep(1.0)
        end
    catch e
        e isa InterruptException || rethrow()
    end
    return h
end

function open_in_browser(url::AbstractString)
    cmd = if Sys.iswindows()
        `cmd /c start "" $url`
    elseif Sys.isapple()
        `open $url`
    else
        `xdg-open $url`
    end
    # `ignorestatus = true` already swallows non-zero exit codes from
    # the launcher itself; the remaining failure mode is the launcher
    # binary simply not being on PATH (Base.IOError "no such file").
    # That's best-effort by design — the dev_server's banner printed
    # the URL above, the user can still click it. Log at @debug for
    # anyone investigating "why didn't my browser open".
    try
        run(pipeline(Cmd(cmd; ignorestatus = true), stdout = devnull, stderr = devnull))
    catch e
        e isa Base.IOError || rethrow()
        @debug "open_in_browser: launcher not available" url exception=e
    end
end
