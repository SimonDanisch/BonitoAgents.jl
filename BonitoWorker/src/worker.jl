# ── The worker ──────────────────────────────────────────────────────────────
# One running worker: what it was started with, its link to the server, and
# everything it runs for the server's chats.
#
# The link is the worker's ONE connection (`/w`). Its control channel carries
# the server's commands and our replies; the server opens one more channel per
# agent session and per file transfer, with the request as the channel's header
# (`serve_channel`), and the worker opens one per local MCP or eval-worker
# connection to its relay (mcp_relay.jl). A dropped connection only DETACHES the link: the agents keep
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
    # `name:password` the server's proxy checks on `/w` (issued by "Add worker"),
    # or "" for a server on this machine, which has no proxy in front.
    credential::String = ""
    worker_id::String
    name::String
    mcp_command::String
    mcp_arguments::Vector{String}
    projects_root::String
    # Environment for every agent, over the inherited one.
    agent_env::Dict{String,String} = Dict{String,String}()
    # `nothing`: this worker does not update itself (dev and standalone workers).
    # An installed update writes its spec back into it.
    update_config::Union{Dict{String,Any},Nothing} = nothing
    # This run of the worker, and the previous one if it crashed ("" if not),
    # both in every hello: the server continues what a crash cut off.
    instance::String = ""
    crashed_instance::String = ""
end

# An agent running for one of the server's chats.
struct AgentSession
    proc::Base.Process
    project_id::String
    cwd::String
end

# The managed agent adapters' upkeep (harnesses.jl): the spec to meet, the task
# meeting it, and whether a newer spec arrived while it ran.
mutable struct HarnessState
    spec::Union{HarnessSpec,Nothing}
    task::Union{Task,Nothing}
    pending::Bool
    syncing::Bool   # an install runs: new agent sessions wait for it
    sessions::Int   # agent sessions that hold the next install off
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
    const harness::HarnessState
    const sessions::Dict{WorkerLink.LinkChannel,AgentSession}   # by the channel it runs on
    const eval_hosts::Dict{String,Base.Process}                 # by project id
    control::Union{WorkerLink.LinkChannel,Nothing}   # the control channel being served
    closed::Bool
    # Last: the link's handlers need the worker. The relay opens its channels on
    # `link`, and is replaced with it (see `swap_relay!`).
    link::WorkerLink.Link
    relay::MCPRelay
    function Worker(config::WorkerConfig)
        w = new(config, ReentrantLock(), UpdateState(nothing, false, 0),
                HarnessState(nothing, nothing, false, false, 0),
                Dict{WorkerLink.LinkChannel,AgentSession}(), Dict{String,Base.Process}(),
                nothing, false)
        w.link = new_link(w)
        w.relay = start_mcp_relay(w.link)
        return w
    end
end

new_link(w::Worker) = WorkerLink.Link(:client;
    on_open  = ch -> serve_channel(w, ch),
    on_state = (link, st) -> link_state!(w, link, st))

# Every channel a link delivers must find the relay of that same link. A new link
# gets its relay before it connects, and a reset (`:reset` comes before the new
# connection delivers anything) swaps it, so neither ever races a channel.
function swap_relay!(w::Worker, relay::MCPRelay)
    old = lock(w.lock) do
        prev = w.relay
        w.relay = relay
        prev
    end
    close(old)
    return nothing
end

function link_state!(w::Worker, link::WorkerLink.Link, st::Symbol)
    if st === :dead
        reap!(w, "the link to the server died")
    elseif st === :reset
        reap!(w, "the server started a new link")
        swap_relay!(w, start_mcp_relay(link))
    end
    return nothing
end

updating(w::Worker) = lock(() -> w.update.pending, w.lock)

# Nothing running for the server: no agent, no eval host.
worker_idle(w::Worker) = lock(() -> isempty(w.sessions) && isempty(w.eval_hosts), w.lock)

"""
    serve(w::Worker; retry_delay = 5.0, repeat_log_interval = 600.0)

Connect `w` to its server and keep it connected, until `close(w)`.

A worker that cannot get in retries every `retry_delay` seconds, possibly for
days (its credential was revoked, the server is down). It keeps that cadence, so
it is back seconds after the server is, but it logs the same failure again only
every `repeat_log_interval` seconds.
"""
function serve(w::Worker; retry_delay::Real = 5.0, repeat_log_interval::Real = 600.0)
    last_failure, logged_at = "", 0.0
    while !w.closed
        isempty(last_failure) && @info "BonitoWorker: connecting" url = ws_url(w.config.server_url, "/w") worker_id = w.config.worker_id name = w.config.name
        try
            connect_once!(w)
            last_failure = ""
        catch e
            e isa InterruptException && rethrow()
            w.closed && break
            failure = sprint(showerror, e)
            if failure != last_failure || time() - logged_at > repeat_log_interval
                log_connect_failure(e)
                @info "BonitoWorker: reconnecting every $(retry_delay)s"
                last_failure, logged_at = failure, time()
            end
        end
        w.closed && break
        sleep(retry_delay)
    end
    return nothing
