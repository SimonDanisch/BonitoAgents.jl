module BonitoWorker

# Outbound-only worker: dials the BonitoTeam server, holds a "control" WS open,
# spawns claude-agent-acp + a dedicated per-session WS each time the server
# requests a new session.
#
# Worker has NO inbound listener — no firewall hole on the worker side.
# Single port to open is on the server (8038), already needed for browsers.

using HTTP, HTTP.WebSockets, JSON, RemoteSync
using Scratch: @get_scratch!

# Per-install config directory, managed by Scratch.jl. Resolves to
# `~/.julia/scratchspaces/<BonitoWorker-uuid>/config/` on every OS, so we get
# a writable, cross-platform location without poking at `XDG_DATA_HOME` /
# `HOME` / `%APPDATA%` ourselves. Holds the stable `worker_id`, the install
# `config.json`, and the detached worker's `worker.log`.
config_dir() = @get_scratch!("config")

# Stable per-install identity for this worker. Generated once and persisted so
# the server can recognise the same physical install across hostname/IP
# changes (DHCP renew, VPN flip, laptop carried between Wi-Fi networks). The
# display name is just a label — this id is the dict key on the server.
worker_id_path() = joinpath(config_dir(), "worker_id")

# Install config written by `install!` and read back by `start`.
config_path() = joinpath(config_dir(), "config.json")

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
# whatever env this worker itself runs in (the shared `@bonito-team` after a
# normal install, or the monorepo project in dev) — BonitoMCP is co-installed
# there, so the MCP process resolves it without any extra setup.
julia_bin() = joinpath(Sys.BINDIR::String, Base.julia_exename())

function mcp_args()
    project = something(Base.active_project(), "@bonito-team")
    return String[
        "--project=$(project)",
        "--startup-file=no",
        "--threads=auto",
        "-e", "using BonitoMCP; BonitoMCP.run_stdio()",
    ]
end

# ── Install / start ────────────────────────────────────────────────────────────
"""
    BonitoWorker.install!(; server_url, secret, projects_root = pwd())

Persist the worker config into the Scratch config space and launch the worker
process detached. Called at the end of `install.jl`; also the entry point for
re-pointing an existing install at a different server (just re-run it).
"""
function install!(; server_url::String,
                    secret::String,
                    projects_root::String = pwd())
    worker_id = load_or_generate_worker_id()
    config = Dict(
        "server_url"    => server_url,
        "secret"        => secret,
        "name"          => default_worker_name(worker_id),
        "projects_root" => abspath(projects_root),
    )
    cfg = config_path()
    write(cfg, JSON.json(config))
    @info "BonitoWorker: wrote config" path=cfg server_url projects_root=config["projects_root"]
    proc, logfile = spawn_worker()
    println()
    println("==> BonitoTeam worker started (pid $(getpid(proc)))")
    println("    config : ", cfg)
    println("    log    : ", logfile)
    println("    server : ", server_url)
    println()
    println("    The worker runs detached and survives this shell. To start it")
    println("    again later (e.g. after a reboot), run:")
    println()
    println("      julia --project=@bonito-team -e \"using BonitoWorker; BonitoWorker.start()\"")
    println()
    return proc
end

# Launch `BonitoWorker.start()` as a detached background process so it outlives
# the installer (the `curl … | julia -` pipe exits as soon as install.jl
# returns). `detach` makes the child independent of the parent process group on
# every OS; stdout+stderr append to `worker.log` in the config dir.
function spawn_worker()
    logfile = joinpath(config_dir(), "worker.log")
    project = something(Base.active_project(), "@bonito-team")
    cmd = `$(julia_bin()) --project=$(project) --startup-file=no -e $("using BonitoWorker; BonitoWorker.start()")`
    proc = run(pipeline(detach(cmd); stdout = logfile, stderr = logfile, append = true);
               wait = false)
    return proc, logfile
end

"""
    BonitoWorker.start()

Read the install config written by `install!` and connect to the server.
Blocks forever (reconnecting on drop). This is the worker process entry point.
"""
function start()
    cfg = config_path()
    isfile(cfg) || error("BonitoWorker: no config at $cfg — run the installer first " *
                          "(`curl -fsSL <server-url>/install.jl | julia -`)")
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
                            projects_root::String = joinpath(homedir(), "bonitoteam-projects"),
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
        @info "BonitoWorker: reconnecting in $(retry_delay)s"
        sleep(retry_delay)
    end
end

