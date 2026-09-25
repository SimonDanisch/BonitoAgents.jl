# ── The worker ──────────────────────────────────────────────────────────────
# One running worker: what it was started with, its link to the server, and
# everything it runs for the server's chats.
#
# The link is the worker's ONE connection (`/w`). Its control channel carries
# the server's commands and our replies; the server opens one more channel per
# agent session and per file transfer, with the request as the channel's header
# (`serve_channel`). A dropped connection only DETACHES the link: the agents keep
# running, and the next connection resumes it where it stopped. When the server
# no longer knows the link (it restarted, or we were away longer than its grace
# period) the link resets, every channel on it aborts, and everything from
# before is reaped.

"""
    WorkerConfig

What a worker is started with; fixed for its lifetime.
"""
Base.@kwdef struct WorkerConfig
    server_url::String
    secret::String
    worker_id::String
    name::String
    mcp_command::String
    mcp_arguments::Vector{String}
    projects_root::String
    agent_bin::String
    # Environment for every agent, over the inherited one.
    agent_env::Dict{String,String} = Dict{String,String}()
    # `nothing`: this worker does not update itself (dev and standalone workers).
    # An installed update writes its spec back into it.
    update_config::Union{Dict{String,Any},Nothing} = nothing
end

# An agent running for one of the server's chats.
struct AgentSession
    proc::Base.Process
    project_id::String
    cwd::String
end

# Self-update bookkeeping, see `schedule_auto_update!`.
mutable struct UpdateState
    task::Union{Task,Nothing}
    pending::Bool   # an install runs or is about to: new sessions are refused
    gen::Int        # bumped when an immediate request supersedes a waiting one
end

"""
    Worker(config)

A worker. `serve(worker)` connects it and keeps it connected; `close(worker)`
stops it and everything it runs.
"""
mutable struct Worker
    const config::WorkerConfig
    const lock::ReentrantLock
    const update::UpdateState
    const sessions::Dict{WorkerLink.LinkChannel,AgentSession}   # by the channel it runs on
    const eval_hosts::Dict{String,Base.Process}                 # by project id
    control::Union{WorkerLink.LinkChannel,Nothing}   # the control channel being served
    relay::Union{MCPRelay,Nothing}
    closed::Bool
    link::WorkerLink.Link                            # last: its handlers need the worker
    function Worker(config::WorkerConfig)
        w = new(config, ReentrantLock(), UpdateState(nothing, false, 0),
                Dict{WorkerLink.LinkChannel,AgentSession}(), Dict{String,Base.Process}(),
                nothing, nothing, false)
        w.link = new_link(w)
        return w
    end
end

new_link(w::Worker) = WorkerLink.Link(:client;
    on_open  = ch -> serve_channel(w, ch),
    on_state = (_, st) -> st === :dead && reap!(w, "the link to the server died"))

updating(w::Worker) = lock(() -> w.update.pending, w.lock)

# Nothing running for the server: no agent, no eval host.
worker_idle(w::Worker) = lock(() -> isempty(w.sessions) && isempty(w.eval_hosts), w.lock)

"""
    serve(w::Worker; retry_delay = 5.0)

Connect `w` to its server and keep it connected, until `close(w)`.
"""
function serve(w::Worker; retry_delay::Real = 5.0)
    while !w.closed
        try
            connect_once!(w)
        catch e
            e isa InterruptException && rethrow()
            w.closed && break
            if e isa WorkerLink.LinkRefused
                @error "BonitoWorker: the server refused this worker" reason = e.reason
            else
                @error "BonitoWorker: connection failed" exception = (e, catch_backtrace())
            end
        end
        w.closed && break
        @info "BonitoWorker: reconnecting in $(retry_delay)s"
        sleep(retry_delay)
    end
    return nothing
end

# One connection: dial, handshake, and hold it until it ends.
function connect_once!(w::Worker)
    WorkerLink.state(w.link) === :dead && (w.link = new_link(w))
    url = ws_url(w.config.server_url, "/w")
    @info "BonitoWorker: connecting" url worker_id = w.config.worker_id name = w.config.name
    t = WorkerLink.WebSocketTransport(WebSockets.open(url))
    ack = decode_control(WorkerLink.connect!(w.link, t, MsgPack.pack(hello(w))))
    connected!(w, ack)
    wait(t)
    @info "BonitoWorker: connection ended"
    return nothing
