module BonitoWorker

# Outbound-only worker: dials the BonitoAgents server, holds a "control" WS open,
# spawns claude-agent-acp + a dedicated per-session WS each time the server
# requests a new session.
#
# Worker has NO inbound listener — no firewall hole on the worker side.
# Single port to open is on the server (8038), already needed for browsers.

using HTTP, HTTP.WebSockets, JSON, RemoteSync
using Scratch: @get_scratch!
import AgentProviders   # provider descriptors (find_provider) — the SSOT shared with the server

# Per-install config directory, managed by Scratch.jl. Resolves to
# `~/.julia/scratchspaces/<BonitoWorker-uuid>/config/` on every OS, so we get
# a writable, cross-platform location without poking at `XDG_DATA_HOME` /
# `HOME` / `%APPDATA%` ourselves. Holds the stable `worker_id`, the install
# `config.json`, and the detached worker's `worker.log`.
#
# `BONITOAGENTS_CONFIG_DIR` overrides it — used by `dev_server` to run a real
# install + worker against a throwaway dir (isolated from a machine's real
# install, and removable on cleanup). The spawned worker inherits the env var,
# so it reads the same dir.
function config_dir()
    override = get(ENV, "BONITOAGENTS_CONFIG_DIR", "")
    isempty(override) && return @get_scratch!("config")
    mkpath(override)
    return override
end

# Stable per-install identity for this worker. Generated once and persisted so
# the server can recognise the same physical install across hostname/IP
# changes (DHCP renew, VPN flip, laptop carried between Wi-Fi networks). The
# display name is just a label — this id is the dict key on the server.
worker_id_path() = joinpath(config_dir(), "worker_id")

# Install config written by `install!` and read back by `start`.
config_path() = joinpath(config_dir(), "config.json")

# ── Singleton guard ──────────────────────────────────────────────────────────
# Two worker processes sharing the same persisted `worker_id` fight over the
# server's control-WS registration and tear each other's chat sessions down
# (the server keys workers by id). There is no OS service supervising us, so
# `start()` / `spawn_worker()` could otherwise launch duplicates freely (a
# double install, a manual start on top of an autostart). A pidfile is the
# cross-platform guard: record our pid, and refuse to start if a live worker
# already holds it.
pidfile_path() = joinpath(config_dir(), "worker.pid")

# The pid recorded in the pidfile, or `nothing` if absent/empty/garbage.
function read_pidfile(path::AbstractString = pidfile_path())
    isfile(path) || return nothing
    return tryparse(Int, strip(read(path, String)))
end

# Pid of a *live, other* worker holding the pidfile, or `nothing` if the slot is
# free (no file, stale file pointing at a dead pid, or it's our own pid). A
# `pid_running` result of `nothing` (can't determine) is treated as "not
# confirmed running" so an unverifiable stale file never permanently blocks
# startup — the failure mode of a false-free is a duplicate (caught server-side
# by the identity guard), which is better than a worker that refuses to boot.
function running_worker_pid(path::AbstractString = pidfile_path())
    pid = read_pidfile(path)
    pid === nothing && return nothing
    pid == getpid() && return nothing
    pid_running(pid) === true ? pid : nothing
end

# Claim the pidfile for this process and arrange to release it on exit. Best
# effort: a hard kill (SIGKILL) leaves a stale file, which the next start
# detects as dead and overwrites.
function claim_pidfile!(path::AbstractString = pidfile_path())
    mkpath(dirname(path))
    write(path, string(getpid()))
    atexit() do
        # Only remove if it's still ours — a successor that took over the slot
        # must keep its own claim.
        try
            read_pidfile(path) == getpid() && rm(path; force = true)
        catch
        end
    end
    return nothing
end

# UUIDv4-shaped identifier built from `hash(time_ns(), gethostname(), pid())`.
# We deliberately avoid pulling in the Random or UUIDs stdlibs here — adding
# a new dep to BonitoWorker forces the user's runtime Manifest.toml to be
# re-resolved (Pkg.resolve), which is friction we don't need for a one-shot
# id generation. The id is persisted on first run, so collision risk is
# limited to two installs that happen in the same nanosecond from the same
# pid on the same host (i.e. effectively zero).
function generate_worker_id()
    seed = "$(time_ns())-$(getpid())-$(gethostname())-$(rand(UInt64))"
    h1 = string(hash(seed),                     base = 16, pad = 16)
    h2 = string(hash(string(h1, time_ns())),    base = 16, pad = 16)
    bytes = h1 * h2  # 32 hex chars
    return string(bytes[1:8],   "-",
                  bytes[9:12],  "-",
                  bytes[13:16], "-",
                  bytes[17:20], "-",
                  bytes[21:32])
end

function load_or_generate_worker_id()
    path = worker_id_path()
    if isfile(path)
        id = strip(read(path, String))
        !isempty(id) && return String(id)
    end
    id = generate_worker_id()
    mkpath(dirname(path))
    write(path, id)
    @info "BonitoWorker: generated stable worker_id" path id
    return id
end

# OS-friendly display name. Prefers the user-configured "pretty" name when
# the OS exposes one (macOS ComputerName, Linux hostnamectl pretty); falls
# back to `gethostname()`. Always returns a String; never throws.
function friendly_hostname()
    name = ""
    @static if Sys.isapple()
        # macOS System Settings → General → About → Name. Includes spaces /
        # apostrophes (e.g. "Sebastian's MacBook Pro"). `scutil` ships on
        # every macOS install — no Homebrew dependency.
        try
            name = strip(read(`scutil --get ComputerName`, String))
        catch
        end
    elseif Sys.islinux()
        # `hostnamectl --pretty` prints the user-set pretty hostname if
        # configured, otherwise empty. systemd ships it on most distros.
        try
            name = strip(read(`hostnamectl --pretty`, String))
        catch
        end
    end
    isempty(name) && (name = gethostname())
    # `localhost` is the universal placeholder, not a useful display name —
    # treat it as empty so callers (`default_worker_name`, `dev_server`)
    # can fall through to user-id derivation. Otherwise every freshly
    # installed Linux box ends up registering as "localhost" on the
    # dashboard.
    lowercase(String(name)) == "localhost" && (name = "")
    return String(name)
end

# Default display name. Falls back through friendly-hostname → username →
# "worker". When the hostname is "localhost"/empty (common on freshly-
# installed Linux distros) we splice in a 4-char chunk of the worker_id so
# two laptops with the same `gethostname()=="localhost"` still get distinct
# *display* names — the dict key is the full UUID either way, but the user
# sees something friendlier than "localhost" twice.
function default_worker_name(worker_id::String)
    h = friendly_hostname()
    if !isempty(h) && lowercase(h) != "localhost"
        return h
    end
    user = get(ENV, "USER", get(ENV, "USERNAME", "worker"))
    return "$(user)-$(first(worker_id, 4))"
end

# ── BonitoMCP launch config ────────────────────────────────────────────────────
# The BonitoMCP stdio server is launched by claude-agent-acp as a plain
# `julia <args…>` process — no shell wrapper script. That's what makes it
# cross-platform: a `.sh`/`.cmd` wrapper would need an OS-specific variant,
# but `julia` + an argv array runs identically on Linux/macOS/Windows.
#
# `julia_bin()` resolves the current interpreter; `Base.active_project()` is
# whatever env this worker itself runs in (the shared `@bonito-agents` after a
# normal install, or the monorepo project in dev) — BonitoMCP is co-installed
# there, so the MCP process resolves it without any extra setup.
julia_bin() = joinpath(Sys.BINDIR::String, Base.julia_exename())

function mcp_args()
    project = something(Base.active_project(), "@bonito-agents")
    return String[
        "--project=$(project)",
        "--startup-file=no",
        "--threads=auto",
        "-e", "using BonitoMCP; BonitoMCP.run_stdio()",
    ]
end

# ── systemd --user service (Linux) ───────────────────────────────────────────
# Optional supervised run mode chosen at install time. A `--user` unit gives us
# start-on-boot, restart-on-crash, and a memory cap (so a runaway eval can't
# take the whole box down) — and the service manager is itself the singleton, so
# it composes with (and reinforces) the pidfile guard. Linux-only; macOS/Windows
# stay on the bare-detached path for now.
const SERVICE_NAME = "bonito-worker.service"

systemd_user_dir()  = joinpath(homedir(), ".config", "systemd", "user")
service_unit_path() = joinpath(systemd_user_dir(), SERVICE_NAME)

# Is a `systemctl --user` manager reachable here? False on non-Linux, no systemd,
# or environments without a user manager (some containers, WSL without systemd).
function systemd_user_available()
    Sys.islinux() || return false
    Sys.which("systemctl") === nothing && return false
    try
        return success(pipeline(`systemctl --user show-environment`;
                                stdout = devnull, stderr = devnull))
    catch
        return false
    end
end

# The unit text. PURE (no side effects) so install can diff it against the
# on-disk unit and only rewrite+reload when it actually changed (template bump,
# new server, a juliaup update moving `julia`, a different PATH). `path_env` is
# baked in because systemd --user services do NOT inherit the interactive
# shell's PATH — without it the worker can't find `claude-agent-acp`/`node`/`git`
# at runtime. We capture the install-time PATH, which has them resolved.
function render_service_unit(; julia::AbstractString = julia_bin(),
                               project::AbstractString = "@bonito-agents",
                               projects_root::AbstractString = pwd(),
                               memory_max::AbstractString = "85%",
                               path_env::AbstractString = get(ENV, "PATH", ""))
    exec = "$(julia) --project=$(project) --startup-file=no " *
           "-e 'using BonitoWorker; BonitoWorker.start()'"
    return """
    [Unit]
    Description=BonitoAgents worker
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    Environment=PATH=$(path_env)
    ExecStart=$(exec)
    Restart=on-failure
    RestartSec=5
    # Cap the whole process tree (worker + MCP + Malt eval workers share the
    # unit's cgroup) so a runaway computation gets OOM-killed + restarted instead
    # of freezing the desktop. Tune or remove this line if you want no limit.
    MemoryMax=$(memory_max)
    WorkingDirectory=$(projects_root)

    [Install]
    WantedBy=default.target
    """
