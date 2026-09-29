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

"""
    DevProxy(; caddy_bin, authelia_bin, password, totp_secret, admin = "admin",
               domain = "bonito.localhost", tunnel = false)

Put `dev_server` behind the real login proxy: Caddy with its own certificate
authority, and Authelia, both on this machine under `domain` and `auth.<domain>`
(names under `.localhost` need no DNS: browsers resolve them to this machine).
`admin` logs in with `password` and the authenticator secret `totp_secret`
(base32), which an authenticator app would hold. `fetch_proxy_binaries` gets
the two binaries.

`tunnel = true` sets the server up behind a tunnel instead (`TunnelAuth`): no
Caddy of ours, Authelia under `domain` itself. The tunnel is played by a Caddy
that does nothing but what cloudflared does, bring `https://<domain>:<port>`
(and `https://127.0.0.1:<port>`, for workers) to the server's plain port.
"""
Base.@kwdef struct DevProxy
    caddy_bin::String
    authelia_bin::String
    password::String
    totp_secret::String
    admin::String = "admin"
    domain::String = "bonito.localhost"
    tunnel::Bool = false
end

# The proxy processes of a `dev_server(proxy = …)`, and where Caddy keeps its CA.
struct DevProxyRig
    caddy::Base.Process
    authelia::Base.Process
    dir::String
    root_cert::String      # Caddy's own CA: what a browser or worker must trust
end

mutable struct DevHandle
    url         :: String
    state         :: ServerState
    worker_proc   :: Union{Base.Process,Nothing}  # the worker runs as a SEPARATE process (see dev_server)
    state_dir     :: String
    working_dir   :: String
    worker_root   :: String
    worker_config :: String                       # throwaway BonitoWorker config dir (removed on close)
    # false ⇒ the dirs above were caller-supplied (`dir = ...`) and survive
    # `close` — a PERSISTENT rig (e.g. the docs-walkthrough state) that the
    # next `dev_server(dir = ...)` picks up with all projects/chats intact.
    ephemeral     :: Bool
    closed        :: Threads.Atomic{Bool}
    proxy         :: Union{DevProxyRig,Nothing}   # `dev_server(proxy = …)`: Caddy + Authelia in front
end