# Control WS lifecycle
function run_control_session(; server_url, secret, worker_id, name, mcp_command,
                               mcp_arguments, projects_root, agent_bin)
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

        for frame in ws
            cmd = JSON.parse(String(frame))
            t = get(cmd, "type", "")
            if t == "open_session"
                @async handle_open_session(ws, server_url, secret, agent_bin, cmd)
            elseif t == "open_transfer"
                @async handle_open_transfer(server_url, secret, cmd)
            elseif t == "list_dir"
                @async handle_list_dir(ws, cmd)
            elseif t == "inspect_path"
                @async handle_inspect_path(ws, cmd)
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
        @info "BonitoWorker: control WS closed by server"
    end
end

# Per-session WS handler. `agent_bin` is the default agent binary discovered at
# worker startup; it's only used when the server's open_session frame doesn't
# pin a specific agent_type (legacy frames from old server builds).
#
# `control_ws` is the worker's persistent control WebSocket — passed in so we
# can send an `open_session_failed` notification frame back to the server if
# the agent binary is missing (server-side `take_pending!` unblocks immediately
# instead of waiting 30s for a dial-back that'll never come).
function handle_open_session(control_ws, server_url::String, secret::String,
                              agent_bin::String, cmd::AbstractDict)
    sid           = String(get(cmd, "sid", ""))
    cwd           = String(get(cmd, "cwd", pwd()))
    env_overrides = Dict{String,String}(get(cmd, "env", Dict{String,String}()))
    agent_type    = String(get(cmd, "agent_type", "claude"))
    isempty(sid) && (@error "open_session missing sid"; return)

    isdir(cwd) || try mkpath(cwd) catch end

    spec = agent_spec(agent_type)
    bin  = haskey(cmd, "agent_type") ? find_agent_bin(agent_type) : agent_bin

    # Fast-fail check: if the resolved binary is neither an absolute file nor
    # something `which` could find, the spawn will fail. Tell the server now
    # so the UI's busy banner clears in milliseconds, not 30 seconds.
    if !isfile(bin) && which_executable(bin) === nothing
        reason = "agent '$(agent_type)' not available on this worker: " *
                 "'$(bin)' is not on PATH. " *
                 "Install $(spec.display_name) CLI on the worker " *
                 "(`$(spec.binary)` binary required)."
        @error "BonitoWorker: $(reason)" sid agent=agent_type
        try
            WebSockets.send(control_ws, JSON.json(Dict(
                "type"   => "open_session_failed",
                "sid"    => sid,
                "reason" => reason,
            )))
        catch e
            @warn "BonitoWorker: failed to send open_session_failed" exception=e
        end
        return
    end

    env = merge(Dict(string(k) => string(v) for (k, v) in ENV),
                spec.env,
                env_overrides)

    proc = try
        open(Cmd(`$bin $(spec.args)`; env, dir = cwd), "r+")
    catch e
        @error "BonitoWorker: failed to spawn agent" exception=e cwd agent=agent_type bin
        try
            WebSockets.send(control_ws, JSON.json(Dict(
                "type"   => "open_session_failed",
                "sid"    => sid,
                "reason" => "spawn of '$(bin)' failed: $(sprint(showerror, e))",
            )))
        catch e2
            @warn "BonitoWorker: failed to send open_session_failed" exception=e2
        end
        return
    end
    @info "BonitoWorker: ACP session started" sid cwd agent=agent_type pid=getpid()

    acp_url = ws_url(server_url, "/worker-acp")
    try
        WebSockets.open(acp_url) do ws
            # Tell the server which session this WS belongs to.
            WebSockets.send(ws, JSON.json(Dict("secret" => secret, "sid" => sid)))
            ack = JSON.parse(String(WebSockets.receive(ws)))
            get(ack, "ok", false) ||
                error("server rejected ACP session: $(get(ack, "error", "unknown"))")

            ws_to_proc = @async relay_ws_to_proc(ws, proc)
            proc_to_ws = @async relay_proc_to_ws(proc, ws)
            try
                wait(ws_to_proc)
            finally
                try
                    isopen(proc) && kill(proc)
                catch e
                    @warn "BonitoWorker: kill failed" exception=e
                end
                wait(proc_to_ws)
                try
                    close(proc)
                catch e
                    e isa Base.IOError || @warn "BonitoWorker: close proc failed" exception=e
                end
            end
        end
    catch e
        @error "BonitoWorker: ACP session error" sid exception=e
    end
    @info "BonitoWorker: ACP session ended" sid cwd
end