end

service_installed() = isfile(service_unit_path())

# Best-effort: let the service start at boot without an active login session.
# enable-linger for one's own user is normally allowed via polkit; if it isn't,
# the service still runs while logged in — so we warn, not error.
function enable_linger!()
    user = get(ENV, "USER", "")
    isempty(user) && (user = try strip(read(`whoami`, String)) catch; "" end)
    isempty(user) && return false
    try
        run(pipeline(`loginctl enable-linger $user`; stdout = devnull, stderr = devnull))
        return true
    catch e
        @warn "BonitoWorker: could not enable linger (service won't auto-start at boot " *
              "without an active session); enable it manually with `loginctl enable-linger $user`" exception = e
        return false
    end
end

# Stop a bare-detached worker if one is holding the pidfile, so a mode switch
# (background → service) or a re-install with `code_changed=true` doesn't
# leave the old process fighting the new one over the server registration.
# Tries graceful first (SIGTERM / taskkill), waits up to 10 s for exit, then
# escalates to SIGKILL / taskkill /F if the worker is wedged on something.
# After this returns, the pidfile is gone and a fresh `start()` is safe.
function stop_running_worker!(; grace::Real = 10.0)
    pid = read_pidfile()
    pid === nothing && return
    pid == getpid() && return
    if pid_running(pid) === true
        signal_worker_graceful(pid)
        deadline = time() + grace
        while time() < deadline
            pid_running(pid) === true || break
            sleep(0.1)
        end
        # Still alive? Escalate.
        if pid_running(pid) === true
            @warn "BonitoWorker: graceful stop timed out; force-killing" pid grace
            signal_worker_force(pid)
            for _ in 1:30
                pid_running(pid) === true || break
                sleep(0.1)
            end
        end
    end
    rm(pidfile_path(); force = true)
    return
end

@static if Sys.iswindows()
    # `taskkill` ships in every Windows install; PID-targeted form is the
    # closest WinAPI-free analogue of `kill -TERM`. `/T` includes child
    # processes, so a worker that spawned subagents takes them with it.
    function signal_worker_graceful(pid::Integer)
        try
            run(pipeline(`taskkill /PID $(pid) /T`, devnull, devnull); wait = false)
        catch
        end
    end
    function signal_worker_force(pid::Integer)
        try
            run(pipeline(`taskkill /F /PID $(pid) /T`, devnull, devnull); wait = false)
        catch
        end
    end
else
    function signal_worker_graceful(pid::Integer)
        try
            ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(15))   # SIGTERM
        catch
        end
    end
    function signal_worker_force(pid::Integer)
        try
            ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(9))    # SIGKILL
        catch
        end
    end
end

"""
    install_service!(; projects_root, memory_max="85%") -> (path, changed::Bool)

Idempotently install/upgrade the `--user` systemd unit and make sure it's
enabled (boot) + running. Re-running is safe:

  * unit absent            → write, daemon-reload, enable, start
  * unit present, same     → no-op (just ensure enabled + running)
  * unit present, changed  → rewrite, daemon-reload, enable, RESTART

"changed" is a byte compare of the rendered unit vs the on-disk one, so it
catches template bumps, a new `julia` path, a different PATH, etc.
"""
function install_service!(; projects_root::AbstractString = pwd(),
                            memory_max::AbstractString = "85%",
                            # When the underlying Pkg env moved forward but
                            # the unit text is unchanged, we still need to
                            # bounce the service so it picks up new code.
                            code_changed::Bool = true)
    systemd_user_available() ||
        error("BonitoWorker: systemctl --user not available; cannot install a service")
    mkpath(systemd_user_dir())
    path     = service_unit_path()
    desired  = render_service_unit(; projects_root, memory_max)
    existing = isfile(path) ? read(path, String) : nothing
    changed  = existing != desired

    # Any bare-detached worker must go first — the service will claim the pidfile.
    stop_running_worker!()

    if changed
        write(path, desired)
        run(`systemctl --user daemon-reload`)
    end
    run(`systemctl --user enable $SERVICE_NAME`)
    enable_linger!()
    # `restart` applies a changed unit OR new code (since the process keeps
    # the old `using BonitoMCP` modules loaded until it exits). `start` is a
    # no-op when the service is already running, which silently strands the
    # user on old code on re-install. Treat code_changed the same as unit-
    # changed for the bounce decision.
    must_restart = changed || code_changed
    run(`systemctl --user $(must_restart ? "restart" : "start") $SERVICE_NAME`)
    return path, changed
end

"""
    uninstall_service!()

Stop + disable + remove the `--user` unit if present. No-op otherwise. Used when
the user switches back to the plain background run mode.
"""
function uninstall_service!()
    systemd_user_available() || return
    service_installed() || return
    run(ignorestatus(`systemctl --user disable --now $SERVICE_NAME`))
    rm(service_unit_path(); force = true)
    run(ignorestatus(`systemctl --user daemon-reload`))
    return
end

# ── Run-mode selection (interactive, via the controlling terminal) ───────────
# The installer runs as `curl … | julia -`, so the script's stdin IS the program
# text (already at EOF) — we CANNOT read a choice from stdin. Read the
# controlling terminal directly, the way `curl | sh` installers do. Returns the
# trimmed answer, or `nothing` when there's no tty (CI / nohup / `ssh` without
# `-t`) OR no answer arrives within `timeout` (a tty that's openable but has no
# typist — some CI ptys), so the caller can fall back to a safe default rather
# than hang the install forever.
function prompt_tty(question::AbstractString; timeout::Real = 120)
    tty = try
        open("/dev/tty", "r")
    catch
        return nothing
    end
    try
        print(question)
        flush(stdout)
        result = Ref{Union{String,Nothing}}(nothing)
        task = @async try
            result[] = strip(readline(tty))
        catch
            # `close(tty)` below unblocks a pending readline → lands here.
        end
        if timedwait(() -> istaskdone(task), float(timeout)) !== :ok
            println("\n(no response in $(round(Int, timeout))s; using the default)")
            return nothing
        end
        return result[]
    finally
        close(tty)   # also unblocks the reader task if it's still waiting
    end
end

# Pure decision: map a prompt answer + current service presence to a run mode.
# Factored out of the IO so it's unit-testable without a tty or systemd.
#   nothing (no answer) → keep an existing service (don't silently downgrade),
#                         else background (don't silently enable a boot service)
#   "2"                 → background
#   anything else / ""  → service (the recommended default)
function decide_run_mode(answer::Union{AbstractString,Nothing}, service_exists::Bool)
    answer === nothing && return service_exists ? :service : :background
    return answer == "2" ? :background : :service
end

# Decide how the worker should run. Linux + systemd → ask at the terminal;
# no systemd → always background. When a service is already installed the prompt
# makes that the visible default ("keep it"), so a re-run that just hits Enter
# never accidentally downgrades to a bare process.
function choose_run_mode()
    systemd_user_available() || return :background
    have = service_installed()
    note = have ? " — a service is already installed" : ""
    svc_line = have ?
        "[1] Service (current, recommended) — keep the boot/restart/memory-capped service" :
        "[1] Service (recommended) — start on boot, restart on crash, memory-capped"
    answer = prompt_tty("""
==> How should the BonitoAgents worker run?$(note)
    $(svc_line)
    [2] Background process — stops on reboot; you restart it manually
  choice [1]: """)
    mode = decide_run_mode(answer, have)
    answer === nothing &&
        @info "BonitoWorker: no run-mode answer; using default" mode
    return mode
end

# Apply a chosen run mode. `:service` reconciles the unit (idempotent upgrade);
# `:background` tears down any service then spawns the detached process.
function apply_run_mode!(mode::Symbol; projects_root::AbstractString = pwd(),
                          code_changed::Bool = true)
    if mode === :service
        path, changed = install_service!(; projects_root, code_changed)
        return (; mode, path, changed)
    else
        uninstall_service!()          # ensure no service competes with the bg process
        # `code_changed=true` triggers a stop+respawn even if the live PID is
        # still healthy — needed to reload new BonitoMCP/BonitoWorker code.
        proc, logfile = spawn_worker(; force_restart = code_changed)
        return (; mode, proc, logfile)
    end
end

# ── Install / start ────────────────────────────────────────────────────────────

# Write the worker's `config.json` (read back by `start()`). Shared by `install!`
# and `dev_server`, so the two stay in lock-step. `name` defaults to the derived
# per-install label; callers can override it.
function write_config!(; server_url::AbstractString,
                          secret::AbstractString,
                          projects_root::AbstractString = pwd(),
                          name::AbstractString = default_worker_name(load_or_generate_worker_id()))
    config = Dict(
        "server_url"    => String(server_url),
        "secret"        => String(secret),
        "name"          => String(name),
        "projects_root" => abspath(projects_root),
    )
    cfg = config_path()
    write(cfg, JSON.json(config))
    @info "BonitoWorker: wrote config" path=cfg server_url projects_root=config["projects_root"]
    return cfg
end