"""
    dev_server(; port=nothing, name="dev", auto_open=false) -> DevHandle

Boot a self-contained BonitoAgents server + a local worker in this
process. All state lives in `mktempdir()`-allocated directories and is
removed when you call `close(handle)` (or when the Julia process exits
— an atexit hook is registered).

The worker is a separate `BonitoWorker.start()` process: it dials the
server's `/w` over loopback. No systemd, no install script.

`proxy = DevProxy(...)` puts the real login proxy in front, as an install has it:
Caddy (with its own certificate authority) and Authelia, rendered from the same
code, the worker coming in through Caddy with its credential, and `handle.url`
Caddy's `https://<domain>:<port>`. The e2e items for the login use it.

`network = true` runs it the way a trusted network's server runs (`NetworkAuth`:
no login, and the worker comes in with a credential "Add worker" issued, which
the server checks itself), still on localhost.

`manage_harnesses = true` has the server declare the agent adapters, which the
worker then installs (off by default, so a dev server's worker downloads no Node).

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
                      agent_env::Dict{String,String}       = Dict{String,String}(),
                      heartbeat_interval::Real             = 15.0,
                      heartbeat_deadline::Real             = 45.0,
                      worker_link_grace::Real              = 300.0,
                      scan_on_connect::Bool                = true,
                      dir::Union{String,Nothing}           = nothing,
                      proxy::Union{DevProxy,Nothing}       = nothing,
                      network::Bool                        = false,
                      manage_harnesses::Bool               = false)
    (network && proxy !== nothing) &&
        error("dev_server: `network` and `proxy` are two different setups; pick one")
    # port=0 lets the kernel pick a free ephemeral port; Bonito.Server
    # writes the real port back to srv.port after start. Behind the proxy the
    # port has to be known up front: the Caddyfile forwards to it.
    chosen_port = port !== nothing ? port : proxy === nothing ? 0 : free_port()
    # `dir` makes the rig PERSISTENT: all four state dirs live under it, the
    # worker id is pinned once and reused, and `close` keeps everything on
    # disk — the next `dev_server(dir = ...)` resumes the same projects/chats.
    # (Used by the docs walkthrough so its seeded demo chats aren't re-paid
    # on every re-record.) Default stays the throwaway tempdir rig.
    ephemeral = dir === nothing
    local state_dir, working_dir, worker_root, worker_config
    if ephemeral
        state_dir   = mktempdir(; prefix = "bonitoagents-dev-state-")
        working_dir = mktempdir(; prefix = "bonitoagents-dev-work-")
        worker_root = mktempdir(; prefix = "bonitoagents-dev-worker-")
        worker_config = mktempdir(; prefix = "bonitoagents-dev-wcfg-")
    else
        root = abspath(String(dir))
        state_dir     = joinpath(root, "state")
        working_dir   = joinpath(root, "working")
        worker_root   = joinpath(root, "worker")
        worker_config = joinpath(root, "worker-config")
        foreach(mkpath, (state_dir, working_dir, worker_root, worker_config))
    end
    # Stable worker identity for a persistent rig: reuse the pinned id so
    # projects.json's worker_id foreign keys stay valid across relaunches.
    id_file   = joinpath(worker_config, "worker_id")
    worker_id = isfile(id_file) ? strip(read(id_file, String)) :
                                  "dev-" * randstring(8)
    # Route through `default_worker_name` so a machine whose
    # `friendly_hostname()` is empty (no `hostnamectl --pretty` configured,
    # `gethostname()` = "localhost") falls back to `<user>-<4 chars>` —
    # otherwise dev_server registered every worker as "localhost".
    actual_name = name === nothing ? BonitoWorker.default_worker_name(worker_id) : name

    # Without `proxy` there is nothing in front (a localhost server: its worker
    # connects without a credential, or with one on a `network` server). No
    # managed agent adapters either unless asked (`serve`'s default): a dev or
    # test worker must never download Node or npm packages by surprise.
    proxy === nothing || write_dev_proxy_config!(proxy, state_dir, chosen_port)
    state = serve(; host          = "127.0.0.1",
                    port          = chosen_port,
                    auth          = network ? NetworkAuth() : auth_mode(state_dir),
                    manage_harnesses,
                    state_dir     = state_dir,
                    working_dir   = working_dir,
                    heartbeat_interval = heartbeat_interval,
                    heartbeat_deadline = heartbeat_deadline,
                    worker_link_grace  = worker_link_grace,
                    scan_on_connect    = scan_on_connect)
    # Behind the proxy the worker goes through Caddy, like any other, with a
    # credential (issued first, so Caddy starts out knowing it): under 127.0.0.1
    # (the proxy's `worker_address`), since only browsers resolve `.localhost`.
    rig, credential = try
        proxy !== nothing ?
            (credential = add_worker_credential!(state, proxy.admin);
             (start_dev_proxy(proxy, state), credential)) :
        network ? (nothing, add_worker_credential!(state, default_owner(state.auth))) :
                  (nothing, "")
    catch
        close(state.srv)    # a proxy that did not come up leaves no server behind
        rethrow()
    end
    server_url = rig === nothing ? "http://127.0.0.1:$(state.srv.port)" :
                                   public_origin(state.auth.config, "127.0.0.1")

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
    ENV["BONITOAGENTS_CONFIG_DIR"] = worker_config
    write(id_file, worker_id)   # pin the dev id (reused on a persistent rig)
    resolved_agent_bin === nothing || (ENV["CLAUDE_AGENT_ACP"] = resolved_agent_bin)
    for (k, v) in agent_env; ENV[k] = v; end
    # Build the provider singleton list ONCE here, on the uncontended startup path
    # (ENV is now fully configured; no browser is attached yet). Without this the
    # list is built lazily on the FIRST chat bind — and that first build compiles
    # every descriptor constructor, reached concurrently from the bind path
    # (`default_provider`) AND the provider-dropdown render (`current_providers`).
    # Under nworkers=4 load that concurrent first-build stalled the bind for >90 s
    # ("chat view opened" timeout); worse, since the memo only caches AFTER a full
    # build, a stalled build was never cached, so every later bind on that worker
    # re-entered the build and re-hung. `refresh_providers!` builds + first-compiles
    # every descriptor constructor once here, uncontended, so no bind ever
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
    BonitoWorker.write_config!(; server_url = server_url, credential,
                                projects_root = worker_root, name = actual_name)
    # Behind the proxy the worker trusts Caddy's own CA, and only it; this
    # process keeps the system's.
    worker_proc, _ = rig === nothing ? BonitoWorker.spawn_worker() :
        withenv(BonitoWorker.spawn_worker, "JULIA_SSL_CA_ROOTS_PATH" => rig.root_cert)

    # `closed` guards close() idempotency (the worker lifecycle is the process).
    closed = Threads.Atomic{Bool}(false)
    url = rig === nothing ? server_url : public_origin(state.auth.config, proxy.domain)
    handle = DevHandle(url, state, worker_proc,
                       state_dir, working_dir, worker_root, worker_config,
                       ephemeral, closed, rig)

    # Best-effort cleanup if the Julia process exits without explicit close.
    Base.atexit(() -> close(handle))

    println()
    @info "BonitoAgents dev server running" url worker_name=actual_name
    println("  State dirs ($(ephemeral ? "auto-cleaned on close" : "PERSISTENT — kept on close")):")
    println("    state    $state_dir")
    println("    working  $working_dir")
    println("    worker   $worker_root")
    println()
    println("  Call close(h) to stop, or BonitoAgents.wait!(h) to block " *
            "until Ctrl+C.")
    println()

    auto_open && open_in_browser(url)

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
# `proc` is usually juliaup's launcher with the real julia as its child, so a
# signal to the handle alone can leave the actual worker (and its control
# socket) alive. `detach` at spawn made the launcher a group leader: signal the
# GROUP, gracefully first, then hard.
function stop_worker_proc!(proc::Base.Process; grace_s::Real = 1.5)
    process_exited(proc) && return
    BonitoWorker.kill_process_group!(proc, Base.SIGTERM)
    try
        kill(proc)                       # SIGTERM to the leader too, in case it left its group
    catch e
        e isa Base.IOError || rethrow()
    end
    deadline = grace_s / 0.05
    for _ in 1:ceil(Int, deadline)
        process_exited(proc) && return
        sleep(0.05)
    end
    @warn "dev_server: worker ignored SIGTERM within grace window; sending SIGKILL" grace_s
    BonitoWorker.kill_process_group!(proc)
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
    if h.proxy !== nothing
        foreach(stop_worker_proc!, (h.proxy.caddy, h.proxy.authelia))
        h.ephemeral && rm(h.proxy.dir; recursive = true, force = true)
    end
    # ...and the agents that worker started. It cannot do this itself: it is
    # killed, often with SIGKILL, so it runs no cleanup — and the agents are in
    # their OWN process groups (BonitoWorker spawns them `detach`ed so an agent's
    # MCP servers and eval workers die with it), so they do not go down with the
    # worker either.
    #
    # BonitoWorker's own startup sweep does not cover this case: every dev_server
    # gets a THROWAWAY config dir, so the next one looks for an id that has never
    # existed. We know the id we handed out, so we reap on the way down. Without
    # this the e2e suite leaked ~3 agent processes per full run, which is how the
    # box ended up at 93% memory and unrelated tests started failing on timing.
    try
        BonitoWorker.reap_agents_owned_by(strip(read(joinpath(h.worker_config, "worker_id"), String)))
    catch e
        e isa InterruptException && rethrow()
        @debug "dev_server: could not reap the worker's agents" exception = e
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
    close_worker_links!(h.state)
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
    # A persistent rig (`dir = ...`) keeps its dirs: that's its whole point.
    if h.ephemeral
        for d in (h.state_dir, h.working_dir, h.worker_root, h.worker_config)
            try
                rm(d; recursive = true, force = true)
            catch e
                @warn "dev_server: cleanup rm failed" path=d exception=e
            end
        end
    end
    return h
end

# ── The login proxy in front of a dev server ─────────────────────────────────

free_port() = let s = Sockets.listen(Sockets.IPv4(0x7f000001), 0)
    p = Int(Sockets.getsockname(s)[2]); close(s); p
end

# Where a dev rig keeps the proxy's files, logs and Caddy's CA: its own, never
# the current directory (a tunnel has no Caddyfile to take a directory from).
dev_proxy_dir(state_dir::AbstractString) = joinpath(state_dir, "proxy")

# proxy.json and the admin's account, as the installer writes them, before the
# server starts (it renders the proxy's files from them).
function write_dev_proxy_config!(p::DevProxy, state_dir::AbstractString, server_port::Int)
    dir = mkpath(dev_proxy_dir(state_dir))
    authelia_dir = mkpath(joinpath(dir, "authelia"))
    config = Dict{String,Any}(
        "domain" => p.domain, "admin" => p.admin,
        "port" => server_port, "authelia_port" => free_port(), "https_port" => free_port(),
        "authelia_bin" => p.authelia_bin, "users_file" => joinpath(authelia_dir, "users.yml"))
    p.tunnel ? (config["tls"] = "tunnel") : merge!(config, Dict(
        "auth_domain" => "auth." * p.domain, "http_port" => free_port(),
        "tls" => "internal", "worker_address" => "127.0.0.1",
        "caddy_bin" => p.caddy_bin, "caddyfile" => joinpath(dir, "Caddyfile")))
    atomic_write_json(joinpath(state_dir, "proxy.json"), config)
    # The admin's account, unless a persistent rig has its accounts already. A dev
    # rig's password is no secret: it may cross a command line.
    accounts = joinpath(state_dir, "accounts.json")
    isfile(accounts) && return nothing
    out = read(`$(p.authelia_bin) crypto hash generate argon2 --password $(p.password)`, String)
    digest = match(r"Digest:\s*(\S+)", out)
    digest === nothing && error("`authelia crypto hash generate` printed no digest: $(out)")
    atomic_write_json(accounts, [Dict(Account(p.admin, p.admin, "", ["admins"], false, String(digest[1])))];
                      mode = 0o600)
    return nothing
end

# Caddy and Authelia, on the files the server just rendered.
function start_dev_proxy(p::DevProxy, state::ServerState)
    cfg = state.auth.config
    dir = dev_proxy_dir(state.state_dir)
    config = authelia_config_file(cfg)
    # The admin's second factor, as if they had registered an authenticator app
    # (into a database brought to Authelia's schema first).
    migrate_authelia_storage(cfg)
    run(pipeline(`$(p.authelia_bin) storage user totp generate $(p.admin) --secret $(p.totp_secret) --force --config $(config)`;
                 stdout = devnull))
    log(name) = joinpath(dir, name * ".log")
    # Both go down with this process, however it ends (the kernel sees to it), like
    # the dev worker: a crashed test run must not leave them listening.
    with_parent(cmd) = `setpriv --pdeathsig KILL -- $cmd`
    authelia = run(pipeline(with_parent(`$(p.authelia_bin) --config $(config)`);
                            stdout = log("authelia"), stderr = log("authelia")); wait = false)
    caddy_env = merge(ENV, Dict("XDG_DATA_HOME" => mkpath(joinpath(dir, "data")),
                                "XDG_CONFIG_HOME" => mkpath(joinpath(dir, "config"))))
    caddyfile = p.tunnel ? write_dev_tunnel(p, cfg, dir) : cfg.caddyfile
    caddy = run(pipeline(setenv(with_parent(`$(p.caddy_bin) run --config $(caddyfile) --adapter caddyfile --watch`),
                                caddy_env); stdout = log("caddy"), stderr = log("caddy")); wait = false)
    root_cert = joinpath(dir, "data", "caddy", "pki", "authorities", "local", "root.crt")
    listening(port) = try
        close(Sockets.connect(Sockets.IPv4(0x7f000001), port)); true
    catch e
        e isa Base.IOError || rethrow()
        false
    end
    up() = isfile(root_cert) && listening(cfg.https_port) && listening(cfg.authelia_port)
    if timedwait(up, 30.0) !== :ok
        foreach(stop_worker_proc!, (caddy, authelia))
        error("dev_server: the proxy did not come up within 30 s; see $(log("caddy")) and $(log("authelia"))")
    end
    return DevProxyRig(caddy, authelia, dir, root_cert)
end

# The tunnel's stand-in: HTTPS for the dashboard's name (browsers) and for
# 127.0.0.1 (workers, which do not resolve `.localhost`), forwarded unchanged to
# the server's plain port, as cloudflared forwards to `http://localhost:8038`.
function write_dev_tunnel(p::DevProxy, cfg::ProxyConfig, dir::AbstractString)
    file = joinpath(dir, "tunnel.caddy")
    write(file, """
        {
        \tadmin off
        \tskip_install_trust
        \tdefault_bind 127.0.0.1
        \thttps_port $(cfg.https_port)
        \thttp_port $(free_port())
        }

        $(p.domain), 127.0.0.1 {
        \ttls internal
        \treverse_proxy 127.0.0.1:$(cfg.port)
        }
        """)
    return file
end

"""
    fetch_proxy_binaries(dir; caddy = "2.11.4", authelia = "4.39.28") -> (caddy, authelia)