end

log_connect_failure(e::WorkerLink.LinkRefused) =
    @error "BonitoWorker: the server refused this worker" reason = e.reason
# The proxy turned the handshake away. Its status is all there is to say, so no
# backtrace.
log_connect_failure(e::WebSockets.WebSocketError) =
    @error "BonitoWorker: the server did not take the connection ($(sprint(showerror, e))). " *
           "401 or 403 means this worker's credential is wrong or was revoked: reinstall it " *
           "with the command from \"Add worker\" on the dashboard."
log_connect_failure(e) = @error "BonitoWorker: connection failed" exception = (e, catch_backtrace())

# One connection: dial, handshake, and hold it until it ends.
function connect_once!(w::Worker)
    if WorkerLink.state(w.link) === :dead
        w.link = new_link(w)
        swap_relay!(w, start_mcp_relay(w.link))
    end
    url = ws_url(w.config.server_url, "/w")
    # The credential rides as the URL's userinfo, which HTTP sends as Basic auth;
    # it is never logged.
    t = WorkerLink.WebSocketTransport(WebSockets.open(credential_url(url, w.config.credential)))
    ack = decode_control(WorkerLink.connect!(w.link, t, MsgPack.pack(hello(w))))
    connected!(w, ack)
    wait(t)
    @info "BonitoWorker: connection ended"
    return nothing
end

function hello(w::Worker)
    c = w.config
    return Dict(
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
        "harnesses"     => installed_harnesses(harness_root(), AgentProviders.managed_packages()),
        "instance"      => c.instance,
        "crashed_instance" => c.crashed_instance,
    )
end

# After a handshake. The control channel we already serve means the link
# resumed and everything carries on. Another one means the link is new or was
# reset; what ran on the old one is reaped already (`link_state!`).
function connected!(w::Worker, ack::AbstractDict)
    ctrl = WorkerLink.control_channel(w.link)
    if ctrl === w.control
        @info "BonitoWorker: link resumed"
    else
        lock(() -> (w.control = ctrl), w.lock)
        Base.errormonitor(@async serve_control(w, ctrl))
        @info "BonitoWorker: registered with server" name = get(ack, "registered_as", w.config.name)
    end
    w.config.update_config === nothing || schedule_auto_update!(w, get(ack, "update_spec", nothing))
    spec = harness_spec_from_wire(get(ack, "harnesses", nothing))
    spec === nothing || schedule_harness_sync!(w, spec)
    return nothing
end

# The URL a worker dials with its credential as userinfo.
credential_url(url::AbstractString, credential::AbstractString) =
    isempty(credential) ? String(url) : string(HTTP.URI(HTTP.URI(url); userinfo = credential))

"""
    schedule_harness_sync!(w, spec)

Keep the managed agent adapters at `spec` (harnesses.jl): one task per worker,
which picks up the newest spec whenever it gets to it.
"""
function schedule_harness_sync!(w::Worker, spec::HarnessSpec)
    lock(w.lock) do
        w.harness.spec = spec
        w.harness.pending = true
        t = w.harness.task
        (t === nothing || istaskdone(t)) &&
            (w.harness.task = Base.errormonitor(@async harness_loop(w)))
    end
    return nothing
end

# Meets the spec now, then again every `recheck` seconds (so "latest" follows the
# registry) or as soon as a new spec arrives, and only while no chat runs: an
# agent must not have its files replaced underneath it. A failed install (the
# network was down, a version does not exist) is tried again after `retry`
# seconds: a new machine has no adapters at all until one succeeds.
function harness_loop(w::Worker; recheck::Real = 6 * 3600.0, retry::Real = 300.0,
                      idle_poll::Real = 30.0)
    while !w.closed
        while !(w.closed || begin_harness_sync!(w))
            sleep(idle_poll)
        end
        w.closed && break
        spec = lock(() -> (w.harness.pending = false; w.harness.spec), w.lock)
        installed, err = try
            (sync_harnesses!(spec), "")
        catch e
            (e isa HTTP.Exceptions.HTTPError || e isa ProcessFailedException ||
             e isa ErrorException || e isa Base.IOError || e isa SystemError) || rethrow()
            @error "BonitoWorker: could not install the agent adapters" exception = (e, catch_backtrace())
            (installed_harnesses(harness_root(), keys(spec.packages)), sprint(showerror, e))
        finally
            lock(() -> (w.harness.syncing = false), w.lock)
        end
        report_harnesses(w, installed, err)
        timedwait(() -> w.closed || lock(() -> w.harness.pending, w.lock),
                  isempty(err) ? recheck : retry; pollint = min(5.0, idle_poll))
    end
    return nothing