"""
    BonitoWorker.install!(; server_url, secret, projects_root = pwd(), run_mode = :prompt)

Persist the worker config into the Scratch config space and bring the worker up
in the chosen run mode. Called at the end of `install.jl`; also the entry point
for re-pointing an existing install at a different server (just re-run it).

`run_mode`:
  * `:prompt`     — ask at the controlling terminal (Linux+systemd only), else background
  * `:service`    — install/upgrade the systemd `--user` service
  * `:background` — bare detached process (current default elsewhere)
"""
function install!(; server_url::String,
                    secret::String,
                    projects_root::String = pwd(),
                    run_mode::Symbol = :prompt,
                    # Did the underlying Pkg env actually move forward (per
                    # `install.jl`'s before/after tree-sha diff)? When `true`,
                    # the running worker / service is restarted so the new
                    # code is actually loaded — otherwise the user only sees
                    # the new package version after a manual kill.
                    code_changed::Bool = true)
    cfg = write_config!(; server_url, secret, projects_root)

    mode = run_mode == :prompt ? choose_run_mode() : run_mode
    result = apply_run_mode!(mode; projects_root = abspath(projects_root),
                              code_changed = code_changed)
    println()
    if mode === :service
        verb = result.changed ? (service_installed() ? "installed/updated" : "installed") : "already up to date"
        println("==> BonitoAgents worker service $(verb)")
        println("    unit   : ", result.path)
        println("    config : ", cfg)
        println("    server : ", server_url)
        println()
        println("    Manage it with:")
        println("      systemctl --user status  $(SERVICE_NAME)")
        println("      systemctl --user restart $(SERVICE_NAME)")
        println("      journalctl --user -u $(SERVICE_NAME) -f")
        println("    Switch back to a plain process: re-run the installer and pick [2].")
        println()
        return result
    end

    # Background mode.
    proc = result.proc
    if proc === nothing
        # spawn_worker found a healthy live worker and code didn't change, so
        # we left it running. The config WAS rewritten above (line 484), so the
        # running worker picks up new server/secret on its next reconnect; only
        # a different binary (julia path / Pkg env shift not covered by
        # code_changed) needs the manual restart hint below.
        println("==> BonitoAgents worker already running (pid $(running_worker_pid()))")
        println("    config updated : ", cfg)
        println("    log            : ", result.logfile)
        println("    server         : ", server_url)
        println()
        println("    Code is already up to date; the running worker picks up the new")
        println("    server/secret on its next reconnect. If you need a hard restart")
        println("    anyway:")
        println()
        println("      julia --project=@bonito-agents -e \"using BonitoWorker; BonitoWorker.stop_running_worker!(); BonitoWorker.start()\"")
        println()
        return result
    end
    println("==> BonitoAgents worker started (pid $(getpid(proc)))")
    println("    config : ", cfg)
    println("    log    : ", result.logfile)
    println("    server : ", server_url)
    println()
    println("    The worker runs detached and survives this shell. To start it")
    println("    again later (e.g. after a reboot), run:")
    println()
    println("      julia --project=@bonito-agents -e \"using BonitoWorker; BonitoWorker.start()\"")
    println()
    return result
end

# Launch `BonitoWorker.start()` as a detached background process so it outlives
# the installer (the `curl … | julia -` pipe exits as soon as install.jl
# returns). `detach` makes the child independent of the parent process group on
# every OS; stdout+stderr append to `worker.log` in the config dir.
#
# `force_restart=true` (set by the installer when the Pkg env actually moved
# forward) stops the live worker first and then respawns — without this the
# pidfile keeps a stale process alive after a `git pull`-style update, and the
# user never sees the new code load. The PID-lock invariant is preserved:
# `stop_running_worker!` waits for exit before we spawn the replacement.
function spawn_worker(; force_restart::Bool = false)
    logfile = joinpath(config_dir(), "worker.log")
    other = running_worker_pid()
    if other !== nothing
        if force_restart
            @info "BonitoWorker: stopping live worker to load updated code" pid = other
            stop_running_worker!()
        else
            # Don't launch a duplicate on top of a healthy live worker — the
            # child's own `start()` also guards via pidfile, but skipping the
            # spawn here keeps the install output honest ("already running"
            # instead of "started pid N" for a process that immediately exits).
            @info "BonitoWorker: worker already running; not spawning a duplicate" pid = other
            return nothing, logfile
        end
    end
    project = something(Base.active_project(), "@bonito-agents")
    cmd = `$(julia_bin()) --project=$(project) --startup-file=no -e $("using BonitoWorker; BonitoWorker.start()")`
    proc = run(pipeline(detach(cmd); stdout = logfile, stderr = logfile, append = true);
               wait = false)
    return proc, logfile
end

"""
    BonitoWorker.start(; force=false)

Read the install config written by `install!` and connect to the server.
Blocks forever (reconnecting on drop). This is the worker process entry point.

Refuses to start if another live worker already holds the pidfile (a duplicate
would fight it over the server's control-WS registration). Pass `force=true`
to start anyway (e.g. you intend to replace a wedged instance you'll kill).
"""
# Bind our lifetime to the spawning parent's (Linux only). `dev_server` sets
# `BONITOAGENTS_DIE_WITH_PARENT` to its own PID; we then ask the kernel to SIGKILL
# us the moment that parent dies — via `PR_SET_PDEATHSIG`, which fires even on an
# OOM-kill / `kill -9` that skips the parent's atexit cleanup. Without this a
# detached worker (we `setsid` to look like a real install) outlives an abnormally
# -killed test runner and orphans its whole agent subtree → the process explosion.
# Production leaves the var UNSET: the worker is a service meant to outlive its
# launcher, so it stays detached.
function _bind_lifetime_to_parent!()
    Sys.islinux() || return nothing
    want = tryparse(Int, get(ENV, "BONITOAGENTS_DIE_WITH_PARENT", ""))
    want === nothing && return nothing
    # PR_SET_PDEATHSIG (1) = SIGKILL (9).
    ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 1, 9, 0, 0, 0)
    # Race: pdeathsig only fires on a FUTURE parent death. If the parent already
    # died (we've been reparented) before we set it, exit now instead of lingering.
    ccall(:getppid, Cint, ()) == want ||
        (@warn "BonitoWorker: spawning parent already gone; exiting"; exit(0))
    return nothing
end

function start(; force::Bool = false)
    _bind_lifetime_to_parent!()
    cfg = config_path()
    isfile(cfg) || error("BonitoWorker: no config at $cfg — run the installer first " *
                          "(`curl -fsSL <server-url>/install.jl | julia -`)")
    other = running_worker_pid()
    if other !== nothing && !force
        @warn "BonitoWorker: a worker is already running; refusing to start a duplicate" *
              " (kill it first, or call start(; force=true))" pid = other pidfile = pidfile_path()
        return nothing
    end
    claim_pidfile!()
    config = JSON.parse(read(cfg, String))
    worker_id = load_or_generate_worker_id()
    connect_and_serve(;
        server_url    = String(config["server_url"]),
        secret        = String(config["secret"]),
        worker_id     = worker_id,
        name          = String(get(config, "name", default_worker_name(worker_id))),
        projects_root = String(get(config, "projects_root", pwd())),
    )
end

# Public entry
"""
    BonitoWorker.connect_and_serve(; server_url, secret, name, projects_root,
                                   mcp_command, mcp_args, agent_bin,
                                   retry_delay = 5.0)

Open a control WS to `server_url/worker-ws`, send the hello frame, then loop
on commands. Reconnects with `retry_delay` between attempts. Blocks forever.
"""
function connect_and_serve(; server_url::String,
                            secret::String,
                            worker_id::String     = load_or_generate_worker_id(),
                            name::String          = default_worker_name(worker_id),
                            mcp_command::String   = julia_bin(),
                            mcp_arguments::Vector{String} = mcp_args(),
                            projects_root::String = joinpath(homedir(), "bonitoagents-projects"),
                            agent_bin::String     = find_agent_bin(),
                            retry_delay::Real     = 5.0)
    while true
        try
            run_control_session(; server_url, secret, worker_id, name, mcp_command,
                                  mcp_arguments, projects_root, agent_bin)
        catch e
            e isa InterruptException && rethrow()
            @error "BonitoWorker: control session crashed; reconnecting" exception=(e, catch_backtrace())
        end
        # The control link is down ⇒ the server has torn down this worker's
        # registration and evicted its chat models — every live session here is
        # already abandoned on the other end. Reap agents + session transports
        # NOW so nothing leaks across the reconnect (the fresh registration
        # lazily re-opens sessions on the next user turn).
        reap_all_sessions!("control link lost")
        @info "BonitoWorker: reconnecting in $(retry_delay)s"
        sleep(retry_delay)
    end
end

# The receive-watchdog below is armed ONLY when the server's hello-ack
# advertises `heartbeat_interval` (it pings on that cadence). An earlier,
# unconditional idle-watchdog was a bug: against a server that never pings, a
# perfectly healthy but idle control connection receives no frames and the
# watchdog killed it. With advertised pings, "no frame for several intervals"
# really does mean a half-open TCP link (laptop suspend / NAT drop with no
# RST) — the case where blocked sends wedge the relay forever and only a
# close + re-dial recovers.

# Control WS lifecycle
function run_control_session(; server_url, secret, worker_id, name, mcp_command,
                               mcp_arguments, projects_root, agent_bin,
                               agent_env::Dict{String,String} = Dict{String,String}())
    control_url = ws_url(server_url, "/worker-ws")
    @info "BonitoWorker: connecting to control WS" control_url worker_id name
    WebSockets.open(control_url) do ws
        WebSockets.send(ws, JSON.json(Dict(
            "type"          => "hello",
            "secret"        => secret,
            "worker_id"     => worker_id,
            "name"          => name,
            "hostname"      => gethostname(),
            "username"      => get(ENV, "USER", get(ENV, "USERNAME", "")),
            "home"          => homedir(),
            "mcp_path"      => mcp_command,
            "mcp_args"      => mcp_arguments,
            "projects_root" => projects_root,
        )))

        ack_raw = WebSockets.receive(ws)
        ack = JSON.parse(String(ack_raw))
        if !get(ack, "ok", false)
            error("server rejected hello: $(get(ack, "error", "unknown"))")
        end
        @info "BonitoWorker: registered with server" name=name

        last_rx  = Ref(time())
        hb_alive = Ref(true)
        hb = get(ack, "heartbeat_interval", nothing)
        if hb isa Number && hb > 0
            Base.errormonitor(@async while hb_alive[]
                sleep(Float64(hb))
                hb_alive[] || break
                if time() - last_rx[] > 4 * Float64(hb)
                    @warn "BonitoWorker: no server traffic for 4 heartbeat intervals — killing zombie control WS"
                    # Kill the TRANSPORT, not close(ws): the polite close writes a
                    # CLOSE frame under ws.sendlock — on a wedged link (interface
                    # switch: WLAN→LAN) a blocked relay send already HOLDS that
                    # lock, so close(ws) would deadlock behind it. The transport
                    # close wakes all blocked readers/writers; the retry loop then
                    # re-dials over the new interface.
                    try ws.close_transport!() catch end
                    break
                end
            end)
        end

        for frame in ws
            last_rx[] = time()
            cmd = JSON.parse(String(frame))
            t = get(cmd, "type", "")
            if t == "open_session"
                @async handle_open_session(ws, server_url, secret, agent_bin, cmd; agent_env)
            elseif t == "close_session"
                @async handle_close_session(cmd)
            elseif t == "open_transfer"
                @async handle_open_transfer(server_url, secret, cmd)
            elseif t == "list_dir"
                @async handle_list_dir(ws, cmd)
            elseif t == "stat_path"
                @async handle_stat_path(ws, cmd)
            elseif t == "list_project_files"
                @async handle_list_project_files(ws, cmd)
            elseif t == "inspect_path"
                @async handle_inspect_path(ws, cmd)
            elseif t == "tail_file"
                @async handle_tail_file(ws, cmd)
            elseif t == "kill_file_writers"
                @async handle_kill_file_writers(ws, cmd)
            elseif t == "scan_sessions"
                @async handle_scan_sessions(ws, cmd)
            elseif t == "clone_repo"
                @async handle_clone_repo(ws, cmd)
            elseif t == "ping"
                WebSockets.send(ws, JSON.json(Dict("type" => "pong")))
            else
                @warn "BonitoWorker: unknown control frame" type=t
            end
        end
        hb_alive[] = false
        @info "BonitoWorker: control WS closed by server"
    end