end

function hello(w::Worker)
    c = w.config
    return Dict(
        "secret"        => c.secret,
        "worker_id"     => c.worker_id,
        "name"          => c.name,
        "hostname"      => gethostname(),
        "username"      => get(ENV, "USER", get(ENV, "USERNAME", "")),
        "home"          => homedir(),
        "mcp_path"      => c.mcp_command,
        "mcp_args"      => c.mcp_arguments,
        "projects_root" => c.projects_root,
        "auto_update"   => c.update_config !== nothing && auto_update_enabled(c.update_config),
        "update_spec"   => c.update_config === nothing ? nothing : configured_update_spec(c.update_config),
    )
end

# After a handshake. The control channel we already serve means the link
# resumed and everything carries on. Another one means the link is new or was
# reset: the server has no use for anything from before.
function connected!(w::Worker, ack::AbstractDict)
    ctrl = WorkerLink.control_channel(w.link)
    if ctrl === w.control
        @info "BonitoWorker: link resumed"
    else
        reap!(w, "the server started a new link")
        relay = start_mcp_relay(ctrl)
        old = lock(w.lock) do
            prev = w.relay
            w.control = ctrl
            w.relay = relay
            prev
        end
        old === nothing || close(old)
        Base.errormonitor(@async serve_control(w, ctrl))
        @info "BonitoWorker: registered with server" name = get(ack, "registered_as", w.config.name)
    end
    w.config.update_config === nothing || schedule_auto_update!(w, get(ack, "update_spec", nothing))
    return nothing
end

"""
    reap!(w::Worker, reason)

Kill every agent and eval host `w` runs for the server, and abort the agents'
channels with `reason`.
"""
function reap!(w::Worker, reason::AbstractString)
    sessions, hosts = lock(w.lock) do
        s = collect(w.sessions)
        h = collect(values(w.eval_hosts))
        empty!(w.sessions)
        empty!(w.eval_hosts)
        (s, h)
    end
    isempty(sessions) && isempty(hosts) && return nothing
    @info "BonitoWorker: reaping" agents = length(sessions) eval_hosts = length(hosts) reason
    for (ch, s) in sessions
        kill_proc!(s.proc)
        WorkerLink.abort(ch, reason)
    end
    foreach(kill_proc!, hosts)
    return nothing
end

function Base.close(w::Worker)
    lock(() -> (w.closed = true), w.lock)
    WorkerLink.kill!(w.link, "worker closed")          # reaps, see `new_link`
    relay = lock(w.lock) do
        r = w.relay
        w.relay = nothing
        w.control = nothing
        r
    end
    relay === nothing || close(relay)
    return nothing
end

# ── Control channel ─────────────────────────────────────────────────────────

# The server's commands, for as long as the channel lives (a reset or a dead
# link aborts it). Each runs in its own task and replies on the same channel.
function serve_control(w::Worker, ctrl::WorkerLink.LinkChannel)
    try
        for frame in ctrl
            try
                dispatch_command(w, ctrl, decode_control(frame))
            catch e
                e isa InterruptException && rethrow()
                @error "BonitoWorker: control command failed" exception = (e, catch_backtrace())
            end
        end
    catch e
        e isa WebSockets.WebSocketError || rethrow()
    end
    return nothing
end