end

# An install starts only while nothing runs and no agent session is starting;
# checked and claimed under the lock, so a session cannot slip in between.
function begin_harness_sync!(w::Worker)
    return lock(w.lock) do
        (worker_idle(w) && w.harness.sessions == 0) || return false
        w.harness.syncing = true
        return true
    end
end

# An agent session's claim on the adapters: waits out an install that runs
# (`false` if it does not finish within `timeout`, which stays under the 30 s the
# server gives the session to start, so the reason reaches the user), then holds
# the next install off until `release_adapters!`.
function hold_adapters!(w::Worker; timeout::Real = 20.0)
    deadline = time() + timeout
    while true
        held = lock(w.lock) do
            w.harness.syncing && return false
            w.harness.sessions += 1
            return true
        end
        held && return true
        time() > deadline && return false
        sleep(0.5)
    end
end

release_adapters!(w::Worker) = lock(() -> (w.harness.sessions -= 1), w.lock)

# Tell the server what is installed, for the worker's card.
function report_harnesses(w::Worker, installed::AbstractDict, err::AbstractString)
    ctrl = lock(() -> w.control, w.lock)
    ctrl === nothing && return nothing
    try
        send_control(ctrl, Dict("type" => "harness_status", "installed" => installed, "error" => err))
    catch e
        (e isa WebSockets.WebSocketError || e isa WorkerLink.LinkDead) || rethrow()
    end
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
    lock(() -> (w.closed = true; w.control = nothing), w.lock)
    WorkerLink.kill!(w.link, "worker closed")          # reaps, see `link_state!`
    close(lock(() -> w.relay, w.lock))
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
    if t == "list_dir"
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
    elseif t == "harness_spec"
        spec = harness_spec_from_wire(get(cmd, "spec", nothing))
        spec === nothing ? @warn("BonitoWorker: ignored a malformed adapter spec", spec = get(cmd, "spec", nothing)) :
                           schedule_harness_sync!(w, spec)
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
    # An adapter install that runs finishes first, and this session holds the
    # next one off until it ends: an agent never has its files replaced
    # underneath it.
    hold_adapters!(w) || return refuse_channel(ch,
        "worker is still installing its agent adapters; try again in a minute")
    try
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
        agent = agent_command(provider)
        agent_bin = agent.bin

        if !isdir(cwd)
            try
                mkpath(cwd)
            catch e
                e isa Base.IOError || e isa SystemError || rethrow()
                return refuse_channel(ch, "could not create cwd $cwd: $(sprint(showerror, e))")
            end
        end

        env = provider_env(provider, c.agent_env)
        isempty(agent.path) || (env["PATH"] = agent.path * (Sys.iswindows() ? ';' : ':') * get(env, "PATH", ""))
        # `provider.args` carries any required subcommand (`["acp"]` for
        # mimo/opencode/kimi, whose ACP server lives under that subcommand).
        agent_args = provider.args
        relay = lock(() -> w.relay, w.lock)   # the relay of the link `ch` came on
        # Names this session's MCP grants, so they are revoked with it.
        owner = "acp:" * bytes2hex(rand(Random.RandomDevice(), UInt8, 8))
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
        lock(() -> (w.sessions[ch] = AgentSession(proc, project_id, cwd)), w.lock)
        @info "BonitoWorker: ACP session started" project_id cwd provider = provider_str pid = getpid(proc)
        try
            channel_ready(ch)
            to_agent   = @async relay_ws_to_proc(ch, proc, relay, owner)
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
            revoke_mcp_grants!(relay, owner)
            lock(() -> delete!(w.sessions, ch), w.lock)
            kill_proc!(proc)
            close(ch)
        end
        @info "BonitoWorker: ACP session ended" project_id cwd
        return nothing
    finally
        release_adapters!(w)
    end
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