end

# Per-session WS handler
# Report an open_session early-failure back to the server over the control WS so
# it stops waiting for a dial that will never come (M13). Best-effort: a dead
# control WS is itself the larger failure and is handled by the reconnect loop.
function report_open_session_failed(ws, sid::AbstractString, reason::AbstractString)
    @error "BonitoWorker: open_session failed" sid reason
    try
        WebSockets.send(ws, JSON.json(Dict(
            "type"  => "open_session_failed",
            "sid"   => sid,
            "error" => reason,
        )))
    catch e
        @warn "BonitoWorker: could not report open_session failure" sid exception=e
    end
    return nothing
end

# Live agent sessions keyed by their cwd (= the server's `worker_path`, one per
# chat): `(proc, ws)` — the agent subprocess and its acp dial-back socket (`ws`
# is `nothing` until the dial completes). Lets a `close_session` control message
# — or a control-link loss (`reap_all_sessions!`) — reap the session EXPLICITLY
# when the dial-back ws is half-open and the relay never reaches its own kill:
# killing the proc unblocks a relay parked READING it, force-closing the ws
# transport unblocks relays parked on the SOCKET (a wedged send holds
# `ws.sendlock`, so only a transport kill gets through — see the server's
# `force_close_ws!` for the full story).
const _SESSION_PROCS = Dict{String,NamedTuple{(:proc, :ws),Tuple{Any,Any}}}()
const _SESSION_PROCS_LOCK = ReentrantLock()

# Reap EVERY live session: control-link loss means the server has already
# evicted this worker's chat models and abandoned their sessions — an agent we
# keep running serves nobody, and its lazy re-opened successor (same cwd, fresh
# proc) would coexist with it. Kill the procs and kill the session transports
# so relays wedged on half-open sockets (the WLAN→LAN incident) unwind too.
function reap_all_sessions!(reason::AbstractString)
    entries = lock(_SESSION_PROCS_LOCK) do
        snap = collect(_SESSION_PROCS)
        empty!(_SESSION_PROCS)
        snap
    end
    isempty(entries) && return nothing
    @info "BonitoWorker: reaping all agent sessions" n=length(entries) reason
    for (cwd, e) in entries
        kill_proc!(e.proc)
        e.ws === nothing || try e.ws.close_transport!() catch end
    end
    return nothing
end

function handle_open_session(ws, server_url::String, secret::String, agent_bin::String,
                              cmd::AbstractDict;
                              agent_env::Dict{String,String} = Dict{String,String}())
    sid           = String(get(cmd, "sid", ""))
    cwd           = String(get(cmd, "cwd", pwd()))
    # `cmd.env` is per-session overrides from the open_session command.
    # `agent_env` is worker-wide config (e.g. `dev_server(agent=...)`
    # threading dispatcher coords to every chat). Merge with per-session
    # winning over worker-wide, both winning over inherited.
    env_overrides = merge(Dict{String,String}(agent_env),
                          Dict{String,String}(get(cmd, "env", Dict{String,String}())))
    isempty(sid) && (@error "open_session missing sid"; return)

    # Resolve the requested provider from the single AgentProviders registry — the
    # SAME descriptors + list the server's dropdown is built from, so the two sides
    # can't disagree. The provider arrives as a name string (a Julia type can't
    # cross the JSON control-WS); its `bin`/`args`/`env` are resolved HERE,
    # worker-side, so `Sys.which` runs on the machine that owns the binary. An
    # unknown provider — or the mock when `BT_ENABLE_MOCK_AGENT` is unset — is
    # rejected, not silently swapped for a default binary.
    provider_str = String(get(cmd, "provider", "ClaudeCode"))
    provider = try
        AgentProviders.find_provider(provider_str)
    catch e
        return report_open_session_failed(ws, sid,
            "unknown provider '$provider_str': $(sprint(showerror, e))")
    end
    # Honor the worker's configured `agent_bin` for the default ClaudeCode provider
    # (the installer points it at the local claude-agent-acp); every other provider
    # uses the descriptor's worker-side resolved bin.
    resolved_agent_bin = (provider_str == "ClaudeCode" && !isempty(agent_bin)) ?
        agent_bin : provider.bin

    # Create the working dir if missing. A failure here (permissions, a file in
    # the way) is fatal for this session — narrow the catch to filesystem errors,
    # report it to the server, and bail instead of silently swallowing it and
    # spawning the agent in the wrong cwd (M13).
    if !isdir(cwd)
        try
            mkpath(cwd)
        catch e
            e isa Base.IOError || e isa SystemError || rethrow()
            return report_open_session_failed(ws, sid,
                "could not create cwd $cwd: $(sprint(showerror, e))")
        end
    end

    # `BONITOAGENTS_SERVER_URL` flows from here all the way down to BonitoMCP's
    # eval-ws dial-back: claude-agent-acp inherits this env, and MCP children
    # spawned by the agent inherit it too. The worker is the right side to set
    # it — `server_url` is the URL we ourselves dialed in on, so by construction
    # reachable. The server cannot reliably guess its own outward URL (see
    # `Bonito.online_url` behavior under `proxy_url="."`), so it stays out of
    # the URL-naming business.
    # Provider-specific env (e.g. Claude's CLAUDE_* vars) comes from the descriptor;
    # the worker layers live ENV under it and the server-url on top. Live ENV stays
    # the base so the agent inherits PATH etc.; `provider.env` and the per-session
    # overrides win.
    env = merge(Dict(string(k) => string(v) for (k, v) in ENV),
                provider.env,
                Dict("BONITOAGENTS_SERVER_URL"  => server_url),
                env_overrides)

    # `provider.args` carries any required subcommand (e.g. `["acp"]` for
    # mimo/opencode, whose ACP server lives under that subcommand).
    agent_args = provider.args
    proc = try
        open(Cmd(`$resolved_agent_bin $agent_args`; env, dir = cwd), "r+")
    catch e
        return report_open_session_failed(ws, sid,
            "failed to spawn agent ($resolved_agent_bin $(join(agent_args, ' '))): $(sprint(showerror, e))")
    end
    @info "BonitoWorker: ACP session started" sid cwd pid=getpid() provider=provider_str
    # Register the proc BEFORE the acp dial-back so a `close_session` (server's
    # reliable reap over the control ws) can always find it, even if the dial /
    # ack races with the server tearing the session down. The ws slot is filled
    # once the dial completes.
    lock(_SESSION_PROCS_LOCK) do; _SESSION_PROCS[cwd] = (proc = proc, ws = nothing) end

    acp_url = ws_url(server_url, "/worker-acp")
    # Outer try/finally guarantees the agent process is reaped on EVERY exit
    # path. The old code only killed/closed `proc` inside the relay's inner
    # finally, which is reached ONLY after the WS dialed AND the ack succeeded —
    # so a dial failure (server down) or a rejected ack orphaned the
    # claude-agent-acp process with open pipes, one per failed open (M8).
    try
        WebSockets.open(acp_url) do ws
            # Tell the server which session this WS belongs to.
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sid" => sid)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected ACP session: $(get(ack, "error", "unknown"))")
            # Fill the registry's ws slot (only if this session still owns the
            # entry) so a reap can kill the transport under a wedged relay.
            lock(_SESSION_PROCS_LOCK) do
                e = get(_SESSION_PROCS, cwd, nothing)
                e !== nothing && e.proc === proc &&
                    (_SESSION_PROCS[cwd] = (proc = proc, ws = ws))
            end

            ws_to_proc = @async relay_ws_to_proc(ws, proc)
            proc_to_ws = @async relay_proc_to_ws(proc, ws)
            try
                wait(ws_to_proc)
            finally
                # Kill proc FIRST so relay_proc_to_ws (blocked reading proc's
                # stdout) sees EOF and returns, then drain it.
                kill_proc!(proc)
                wait(proc_to_ws)
            end
        end
    catch e
        # A dial/ack failure here means the server never bound this WS to the
        # session, so it'd wait forever — tell it (M13). Mid-session transport
        # errors are reported too; harmless if the session already came up.
        report_open_session_failed(ws, sid, "ACP session error: $(sprint(showerror, e))")
    finally
        # Deregister (only if still us — a fast reopen on the same cwd may have
        # replaced the entry) so a late close_session can't kill a newer session.
        lock(_SESSION_PROCS_LOCK) do
            e = get(_SESSION_PROCS, cwd, nothing)
            e !== nothing && e.proc === proc && delete!(_SESSION_PROCS, cwd)
        end
        # Backstop reap: covers the paths the inner finally never reaches — dial
        # failure, rejected ack, or any throw before the relays start. Idempotent
        # with the inner kill (kill of an already-dead proc is a no-op).
        kill_proc!(proc)
    end
    @info "BonitoWorker: ACP session ended" sid cwd