# Filesystem listing RPC
"""
Respond to `{type:"list_dir", request_id, path}` — used by the dashboard's
remote folder picker. Empty/missing path defaults to the worker's \$HOME.
Reply over the same control WS:

    {type: "list_dir_response", request_id, path, entries: [{name, dir}, …]}

Entries are sorted; dotfiles, .git/, .bonitoTeam/ skipped to keep noise down.
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
            push!(entries, Dict("name" => name, "dir" => isdir(full)))
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
# fetch the PR head ref and check it out as a local branch `pr-<n>` so the
# checkout uses a normal branch name. The server pre-derives `dst_path` so
# we don't have to repeat the projects_root logic on the worker.
function handle_clone_repo(ws, cmd::AbstractDict)
    request_id = String(get(cmd, "request_id", ""))
    url        = String(get(cmd, "url", ""))
    dst_path   = String(get(cmd, "dst_path", ""))
    pr_raw     = get(cmd, "pr_number", nothing)
    pr_number  = pr_raw === nothing ? nothing :
                 (pr_raw isa Integer ? Int(pr_raw) : parse(Int, String(pr_raw)))

    response = try
        isempty(url)      && error("missing url")
        isempty(dst_path) && error("missing dst_path")
        ispath(dst_path)  && error("dst_path already exists: $dst_path")
        mkpath(dirname(dst_path))

        run(`git clone --depth 50 $url $dst_path`)
        if pr_number !== nothing
            ref   = "pull/$(pr_number)/head"
            local_branch = "pr-$(pr_number)"
            run(setenv(`git -C $dst_path fetch origin $ref:$local_branch`))
            run(setenv(`git -C $dst_path checkout $local_branch`))
        end
        Dict("type"       => "clone_repo_response",
             "request_id" => request_id,
             "dst_path"   => dst_path)
    catch e
        # If clone partially populated the dir, clean up so a retry can start
        # fresh — leaving a half-cloned tree blocks the "already exists" check.
        try
            isdir(dst_path) && rm(dst_path; recursive = true, force = true)
        catch
        end
        Dict("type"       => "clone_repo_response",
             "request_id" => request_id,
             "error"      => sprint(showerror, e))
    end
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
                dst = String(cmd["dst_path"])
                mkpath(dst)
                RemoteSync.receive_directory(dst, wsio)
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

# Return the user-message text from one jsonl record, or `nothing` if this
# record isn't a real user prompt. Handles both string content and array
# content (picking the first text block; ignoring tool_result blocks).
function first_user_text(rec)
    rec isa AbstractDict || return nothing
    String(get(rec, "type", "")) == "user" || return nothing
    msg = get(rec, "message", nothing)
    msg isa AbstractDict || return nothing
    String(get(msg, "role", "")) == "user" || return nothing
    c = get(msg, "content", nothing)
    if c isa AbstractString
        return clean_preview(c)
    elseif c isa AbstractVector
        for blk in c
            blk isa AbstractDict || continue
            String(get(blk, "type", "")) == "text" || continue
            t = get(blk, "text", "")
            t isa AbstractString && !isempty(t) && return clean_preview(t)
        end
    end
    return nothing
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
        live = process_running(pid_candidate)
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
    function process_running(pid::Integer)
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
    function process_running(pid::Integer)
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

# ── Agent registry ────────────────────────────────────────────────────────────
# One spec per supported ACP agent. The server's `open_session` control frame
# carries an `agent_type` string; the worker looks the spec up here and spawns
# `binary args...` with `env` merged into the inherited environment.
#
# NOTE: a near-identical registry exists in `AgentClientProtocol.find_agent_bin`
# (used by `LocalTransport` in the dev rig / tests). Keep both in sync until we
# move the registry into a shared location.
struct AgentSpec
    agent_type   :: String
    display_name :: String
    binary       :: String              # PATH name (or absolute) to look up
    args         :: Vector{String}      # CLI args, e.g. ["--acp", "--approval-mode=yolo"]
    env          :: Dict{String,String} # extra env vars at spawn time
    env_override :: String              # name of env var that overrides `binary` (e.g. CLAUDE_AGENT_ACP)
end

const AGENT_REGISTRY = Dict{String,AgentSpec}(
    "claude" => AgentSpec(
        "claude", "Claude",
        "claude-agent-acp", String[],
        Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
             "CLAUDE_MAX_TURNS"       => "100"),
        "CLAUDE_AGENT_ACP"),
    "gemini" => AgentSpec(
        "gemini", "Gemini",
        # `gemini --acp` starts Gemini CLI in stdio ACP mode (see
        # google-gemini/gemini-cli `packages/cli/src/config/config.ts`). The
        # `--approval-mode=yolo` flag mirrors Claude's bypassPermissions UX.
        "gemini", ["--acp", "--approval-mode=yolo"],
        Dict{String,String}(),
        "GEMINI_BIN"),
)

agent_spec(t::AbstractString) =
    get(AGENT_REGISTRY, String(t), AGENT_REGISTRY["claude"])

function find_agent_bin(agent_type::AbstractString = "claude")
    spec = agent_spec(agent_type)
    explicit = get(ENV, spec.env_override, "")
    !isempty(explicit) && return explicit
    bin = which_executable(spec.binary)
    bin !== nothing && return bin
    return spec.binary    # let the OS raise a clear error at spawn time
end

end # module BonitoWorker