Download Caddy and Authelia for this machine into `dir` (once), each checked
against the checksums its project publishes, as `install_server.sh` does.
Returns the two binaries' paths, for `DevProxy`.
"""
function fetch_proxy_binaries(dir::AbstractString; caddy::AbstractString = "2.11.4",
                              authelia::AbstractString = "4.39.28")
    Sys.islinux() || error("fetch_proxy_binaries: Linux only (Caddy and Authelia builds for $(Sys.KERNEL) differ)")
    arch = Sys.ARCH === :x86_64 ? "amd64" : Sys.ARCH === :aarch64 ? "arm64" : error("no builds for $(Sys.ARCH)")
    mkpath(dir)
    function fetch(name, version, file, sums, hashfn)
        bin = joinpath(dir, "$(name)-$(version)")
        isfile(bin) && return bin
        tarball = joinpath(dir, file)
        base = name == "caddy" ? "https://github.com/caddyserver/caddy/releases/download/v$(version)" :
                                 "https://github.com/authelia/authelia/releases/download/v$(version)"
        write(tarball, HTTP.get("$(base)/$(file)").body)
        published = match(Regex("^([0-9a-f]+)\\s+\\Q$(file)\\E\$", "m"), String(HTTP.get("$(base)/$(sums)").body))
        published === nothing && error("$(sums) lists no checksum for $(file)")
        bytes2hex(hashfn(read(tarball))) == published[1] ||
            error("$(file) does not match its published checksum")
        unpacked = mktempdir(dir)
        run(`tar -xzf $(tarball) -C $(unpacked) $(name)`)
        mv(joinpath(unpacked, name), bin; force = true)
        chmod(bin, 0o755)
        rm(unpacked; recursive = true); rm(tarball)
        return bin
    end
    return (caddy = fetch("caddy", caddy, "caddy_$(caddy)_linux_$(arch).tar.gz",
                          "caddy_$(caddy)_checksums.txt", SHA.sha512),
            authelia = fetch("authelia", authelia, "authelia-v$(authelia)-linux-$(arch).tar.gz",
                             "checksums.sha256", SHA.sha256))
end

"""
    wait!(handle)

Block until `Ctrl+C`, then return so the caller's cleanup runs. Useful from
scripts and `bin` wrappers that start a [`dev_server`](@ref) and should stay up
until interrupted; from the REPL just keep the handle and run other code in
parallel instead.
"""
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