end

# Explicit reap requested by the server (stop_session! on a closed/evicted chat).
# The normal teardown is the acp dial-back ws closing → the relay's finally kills
# the proc. But if a bind raced with the close, that ws can be half-open — the
# relay blocks in `receive` and never reaps. Killing the proc here closes its
# stdin (the agent exits on EOF) and unblocks the relay. Idempotent: a no-op if
# the session already tore down (entry gone) or the proc is already dead.
function handle_close_session(cmd)
    cwd = String(get(cmd, "cwd", ""))
    isempty(cwd) && return
    entry = lock(_SESSION_PROCS_LOCK) do; get(_SESSION_PROCS, cwd, nothing) end
    entry === nothing && return
    @info "BonitoWorker: close_session — reaping agent" cwd
    kill_proc!(entry.proc)
    # Also kill the dial-back transport: a relay parked on a half-open socket
    # (send holds ws.sendlock) is unreachable by the proc kill alone.
    entry.ws === nothing || try entry.ws.close_transport!() catch end
end

# Kill + close an agent process, tolerating an already-dead/closed one.
function kill_proc!(proc)
    # Gate on the OS PROCESS state, not `isopen(proc)` — `isopen` tracks the IO
    # streams, and a relay that already ran `close(proc.in)` flips it false while
    # the agent is still alive. The old `isopen(proc) && kill` then SKIPPED the
    # kill and orphaned the subprocess (the leak_cycle straggler). SIGTERM for a
    # clean exit, then SIGKILL as a guaranteed backstop: an agent reaped mid-start
    # (still precompiling, or with its stdio already shut so it never sees the
    # stdin-EOF) can outlive SIGTERM.
    try
        process_running(proc) && kill(proc)
    catch e
        e isa Base.IOError || @warn "BonitoWorker: SIGTERM failed" exception=e
    end
    try
        process_running(proc) && kill(proc, Base.SIGKILL)
    catch e
        e isa Base.IOError || @warn "BonitoWorker: SIGKILL failed" exception=e
    end
    try
        close(proc)
    catch e
        e isa Base.IOError || @warn "BonitoWorker: close proc failed" exception=e
    end
    return nothing
end