function dispatch_command(w::Worker, ws, cmd::AbstractDict)
    c = w.config
    t = get(cmd, "type", "")
    if t in ("mcp_frame", "mcp_close")
        handle_mcp_relay_frame!(w.relay, cmd)
    elseif t == "list_dir"
        @async handle_list_dir(ws, cmd)
    elseif t == "make_dir"
        @async handle_make_dir(ws, cmd)
    elseif t == "ensure_dir"
        @async handle_ensure_dir(ws, cmd)
    elseif t == "stat_path"
        @async handle_stat_path(ws, cmd)
    elseif t == "read_file_range"
        @async handle_read_file_range(ws, cmd)
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
    elseif t == "git_diff"
        @async handle_git_diff(ws, cmd)
    elseif t == "find_repos"
        @async handle_find_repos(ws, cmd)
    elseif t == "worker_state"
        @async handle_worker_state(w, ws, cmd)
    elseif t == "read_log"
        @async handle_read_log(ws, cmd)
    elseif t == "debug_checkout"
        @async handle_debug_checkout(ws, cmd)
    elseif t == "open_eval_host"
        @async handle_open_eval_host(w, ws, cmd)
    elseif t == "close_eval_host"
        @async handle_close_eval_host(w, ws, cmd)
    elseif t == "stage_session"
        @async handle_stage_session(ws, cmd)
    elseif t == "install_session"
        @async handle_install_session(ws, cmd)
    elseif t == "discard_staging"
        @async handle_discard_staging(ws, cmd)
    elseif t == "force_update"
        if c.update_config === nothing
            report_update_status(ws, "unsupported";
                error = "this worker runs without an update config")
        else
            report = (status; error = "") -> report_update_status(ws, status; error)
            schedule_auto_update!(w, get(cmd, "update_spec", nothing);
                force = true, immediate = get(cmd, "immediate", false) === true, report)
            report(updating(w) ? "installing" : "waiting")
        end
    else
        @warn "BonitoWorker: unknown control command" type = t
    end
    return nothing
end

# ── Channels the server opens ───────────────────────────────────────────────
# One agent session or one file transfer, as the header says. Answered with
# `{ok: true}` once it runs, or aborted with the reason it can't, which the
# server reports to whoever asked.

function serve_channel(w::Worker, ch::WorkerLink.LinkChannel)
    header = decode_control(WorkerLink.header(ch))
    kind = get(header, "kind", "")
    if kind == "acp"
        run_agent_session(w, ch, header)
    elseif kind == "transfer"
        run_transfer(ch, header)
    else
        refuse_channel(ch, "unknown channel kind '$(kind)'")
    end
    return nothing
end

channel_ready(ch::WorkerLink.LinkChannel) = WebSockets.send(ch, MsgPack.pack(Dict("ok" => true)))

function refuse_channel(ch::WorkerLink.LinkChannel, reason::AbstractString)
    @error "BonitoWorker: refused the server's request" reason
    WorkerLink.abort(ch, reason)
    return nothing
end