# Filesystem listing RPC
"""
Respond to `{type:"list_dir", request_id, path}` — used by the dashboard's
remote folder picker. Empty/missing path defaults to the worker's \$HOME.
Reply over the same control WS:

    {type: "list_dir_response", request_id, path, entries: [{name, dir}, …]}

Entries are sorted; dotfiles, .git/, .bonitoAgents/ skipped to keep noise down.
On error, returns `{type: "list_dir_response", request_id, error: "..."}`.
"""
function handle_list_dir(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))
    path       = isempty(raw_path) ? homedir() : raw_path

    response = try
        isdir(path) || error("not a directory: $path")
        entries = []
        for name in sort!(readdir(path))
            startswith(name, ".") && continue
            full = joinpath(path, name)
            # `isfile` follows symlinks and is false for a broken link, so
            # `filesize` is only called on a real regular file (no throw).
            isf = isfile(full)
            push!(entries, Dict("name" => name, "dir" => isdir(full),
                                "size" => isf ? filesize(full) : 0))
        end
        Dict("type"       => "list_dir_response",
             "request_id" => request_id,
             "path"       => abspath(path),
             "entries"    => entries)
    catch e
        Dict("type"       => "list_dir_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "list_dir response failed" exception=e
    end
end

# Single-file stat RPC — backs the editor open-guard. The server asks before
# fetching so a directory / missing path / oversized or binary file never starts
# a transfer that ends in an empty editor.
#
#     {type:"stat_path", request_id, path}
#  -> {type:"stat_path_response", request_id, path, exists, isfile, isdir, size}
#     {type:"stat_path_response", request_id, error:"..."}  on failure
function handle_stat_path(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))

    response = try
        isempty(raw_path) && error("path is empty")
        isf = isfile(raw_path)   # follows symlinks; false for dirs / broken links
        Dict("type"       => "stat_path_response",
             "request_id" => request_id,
             "path"       => abspath(raw_path),
             "exists"     => ispath(raw_path),
             "isfile"     => isf,
             "isdir"      => isdir(raw_path),
             "size"       => isf ? filesize(raw_path) : 0)
    catch e
        Dict("type"       => "stat_path_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "stat_path response failed" exception=e
    end
end

# Directories never worth indexing/recursing for the project file list — VCS
# metadata, dependency/build caches, and our own scratch dirs. Pruned in-place
# during the topdown walk (Julia's `walkdir` honours mutation of `dirs`).
const PROJECT_INDEX_IGNORE_DIRS = Set([
    ".git", "node_modules", ".julia", "__pycache__", ".venv", "venv",
    "target", "build", "dist", ".next", ".cache", ".bonitoAgents", ".stage",
    ".pytest_cache", ".mypy_cache", ".gradle", ".idea", ".vscode-test"])
# Hard cap so a pathological tree can't produce a multi-MB index frame.
const PROJECT_INDEX_MAX = 50_000

# Flat, searchable file index for one project root — backs the sidebar tree's
# search box (a VSCode-style fuzzy file list).
#
#     {type:"list_project_files", request_id, path}
#  -> {type:"list_project_files_response", request_id, path, files:[rel…], truncated}
#     {type:"list_project_files_response", request_id, error:"..."}  on failure
function handle_list_project_files(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))

    response = try
        isempty(raw_path) && error("path is empty")
        isdir(raw_path)   || error("not a directory: $raw_path")
        root      = String(raw_path)
        files     = String[]
        truncated = false
        for (dir, dirs, names) in walkdir(root; topdown = true, follow_symlinks = false)
            filter!(d -> !(d in PROJECT_INDEX_IGNORE_DIRS), dirs)
            for f in names
                push!(files, relpath(joinpath(dir, f), root))
                if length(files) >= PROJECT_INDEX_MAX
                    truncated = true
                    break
                end
            end
            truncated && break
        end
        sort!(files)
        Dict("type"       => "list_project_files_response",
             "request_id" => request_id,
             "path"       => abspath(root),
             "files"      => files,
             "truncated"  => truncated)
    catch e
        Dict("type"       => "list_project_files_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "list_project_files response failed" exception=e
    end
end

# Inspect a path for "which side is fresher" comparison on project-name
# collision. Cheap walk: file count + total bytes + latest mtime + top-N
# most-recently-modified files, plus per-subrepo git summary (HEAD, dirty
# count, last commit time). Excludes the contents of .git/ from the file
# walk so commit churn doesn't drown out source-edit recency; the git
# summary block reports commit activity separately so nothing is lost.
const INSPECT_RECENT_LIMIT = 10

function handle_inspect_path(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))

    response = try
        isempty(raw_path) && error("path is empty")
        isdir(raw_path)   || error("not a directory: $raw_path")
        Dict("type"       => "inspect_path_response",
             "request_id" => request_id,
             "path"       => abspath(raw_path),
             "summary"    => inspect_path_summary(raw_path))
    catch e
        Dict("type"       => "inspect_path_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "inspect_path response failed" exception=e
    end
end

# Is `path` still held open by some process? This is the reliable "background
# task still running" signal: a backgrounded shell keeps its `> output` redirect
# open until it exits, so a quiet-but-open file (e.g. mid `sleep 60`) reads as
# running, and the fd closing the instant the shell exits reads as done — no
# completion sentinel needed. Linux only (scans `/proc/*/fd`); returns `nothing`
# on other OSes so the server can fall back to mtime quiescence.
function file_held_open(path::AbstractString)::Union{Bool,Nothing}
    Sys.islinux() || return nothing
    return !isempty(file_writer_pids(path))
end

# Every OTHER process holding `path` open — for a background shell that's
# the shell itself (its `>> output` redirect stays open until exit). Used
# both for the "still running" signal above and for `kill_file_writers`:
# claude-agent-acp runs shells inside the SDK with no ACP-level kill, so
# the redirect fd is the one reliable handle for stopping one directly.
#
# Linux: scan `/proc/*/fd` (no external deps). macOS / other unix: fall back
# to `lsof`. Windows: empty (no portable fd→pid map; the caller still
# finalizes the UI, the process just isn't force-killed).
function file_writer_pids(path::AbstractString)::Vector{Int}
    me = getpid()
    if Sys.islinux()
        target = try realpath(path) catch; abspath(path) end
        pids = Int[]
        for pid in readdir("/proc")
            all(isdigit, pid) || continue
            p = parse(Int, pid)
            p == me && continue          # our own tail read must not count/die
            fddir = joinpath("/proc", pid, "fd")
            try
                for fd in readdir(fddir)
                    lnk = try realpath(joinpath(fddir, fd)) catch; "" end
                    if lnk == target
                        push!(pids, p)
                        break
                    end
                end
            catch
                # process vanished mid-scan or fd not readable — skip
            end
        end
        return pids
    elseif Sys.isunix()
        return lsof_pids(path, me)
    else
        return Int[]                     # Windows: no portable mechanism
    end
end

# `lsof -t -- <path>`: the pids with the file open, one per line. `-t`
# terse-mode prints bare pids. Missing lsof / no holders → empty.
function lsof_pids(path::AbstractString, me::Int)::Vector{Int}
    out = try
        read(pipeline(`lsof -t -- $path`; stderr = devnull), String)
    catch
        return Int[]                     # lsof absent or exit≠0 (no holders)
    end
    pids = Int[]
    for tok in split(out)
        p = tryparse(Int, tok)
        p === nothing || p == me || push!(pids, p)
    end
    return pids
end

# Direct children of `pid`, read from /proc/<pid>/task/*/children. Empty on
# non-Linux or when the file isn't present (older kernels without
# CONFIG_PROC_CHILDREN — rare; the writer-set still covers the common case).
function child_pids(pid::Int)::Vector{Int}
    Sys.islinux() || return Int[]
    kids = Int[]
    taskdir = "/proc/$pid/task"
    isdir(taskdir) || return kids
    for tid in readdir(taskdir)
        f = joinpath(taskdir, tid, "children")
        try
            for tok in split(read(f, String))
                isempty(tok) || push!(kids, parse(Int, tok))
            end
        catch
            # children file absent / process vanished — skip
        end
    end
    return kids
end

# `pid` plus its full descendant tree (BFS). The background bash that holds
# the `.output` fd typically spawns the real command as a CHILD (`bash -c
# 'sleep 600'`), and SIGTERM to the parent does NOT reach the child — so a
# writer-only kill could orphan the actual work. (In practice the child
# inherits the redirected stdout, so it ALSO holds the fd and the writer
# set already contains it — confirmed against the real agent — but we walk
# the tree anyway to cover a child that closed/reopened stdout.) On
# non-Linux `child_pids` is empty, so this is the identity; the lsof writer
# set is the coverage there.
function process_tree(roots::Vector{Int})::Vector{Int}
    seen = Set{Int}()
    queue = copy(roots)
    while !isempty(queue)
        p = popfirst!(queue)
        p in seen && continue
        push!(seen, p)
        append!(queue, child_pids(p))
    end
    return collect(seen)
end

# SIGTERM every holder of the file AND its descendant tree — the direct stop
# for a background shell. The SDK observes the exit as a normal one (its task
# notification fires; the server's poller sees the file released).
function handle_kill_file_writers(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))
    response = try
        writers = file_writer_pids(raw_path)
        me = getpid()
        # Whole tree, minus ourselves (defensive — the writer scan already
        # excludes us, but a descendant walk could in principle re-reach it).
        targets = filter(!=(me), process_tree(writers))
        for p in targets
            r = ccall(:kill, Cint, (Cint, Cint), Cint(p), Cint(15))   # SIGTERM
            r == 0 || @debug "kill_file_writers: SIGTERM failed" pid=p errno=Libc.errno()
        end
        Dict("type" => "kill_file_writers_response", "request_id" => request_id,
             "killed" => targets, "writers" => writers, "supported" => Sys.islinux())
    catch e
        Dict("type" => "kill_file_writers_response", "request_id" => request_id,
             "error" => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "kill_file_writers response failed" exception=e
    end
    return nothing
end

# Stream a file from byte `offset`, plus whether it's still being written
# (`open`). `open_known=false` ⇒ we couldn't tell (non-Linux) and the server
# should use mtime quiescence instead.
function handle_tail_file(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    raw_path   = String(get(cmd, "path", ""))
    offset     = Int(get(cmd, "offset", 0))
    max_bytes  = Int(get(cmd, "max_bytes", 65536))
    response = try
        if !isfile(raw_path)
            Dict("type" => "tail_file_response", "request_id" => request_id,
                 "exists" => false, "offset" => offset, "chunk" => "",
                 "open" => false, "open_known" => true)
        else
            sz    = filesize(raw_path)
            off   = clamp(offset, 0, sz)
            chunk = open(raw_path, "r") do io
                seek(io, off)
                String(read(io, min(max_bytes, sz - off)))
            end
            held = file_held_open(raw_path)
            Dict("type" => "tail_file_response", "request_id" => request_id,
                 "exists" => true, "offset" => off + sizeof(chunk), "chunk" => chunk,
                 "open" => held === true, "open_known" => held !== nothing,
                 "mtime" => mtime(raw_path))
        end
    catch e
        Dict("type" => "tail_file_response", "request_id" => request_id,
             "error" => sprint(showerror, e))
    end
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "tail_file response failed" exception=e
    end
end

function inspect_path_summary(root::AbstractString)
    total_files  = 0
    total_bytes  = 0
    latest_mtime = 0.0
    # Collect (rel, size, mtime) so we can sort for the recent-files list.
    files = NamedTuple{(:rel, :size, :mtime), Tuple{String, Int, Float64}}[]
    git_dirs = String[]   # abs paths of directories that contain a .git entry
    for (dir, dirs, names) in walkdir(String(root); topdown = true,
                                       follow_symlinks = false)
        if ".git" in dirs || ".git" in names
            push!(git_dirs, dir)
            # Don't recurse into .git/: counts huge object trees as "files
            # the user edited", which would mask actual source-edit recency.
            filter!(d -> d != ".git", dirs)
        end
        for n in names
            full = joinpath(dir, n)
            islink(full) && continue
            st = try stat(full) catch; continue end
            sz = Int(st.size)
            mt = Float64(st.mtime)
            total_files += 1
            total_bytes += sz
            mt > latest_mtime && (latest_mtime = mt)
            push!(files, (rel = relpath(full, String(root)),
                          size = sz, mtime = mt))
        end
    end
    sort!(files; by = f -> f.mtime, rev = true)
    n_recent = min(INSPECT_RECENT_LIMIT, length(files))
    recent = [Dict("path"  => f.rel,
                   "size"  => f.size,
                   "mtime" => f.mtime) for f in files[1:n_recent]]
    return Dict(
        "total_files"  => total_files,
        "total_bytes"  => total_bytes,
        "latest_mtime" => latest_mtime,
        "recent_files" => recent,
        "git_subrepos" => [inspect_git_subrepo(d, String(root)) for d in git_dirs],
    )
end

function inspect_git_subrepo(abs_dir::AbstractString, root::AbstractString)
    rel        = relpath(String(abs_dir), String(root))
    head_sha   = ""
    head_time  = 0.0
    dirty_count = 0
    branch     = ""
    try
        head_sha = strip(read(Cmd(`git rev-parse HEAD`; dir = abs_dir), String))
    catch end
    try
        # %ct is committer Unix time. Falls back to 0.0 if HEAD is unborn.
        out = read(Cmd(`git log -1 --format=%ct HEAD`; dir = abs_dir), String)
        head_time = parse(Float64, strip(out))
    catch end
    try
        # `--porcelain` is line-per-change; count non-empty lines.
        out = read(Cmd(`git status --porcelain`; dir = abs_dir), String)
        dirty_count = count(!isempty, split(out, '\n'))
    catch end
    try
        branch = strip(read(Cmd(`git rev-parse --abbrev-ref HEAD`; dir = abs_dir), String))
    catch end
    return Dict(
        "path"        => rel,
        "head_sha"    => head_sha,
        "head_time"   => head_time,
        "dirty_count" => dirty_count,
        "branch"      => branch,
    )
end

# Clone a GitHub repo into `dst_path` (must not exist yet). For PRs we then
# fetch the PR head ref and check it out as a local branch `pr-<n>`. The server
# pre-derives `dst_path` so we don't repeat the projects_root logic on the worker.
#
# Core clone flow, decoupled from the WS so it's unit-testable. `do_clone(url,
# dst_path, pr_number)` performs the actual `git clone` (+ PR checkout); tests
# inject a stub. Returns the response Dict.
#
# The cleanup invariant (M1): `created` flips true ONLY after the "already
# exists" guard passes and we're about to run the clone. The catch's `rm` is
# gated on it, so a name collision or a malformed pr_number can NEVER delete a
# pre-existing tree — the old code threw the "exists" error into the same catch
# that did `rm(dst_path)`, wiping the user's data.
function clone_repo_response(request_id::AbstractString, url::AbstractString,
                             dst_path::AbstractString, pr_raw, do_clone)
    created = false
    try
        # pr_number parsing lives INSIDE the try: a malformed value must return
        # an error response, not throw out of the bare @async with no reply ever
        # sent (the server would wait forever).
        pr_number = pr_raw === nothing ? nothing :
                    (pr_raw isa Integer ? Int(pr_raw) : parse(Int, String(pr_raw)))

        isempty(url)      && error("missing url")
        isempty(dst_path) && error("missing dst_path")
        ispath(dst_path)  && error("dst_path already exists: $dst_path")
        mkpath(dirname(dst_path))

        created = true                     # from here on, the clone owns dst_path
        do_clone(url, dst_path, pr_number)
        return Dict("type"       => "clone_repo_response",
                    "request_id" => request_id,
                    "dst_path"   => dst_path)
    catch e
        # Clean up ONLY a directory WE created (a partial clone), so a retry can
        # start fresh. Never touch a pre-existing tree — `created` stays false on
        # the "already exists" / bad-arg paths, so the user's data is safe.
        if created
            try
                isdir(dst_path) && rm(dst_path; recursive = true, force = true)
            catch rmerr
                @warn "clone_repo cleanup failed" dst_path exception=rmerr
            end
        end
        return Dict("type"       => "clone_repo_response",
                    "request_id" => request_id,
                    "error"      => sprint(showerror, e))
    end
end

# The real clone: shallow `git clone`, then for PRs fetch the head ref into a
# local `pr-<n>` branch and check it out.
function git_clone!(url::AbstractString, dst_path::AbstractString, pr_number)
    run(`git clone --depth 50 $url $dst_path`)
    if pr_number !== nothing
        ref          = "pull/$(pr_number)/head"
        local_branch = "pr-$(pr_number)"
        run(setenv(`git -C $dst_path fetch origin $ref:$local_branch`))
        run(setenv(`git -C $dst_path checkout $local_branch`))
    end
    return nothing
end

function handle_clone_repo(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    url        = String(get(cmd, "url", ""))
    dst_path   = String(get(cmd, "dst_path", ""))
    pr_raw     = get(cmd, "pr_number", nothing)

    response = clone_repo_response(request_id, url, dst_path, pr_raw, git_clone!)
    try
        WebSockets.send(ws, JSON.json(response))
    catch e
        @warn "clone_repo response failed" exception=e
    end
end


# RemoteSync (librsync) transfer over /transfer-ws.
#
# Server sends `{type:"open_transfer", sync_id, direction, src_path or dst_path}`.
# We dial /transfer-ws on the server, authenticate, and run the matching
# RemoteSync side. The transfer happens in the @async task spawned by the
# control loop, so the control WS read-loop continues servicing pings while
# librsync chews through bytes.
function handle_open_transfer(server_url::String, secret::String,
                                cmd::AbstractDict)
    sync_id   = String(get(cmd, "sync_id", ""))
    direction = String(get(cmd, "direction", ""))
    isempty(sync_id) && (@error "open_transfer missing sync_id"; return)

    transfer_url = ws_url(server_url, "/transfer-ws")
    try
        WebSockets.open(transfer_url) do ws
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sync_id" => sync_id)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected transfer: $(get(ack, "error", "unknown"))")

            wsio = RemoteSync.WebSocketIO(ws)
            if direction == "to_worker"
                # Server is sending; we're the receiver. Directory transfer.
                # `quick_check=false` (sent for user-confirmed directional
                # overwrites, e.g. cross-worker sync) forces delta transfer
                # even for files whose size+mtime match — rsync --checksum
                # semantics.
                dst = String(cmd["dst_path"])
                qc  = get(cmd, "quick_check", true) === true
                mkpath(dst)
                RemoteSync.receive_directory(dst, wsio; quick_check = qc)
                @info "BonitoWorker: transfer to_worker complete" dst
            elseif direction == "from_worker"
                # Worker is sending; server is the receiver. Directory transfer.
                src = String(cmd["src_path"])
                isdir(src) || error("src_path is not a directory: $src")
                RemoteSync.send_directory(src, wsio)
                @info "BonitoWorker: transfer from_worker complete" src
            elseif direction == "file_from_worker"
                # Single-file streaming. Worker reads the file and ships chunks
                # to the server. No size cap — receiver writes straight to disk.
                src = String(cmd["src_path"])
                isfile(src) || error("src_path is not a file: $src")
                RemoteSync.send_file(src, wsio)
                # Wait for the server (receiver) to drain + close first; closing
                # this WS before it has the tail truncates the last frame(s) and
                # EOFs its receive_file (the "file won't open" flakiness).
                RemoteSync.wait_peer_close(wsio)
                @info "BonitoWorker: file transfer complete" src
            elseif direction == "file_to_worker"
                # Server pushes a single file. We receive into `dst_path`,
                # creating parent dirs as needed. Used for things that
                # don't justify a full directory sync: pasted screenshots,
                # tool-call captures, ad-hoc Julia eval outputs the server
                # wants to land on the worker without re-walking the
                # whole project tree.
                dst = String(cmd["dst_path"])
                mkpath(dirname(dst))
                RemoteSync.receive_file(dst, wsio)
                @info "BonitoWorker: file received" dst
            else
                error("unknown transfer direction: $direction")
            end
        end
    catch e
        @error "BonitoWorker: transfer error" sync_id direction exception=e
    end
end

# Byte-shuttle between WS frame and subprocess stdio
function relay_ws_to_proc(ws, proc)
    try
        while !WebSockets.isclosed(ws)
            frame = WebSockets.receive(ws)
            line  = String(frame)
            endswith(line, '\n') || (line *= "\n")
            write(proc.in, line)
            flush(proc.in)
        end
    catch e
        e isa WebSockets.WebSocketError && return
        e isa Base.IOError              && return
        e isa EOFError                  && return
        @warn "BonitoWorker ws→proc relay error" exception=e
    finally
        try close(proc.in) catch e
            e isa Base.IOError || @warn "BonitoWorker: close proc.in failed" exception=e
        end
    end
end

function relay_proc_to_ws(proc, ws)
    try
        while isopen(proc)
            line = readline(proc.out; keep = true)
            isempty(line) && break
            WebSockets.send(ws, line)
        end
    catch e
        e isa EOFError                  && return
        e isa Base.IOError              && return
        WebSockets.isclosed(ws)         && return
        @warn "BonitoWorker proc→ws relay error" exception=e
    finally
        # The agent produced no more output — it EXITED (e.g. crashed mid-turn, or
        # was reaped on a normal close). Close the dial-back WS so the SERVER's ACP
        # reader sees EOF and flips the session dead (header restart button),
        # instead of hanging forever on a `session/prompt` response that will never
        # arrive. Best-effort + idempotent: on a normal close the ws is already
        # going down; the handler still reaps `proc` either way.
        try
            WebSockets.isclosed(ws) || close(ws)
        catch
        end
    end
end

# Helpers
function ws_url(http_url::AbstractString, path::AbstractString)
    if startswith(http_url, "http://")
        return "ws://" * replace(http_url, "http://" => ""; count = 1) * path
    elseif startswith(http_url, "https://")
        return "wss://" * replace(http_url, "https://" => ""; count = 1) * path
    else
        return http_url * path
    end
end

# ── Claude session scanner ─────────────────────────────────────────────────────
#
# Discovers Claude Code projects from the on-disk session history under
# `~/.claude/projects/<encoded>/`. We don't try to enumerate live claude
# processes (Linux /proc only; macOS/Windows need OS-specific libproc / PEB
# work); the history walk surfaces both completed and currently-running
# sessions, since active sessions write to a jsonl in the same directory.
#
# The encoded folder name is NOT used to recover the project path — Claude
# Code maps `/`, `.`, AND `_` all to `-`, so the inverse is ambiguous and
# silently fails for any project name containing `.` or `_` (i.e. every
# Julia `Foo.jl` package, every snake_case directory). Instead we read the
# `cwd` field from inside each jsonl. We re-read per jsonl (not once per
# encoded folder) so that subagent rows reflect the cwd recorded in THAT
# subagent's file — if it ran in a nested directory, we honor it.

const CWD_LINE_LIMIT    = 100  # cwd typically lands on line 1-3, but generous
const PREVIEW_MAX_CHARS = 120  # truncated length for the dashboard preview line

"""
    scan_claude_sessions(; home) → Vector{Dict{String,Any}}

Enumerate Claude Code sessions under `~/.claude/projects/`. One entry per
discovered `.jsonl` (top-level session jsonl AND each subagent jsonl), sorted
by `last_used` descending. Each entry has:

- `path`              — absolute project directory (read from a `cwd` field
                        in the jsonl content, not derived from the folder name)
- `name`              — `basename(path)`
- `session_id`        — basename of the jsonl minus `.jsonl`. For top-level
                        sessions this is the UUID Claude Code uses for
                        `session/load`; for subagents it is the agent id
                        (e.g. `agent-a56e94ef589608347`).
- `last_used`         — Unix timestamp (jsonl mtime)
- `kind`              — `"session"` or `"subagent"`
- `agent_type`        — `nothing` for sessions; for subagents, the `agentType`
                        from the sibling `<id>.meta.json` (e.g. `"Explore"`).
- `parent_session_id` — `nothing` for sessions; for subagents, the UUID
                        directory name immediately above `subagents/`.
- `running`           — `true`  iff `~/.claude/sessions/<pid>.json` exists for
                        this `session_id` AND the OS confirms that PID is
                        still alive; `false` if no sessions file exists or the
                        OS says the PID is gone; `nothing` if the OS-level
                        liveness check is unavailable (e.g. Windows path
                        couldn't open the process handle for unknown reasons).
                        Subagents share their parent's process, so they're
                        never tracked in `~/.claude/sessions/` and always get
                        `running = false`.
- `pid`               — set only when `running === true`; the OS PID of the
                        live Claude CLI process. `nothing` otherwise.
- `first_prompt`      — short preview of the first user-message text in the
                        jsonl (whitespace-collapsed, truncated to
                        PREVIEW_MAX_CHARS). `nothing` if the jsonl contains no
                        real user message in its first `CWD_LINE_LIMIT` lines.

Folders whose jsonls yield no `cwd` field (malformed / empty) are skipped.
"""
function scan_claude_sessions(; home::String = homedir())
    results = Dict{String,Any}[]
    projects_dir = joinpath(home, ".claude", "projects")
    isdir(projects_dir) || return results
    pid_map = load_sessions_pid_map(; home = home)
    for encoded in readdir(projects_dir)
        proj_dir = joinpath(projects_dir, encoded)
        isdir(proj_dir) || continue
        for jsonl in find_jsonls(proj_dir)
            entry = entry_from_jsonl(jsonl, pid_map)
            entry === nothing && continue
            push!(results, entry)
        end
    end
    sort!(results; by = r -> -Float64(get(r, "last_used", 0.0)))
    return results
end

# Recursively collect `*.jsonl` files under `proj_dir`. Skips `memory/`
# (Claude's user-memory store, never contains jsonls) and follows no symlinks
# to avoid loops. Returns the list sorted by mtime descending so the freshest
# file is tried first when extracting cwd — its format is most likely current.
function find_jsonls(proj_dir::AbstractString)
    out = String[]
    for (root, dirs, files) in walkdir(String(proj_dir); follow_symlinks=false)
        # Don't descend into `<proj_dir>/memory/`.
        if "memory" in dirs && root == String(proj_dir)
            filter!(d -> d != "memory", dirs)
        end
        for f in files
            endswith(f, ".jsonl") && push!(out, joinpath(root, f))
        end
    end
    sort!(out; by = f -> -stat(f).mtime)
    return out
end

# Scan up to CWD_LINE_LIMIT lines from `jsonl`, JSON-parsing each, and extract
# both the project `cwd` (first record with a non-empty `"cwd"`) and a `preview`
# (first user-message text). Returned as `(cwd, preview)`; either can be
# `nothing` if not found. One pass; corrupt lines are skipped silently.
#
# A "user message" record is `{"type":"user","message":{"role":"user",
# "content": str | [block, ...]}}`. For list content we take the first
# `"type":"text"` block (skipping tool-result blocks etc.).
function scan_jsonl_metadata(jsonl::AbstractString)
    cwd     = nothing
    preview = nothing
    try
        open(jsonl, "r") do io
            n = 0
            while !eof(io) && n < CWD_LINE_LIMIT && (cwd === nothing || preview === nothing)
                line = readline(io)
                n += 1
                isempty(line) && continue
                rec = try
                    JSON.parse(line)
                catch
                    continue
                end
                if cwd === nothing
                    v = get(rec, "cwd", nothing)
                    v isa AbstractString && !isempty(v) && (cwd = String(v))
                end
                if preview === nothing
                    t = first_user_text(rec)
                    t !== nothing && (preview = t)
                end
            end
        end
    catch e
        @debug "scan_jsonl_metadata: read failed" jsonl exception=e
    end
    return (cwd, preview)
end

# Pseudo-XML wrappers Claude Code injects into "user" messages: IDE context,
# system reminders, slash-command invocations, local bash command caveats and
# output, and an ever-growing list of others. The FIRST user records in a
# session are usually wholly these, so the literal first user text gives a
# useless preview like "<ide_opened_file>The user opened the file …".
#
# Rather than enumerate the tag names (the list keeps growing — every new
# Claude Code release adds wrappers like `<local-command-caveat>`), we strip
# ANY leading `<tag>…</tag>` block whose closer matches the opener, and skip
# messages whose remainder still starts with a bare opener — those are
# system-commentary records (e.g. `<ide_opened_file>The user opened …` with
# no closing tag) and contain no user prose.
const LEADING_TAG_BLOCK  = r"\A\s*<\s*([A-Za-z][\w-]*)\s*>.*?<\s*/\s*\1\s*>"is
const LEADING_TAG_OPENER = r"\A\s*<\s*[A-Za-z][\w-]*\s*>"

function strip_injected_context(raw::AbstractString)
    s = String(raw)
    # Strip closed leading blocks one at a time. Slash-command lines emit
    # several adjacent blocks (`<command-name>…</command-name>\n<command-args>…`),
    # so we loop until no leading block remains.
    while occursin(LEADING_TAG_BLOCK, s)
        s = replace(s, LEADING_TAG_BLOCK => ""; count = 1)
    end
    return strip(s)
end

# The real user prose from a message, or `nothing` if the message is purely
# injected context / tooling noise (so the scan keeps looking for a real one).
function meaningful_prompt(raw::AbstractString)
    s = strip_injected_context(raw)
    isempty(s) && return nothing
    # A leftover bare opener (e.g. `<ide_opened_file>The user opened …` with
    # no `</ide_opened_file>`) is system commentary, not user text — skip it
    # so the scan picks up the next real user message.
    occursin(LEADING_TAG_OPENER, s) && return nothing
    startswith(s, "Caveat: The messages below were generated by the user") && return nothing
    return s
end

# Return the real user prose from one jsonl record, or `nothing` if this record
# isn't a real user prompt (wrong role, or wholly injected context — see
# `meaningful_prompt`). Handles both string content and array content (first
# text block; ignores tool_result blocks).
function first_user_text(rec)
    rec isa AbstractDict || return nothing
    String(get(rec, "type", "")) == "user" || return nothing
    msg = get(rec, "message", nothing)
    msg isa AbstractDict || return nothing
    String(get(msg, "role", "")) == "user" || return nothing
    c = get(msg, "content", nothing)
    text = nothing
    if c isa AbstractString
        text = c
    elseif c isa AbstractVector
        for blk in c
            blk isa AbstractDict || continue
            String(get(blk, "type", "")) == "text" || continue
            t = get(blk, "text", "")
            if t isa AbstractString && !isempty(t)
                text = t
                break
            end
        end
    end
    text === nothing && return nothing
    p = meaningful_prompt(text)
    p === nothing && return nothing
    return clean_preview(p)
end

# Strip whitespace, collapse internal whitespace runs to a single space, then
# truncate to PREVIEW_MAX_CHARS with an ellipsis. Returns `nothing` if empty.
function clean_preview(s::AbstractString)
    s = strip(replace(String(s), r"\s+" => " "))
    isempty(s) && return nothing
    length(s) > PREVIEW_MAX_CHARS && (s = first(s, PREVIEW_MAX_CHARS - 1) * "…")
    return String(s)
end

# Build a result Dict for one jsonl. Reads `cwd` from the jsonl itself
# (returns `nothing` if no cwd is recoverable in the first CWD_LINE_LIMIT
# lines). Subagent metadata is read from `<jsonl-stem>.meta.json` next to
# the jsonl; missing or unreadable meta → `agent_type = nothing`. `pid_map`
# (sessionId → OS pid, from `load_sessions_pid_map`) is used to compute the
# `running` / `pid` fields.
function entry_from_jsonl(jsonl::AbstractString, pid_map::Dict{String,Int})
    cwd, preview = scan_jsonl_metadata(jsonl)
    cwd === nothing && return nothing
    # Drop sessions whose project folder no longer exists. Claude keeps the
    # session jsonl under ~/.claude/projects forever, so deleted folders
    # (throwaway temp dirs especially) would otherwise linger in the list with
    # nothing to resume into.
    isdir(String(cwd)) || return nothing
    sid = first(splitext(basename(jsonl)))
    is_subagent = occursin("/subagents/", replace(jsonl, '\\' => '/'))
    agent_type        = nothing
    parent_session_id = nothing
    if is_subagent
        # Layout: <proj>/<parent-sid>/subagents/<agent-id>.jsonl
        subagents_dir = dirname(jsonl)
        parent_dir    = dirname(subagents_dir)
        parent_session_id = basename(parent_dir)
        meta_path = joinpath(subagents_dir, sid * ".meta.json")
        if isfile(meta_path)
            try
                meta = JSON.parse(read(meta_path, String))
                at = get(meta, "agentType", nothing)
                at isa AbstractString && (agent_type = String(at))
            catch e
                @debug "entry_from_jsonl: meta read failed" meta_path exception=e
            end
        end
    end
    # Liveness: only top-level sessions can match a sessions-file entry —
    # subagents share their parent's process and never appear in the map.
    running = nothing
    pid     = nothing
    if !is_subagent && haskey(pid_map, sid)
        pid_candidate = pid_map[sid]
        live = pid_running(pid_candidate)
        if live === true
            running, pid = true, pid_candidate
        elseif live === false
            running = false
        else
            # OS check unavailable (Windows fallback). Conservative: leave
            # running as `nothing` so the UI shows no badge.
        end
    else
        # No sessions-file entry → definitively not running. (Same for
        # subagents.)
        running = false
    end
    return Dict{String,Any}(
        "path"              => String(cwd),
        "name"              => basename(String(cwd)),
        "session_id"        => sid,
        "last_used"         => Float64(stat(jsonl).mtime),
        "kind"              => is_subagent ? "subagent" : "session",
        "agent_type"        => agent_type,
        "parent_session_id" => parent_session_id,
        "running"           => running,
        "pid"               => pid,
        "first_prompt"      => preview,
    )
end

# ── Liveness helpers ──────────────────────────────────────────────────────────
# `~/.claude/sessions/<pid>.json` is Claude Code's own liveness registry:
# filename = OS PID, body has `{pid, sessionId, cwd, ...}`. We pair "file
# exists" with an OS-level "PID still alive" check; only the conjunction is
# trustworthy (files can linger past process death; PIDs can be reused).

# Walk `~/.claude/sessions/*.json` once per scan, returning sessionId → pid.
# Cost is O(K) where K is the number of tracked sessions (typically < 20).
function load_sessions_pid_map(; home::String = homedir())
    out = Dict{String,Int}()
    sdir = joinpath(home, ".claude", "sessions")
    isdir(sdir) || return out
    for f in readdir(sdir; join = true)
        endswith(f, ".json") || continue
        try
            d = JSON.parse(read(f, String))
            sid = String(get(d, "sessionId", ""))
            pid = get(d, "pid", nothing)
            (isempty(sid) || pid === nothing) && continue
            out[sid] = Int(pid)
        catch e
            @debug "load_sessions_pid_map: skip" file=f exception=e
        end
    end
    return out
end

# Check whether the given PID is currently alive. Returns:
#   `true`    — confirmed alive,
#   `false`   — confirmed dead,
#   `nothing` — the OS-level check couldn't determine (always show no badge).
@static if Sys.iswindows()
    const _PROCESS_QUERY_LIMITED_INFORMATION = UInt32(0x1000)
    function pid_running(pid::Integer)
        try
            h = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid},
                      (UInt32, Cint, UInt32),
                      _PROCESS_QUERY_LIMITED_INFORMATION, Cint(0), UInt32(pid))
            if h != C_NULL
                ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), h)
                return true
            end
            # NULL could mean "no such process" or "access denied" — we don't
            # bother calling GetLastError(); be conservative and report
            # "unknown" so the UI shows no badge.
            return nothing
        catch
            return nothing
        end
    end
else
    function pid_running(pid::Integer)
        try
            r = ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(0))
            r == 0 && return true
            err = Libc.errno()
            err == Libc.ESRCH && return false   # No such process
            err == Libc.EPERM && return true    # Process exists, no signal perm
            return false
        catch
            return nothing
        end
    end
end

function handle_scan_sessions(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    sessions = try
        scan_claude_sessions()
    catch e
        @warn "BonitoWorker: scan_claude_sessions failed" exception=e
        Dict{String,Any}[]
    end
    try
        WebSockets.send(ws, JSON.json(Dict(
            "type"       => "scan_sessions_result",
            "request_id" => request_id,
            "sessions"   => sessions,
        )))
    catch e
        @warn "BonitoWorker: scan_sessions response failed" exception=e
    end
end

# Locate an executable on PATH. On Windows, `Sys.which` finds `.exe` but does
# NOT walk PATHEXT for `.cmd`/`.bat` — and npm installs `claude-agent-acp` as
# a `.cmd` shim — so we try those variants explicitly. Unix has no equivalent
# concept, so `Sys.which` is sufficient.
@static if Sys.iswindows()
    which_executable(name) = something(Sys.which(name),
                                       Sys.which(name * ".cmd"),
                                       Sys.which(name * ".bat"),
                                       Some(nothing))
else
    which_executable(name) = Sys.which(name)
end

function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit
    bin = which_executable("claude-agent-acp")
    bin !== nothing && return bin
    return "claude-agent-acp"
end

end # module BonitoWorker