# An agent for one of the server's chats: spawn it, then relay ACP lines
# between it and the channel until either side ends. Closing the channel ends
# the agent, and the agent exiting closes the channel.
function run_agent_session(w::Worker, ch::WorkerLink.LinkChannel, header::AbstractDict)
    updating(w) && return refuse_channel(ch,
        "worker is installing a server update; it will reconnect shortly")
    c = w.config
    cwd        = String(get(header, "cwd", pwd()))
    project_id = String(get(header, "project_id", ""))

    # Resolve the requested provider from the single AgentProviders registry —
    # the SAME descriptors + list the server's dropdown is built from, so the two
    # sides can't disagree. Its `bin`/`args`/`env` are resolved HERE, on the
    # machine that owns the binary. An unknown provider — or the mock when
    # `BT_ENABLE_MOCK_AGENT` is unset — is refused, not swapped for a default.
    provider_str = String(get(header, "provider", "ClaudeCode"))
    provider = try
        AgentProviders.find_provider(provider_str)
    catch e
        e isa ErrorException || rethrow()
        return refuse_channel(ch, "unknown provider '$provider_str': $(sprint(showerror, e))")
    end
    # The installer points `agent_bin` at the local claude-agent-acp; every other
    # provider uses the descriptor's bin.
    agent_bin = (provider_str == "ClaudeCode" && !isempty(c.agent_bin)) ? c.agent_bin : provider.bin

    if !isdir(cwd)
        try
            mkpath(cwd)
        catch e
            e isa Base.IOError || e isa SystemError || rethrow()
            return refuse_channel(ch, "could not create cwd $cwd: $(sprint(showerror, e))")
        end
    end

    # The server URL goes to the agent, and explicitly into our MCP entry in the
    # relay below: some agents filter the environment their MCP children inherit.
    env = provider_env(provider, merge(Dict("BONITOAGENTS_SERVER_URL" => c.server_url), c.agent_env))
    # `provider.args` carries any required subcommand (`["acp"]` for
    # mimo/opencode/kimi, whose ACP server lives under that subcommand).
    agent_args = provider.args
    proc = try
        # `detach` = `setsid()` in the child: the agent leads its OWN process
        # group, so everything it spawns (the MCP servers, and the Julia eval
        # workers under those) goes down with it in `kill_proc!`.
        open(detach(Cmd(`$agent_bin $agent_args`; env, dir = cwd)), "r+")
    catch e
        e isa Base.IOError || rethrow()
        # Not `showerror`: Julia's message spells out the command WITH its whole
        # environment, secrets included, and this reason reaches the user.
        return refuse_channel(ch,
            "failed to spawn agent ($agent_bin $(join(agent_args, ' '))): $(Base.struverror(e.code))")
    end
    relay = w.relay
    # Names this session's MCP grants, so they are revoked with it.
    owner = "acp:" * bytes2hex(rand(Random.RandomDevice(), UInt8, 8))
    lock(() -> (w.sessions[ch] = AgentSession(proc, project_id, cwd)), w.lock)
    @info "BonitoWorker: ACP session started" project_id cwd provider = provider_str pid = getpid(proc)
    try
        channel_ready(ch)
        to_agent   = @async relay_ws_to_proc(ch, proc; server_url = c.server_url, mcp_relay = relay, owner)
        from_agent = @async relay_proc_to_ws(proc, ch)
        try
            wait(to_agent)
        finally
            # The agent first: its output reader then sees EOF and ends.
            kill_proc!(proc)
            wait(from_agent)
        end
    catch e
        # The server gave up on the session before we could answer.
        e isa WebSockets.WebSocketError || rethrow()
    finally
        relay === nothing || revoke_mcp_grants!(relay, owner)
        lock(() -> delete!(w.sessions, ch), w.lock)
        kill_proc!(proc)
        close(ch)
    end
    @info "BonitoWorker: ACP session ended" project_id cwd
    return nothing
end

# A RemoteSync transfer. Whatever can fail before the first byte (a missing
# source, an unwritable destination) fails before the answer, so the server
# reports the reason instead of a broken stream.
function run_transfer(ch::WorkerLink.LinkChannel, header::AbstractDict)
    direction = String(get(header, "direction", ""))
    wsio = RemoteSync.WebSocketIO(ch)
    try
        if direction == "to_worker"
            # A push onto this machine only adds and updates: whatever else lives
            # under `dst` is the user's and stays, and no field of the request can
            # change that. `quick_check=false` (user-confirmed directional
            # overwrites) delta-checks even files whose size+mtime match.
            dst = String(header["dst_path"])
            mkpath(dst)
            channel_ready(ch)
            RemoteSync.receive_directory(dst, wsio; quick_check = get(header, "quick_check", true) === true)
        elseif direction == "from_worker"
            src = String(header["src_path"])
            isdir(src) || error("src_path is not a directory: $src")
            channel_ready(ch)
            RemoteSync.send_directory(src, wsio)
        elseif direction == "file_from_worker"
            src = String(header["src_path"])
            isfile(src) || error("src_path is not a file: $src")
            channel_ready(ch)
            RemoteSync.send_file(src, wsio)
        elseif direction == "file_to_worker"
            # One file (a pasted screenshot, an eval artifact): no tree walk.
            dst = String(header["dst_path"])
            mkpath(dirname(dst))
            channel_ready(ch)
            RemoteSync.receive_file(dst, wsio)
        else
            error("unknown transfer direction '$direction'")
        end
        close(wsio)             # flushes, then closes the channel
        @info "BonitoWorker: transfer done" direction
    catch e
        e isa InterruptException && rethrow()
        @error "BonitoWorker: transfer failed" direction exception = e
        WorkerLink.abort(ch, "transfer failed: $(sprint(showerror, e))")
    end
    return nothing
end
