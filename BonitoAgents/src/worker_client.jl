# Server side of the worker connection. Every worker dials ONE websocket, `/w`,
# and runs a WorkerLink over it (`handle_worker_link`):
#
#   control channel  MsgPack commands to the worker and its replies; a reply
#                    finds its caller through `request_id`.
#   other channels   one per agent session and one per file transfer, opened
#                    by the SERVER with the request as the channel's header
#                    (`open_worker_channel`); and one per MCP process and eval
#                    worker bridge, opened by the WORKER's local relay
#                    (`accept_worker_channel`).
#
# A dropped connection DETACHES the link instead of ending it: the worker shows
# offline, its agents keep running, and a reconnect within
# `state.worker_link_grace` resumes every channel where it stopped. Only a dead
# link tears the worker's registration down (`teardown_worker!`).

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol, RemoteSync

# All worker-related state lives on `state::ServerState`:
#   state.worker_links      — worker id → its WorkerLink.Link
#   state.pending_rpcs      — request_id → Channel{Any}, one dict for every RPC
#                              type (list_dir, scan_sessions, clone_repo, …). The
#                              keys are uuids, so types can't collide.
#   state.pending_chunks    — request_id → ChunkAccumulator for replies that span
#                              MULTIPLE frames (git_diff's patch); `deliver_chunk!`
#                              reassembles per frame and resolves once complete.

"The worker's link, or `nothing` when it has none."
worker_link(state::ServerState, worker_id::AbstractString) =
    lock(() -> get(state.worker_links, worker_id, nothing), state.lock)

"""
    worker_connected(state, worker_id) -> Bool

Whether the worker can be reached right now: it has a link, and the link has a
connection. A detached link, waiting for the worker to come back, has none.
"""
function worker_connected(state::ServerState, worker_id::AbstractString)
    link = worker_link(state, worker_id)
    return link !== nothing && WorkerLink.state(link) === :connected
end

# The link of a worker that can be reached right now; throws otherwise. A
# command queued on a detached link would only make its caller sit out a
# timeout, so nothing is sent to a worker that isn't there.
function connected_link(state::ServerState, worker_id::AbstractString)
    link = worker_link(state, worker_id)
    (link === nothing || WorkerLink.state(link) !== :connected) &&
        error("Worker '$worker_id' is not connected")
    return link
end

# Send a command to a worker over its control channel.
function send_command(state::ServerState, worker_id::String, payload::AbstractDict)
    send_control(WorkerLink.control_channel(connected_link(state, worker_id)), payload)
    return nothing
end

# ── The control-WS wire ─────────────────────────────────────────────────────
# MsgPack in a BINARY frame; the worker's half of this lives in BonitoWorker and
# the two must move together. See the long note there for why it is not JSON: a
# TEXT frame is UTF-8 validated by the receiver, this protocol carries filenames
# and diff hunks and file previews, and one byte that isn't valid UTF-8 closed
# the link with 1007 — then again on every reconnect, because the server re-sent
# the same command. A binary frame is never validated, so a bad byte is data to
# handle rather than a severed connection.
#
send_control(ws, payload::AbstractDict) = WebSockets.send(ws, MsgPack.pack(payload))

"""
    decode_control(frame) -> Dict{String,Any}

Decode one control-WS frame. Binary only — a text frame means the worker still
speaks the old JSON wire, and saying so beats letting half a migration run.
"""
decode_control(frame::AbstractVector{UInt8}) = normalize_wire(MsgPack.unpack(frame))
decode_control(frame::AbstractString) = error(
    "BonitoAgents: got a TEXT control frame — this worker still speaks the old " *
    "JSON wire. Update the worker (re-run the installer against this server).")

"""
    normalize_wire(x)

Put a decoded MsgPack value back into the shape the handlers expect:
`Dict{String,Any}` with `Int64` integers.

MsgPack encodes integers in the narrowest type that fits, so `0` arrives as
`UInt8` and `12345` as `UInt16`, and maps arrive as `Dict{Any,Any}`. Unsigned
arithmetic WRAPS, which turns a narrowed `size - 1` into 255 somewhere far from
here, so it is normalised once rather than guarded at every use. `Bool` is
matched ahead of `Integer` because it is one, and widening would make `true`
into `1`.
"""
normalize_wire(x::Bool)           = x
normalize_wire(x::Integer)        = Int64(x)
normalize_wire(x::AbstractDict)   = Dict{String,Any}(String(k) => normalize_wire(v) for (k, v) in x)
normalize_wire(x::AbstractVector) = Any[normalize_wire(v) for v in x]
normalize_wire(x)                 = x

"""
    WorkerUnreachableError(op, detail)

A worker RPC failed because the worker cannot be reached: it has no connection
("not connected") or the RPC hit its deadline ("timed out"). Callers that gate a user
action on worker liveness (the editor open-guard) match on this TYPE to fail
closed immediately, instead of parsing message strings.
"""
struct WorkerUnreachableError <: Exception
    op     :: String
    detail :: String
end
Base.showerror(io::IO, e::WorkerUnreachableError) = print(io, e.op, " ", e.detail)

# Register a pending RPC: returns (request_id, channel). Caller sends the
# command (with `request_id` set to the returned id) and waits on the channel
# via `take_pending!`. The matching control-frame handler pops the id out of
# `pending_rpcs` and puts the response on the channel.
function register_rpc!(state::ServerState)
    rid = string(uuid4())
    ch  = Channel{Any}(1)
    lock(state.lock) do
        state.pending_rpcs[rid] = ch
    end
    return (rid, ch)
end

"""
    register_chunked_rpc!(state)

Register a pending RPC whose reply arrives as a SERIES of frames, not one.
Same contract as [`register_rpc!`](@ref) — the caller sends the command with
`request_id` set to the returned id and waits via `take_pending!` — but the
reply frames go through [`deliver_chunk!`](@ref), which reassembles them into
the single value `git_diff_on_worker` exposes. The accumulator lives in
`state.pending_chunks`; the timeout/cancel paths evict it with the plain
`pending_rpcs` entry.
"""
function register_chunked_rpc!(state::ServerState)
    rid = string(uuid4())
    ch  = Channel{Any}(1)
    lock(state.lock) do
        state.pending_chunks[rid] = ChunkAccumulator(ch, nothing, 0, IOBuffer(),
                                                     Dict{String,Any}())
    end
    return (rid, ch)
end

# Drop a pending-RPC registration if it's still present (T10). `take_pending!`
# already evicts on timeout/success, but if `send_command` (or the command
# dict-build) throws between `register_rpc!` and `take_pending!`, the entry
# would leak — the RPC wrappers run this in a `finally` to cover that gap.
# No-op once the key is gone (the normal success path already removed it).
function unregister_rpc!(state::ServerState, key::AbstractString)
    lock(state.lock) do
        rid = String(key)
        haskey(state.pending_rpcs, rid) && delete!(state.pending_rpcs, rid)
        haskey(state.pending_chunks, rid) && delete!(state.pending_chunks, rid)
    end
    return nothing
end

# Take from a pending-RPC channel with a bounded wait. If `timeout` seconds
# elapse without the worker replying, evict the entry (so a late reply gets
# "unknown id") and surface a clear error to the caller.
function take_pending!(state::ServerState, ch::Channel, key::String,
                       timeout::Real, op_name::AbstractString)
    # Fire the timeout from a `Timer` rather than an `@async sleep(timeout)`
    # task (T15): the old design left one sleeping task alive for the FULL
    # timeout (15–120 s, and the 1 Hz bg poller calls this every tick) even when
    # the reply landed in milliseconds. The timer is `close`d the instant the
    # take returns, so a fast reply doesn't strand anything.
    timer = Timer(timeout) do _
        # Atomic "take if present" so we don't race a concurrent
        # deliver_rpc_response!/deliver_chunk! popping the same key.
        had = lock(state.lock) do
            if haskey(state.pending_rpcs, key)
                delete!(state.pending_rpcs, key)
                true
            elseif haskey(state.pending_chunks, key)
                delete!(state.pending_chunks, key)
                true
            else
                false
            end
        end
        if had
            # The channel may have been closed by a peer-cleanup between the
            # `had` check above and this put!. That's exactly the race this
            # whole timeout dance handles — not a real error.
            try
                put!(ch, nothing)
            catch e
                e isa InvalidStateException || rethrow()
            end
        end
    end
    val = try
        take!(ch)
    finally
        close(timer)
    end
    val === nothing && throw(WorkerUnreachableError(String(op_name),
        "timed out after $(timeout)s — worker may be offline or stuck"))
    # A definitive failure arrives as an Exception (`deliver_rpc_error!`), so
    # the caller fails fast instead of waiting out the timeout.
    val isa Exception && throw(val)
    return val
end

# Try to deliver a worker-pushed RPC reply by request_id. No-op if the id is
# unknown (caller already timed out, or the response races a re-registration).
# Also serves CHUNKED requests: a worker replying to a chunked request in one
# legacy-shaped frame (or an error frame) reaches the same channel through the
# accumulator.
function deliver_rpc_response!(state::ServerState, rid::AbstractString, value)
    ch = lock(state.lock) do
        if haskey(state.pending_rpcs, rid)
            pop!(state.pending_rpcs, rid)
        elseif haskey(state.pending_chunks, rid)
            pop!(state.pending_chunks, rid).ch
        else
            nothing
        end
    end
    ch === nothing && return
    # Caller may have given up (closed the channel) between our pop!
    # above and this put!. Same race as `take_pending!`; not an error.
    try
        put!(ch, value)
    catch e
        e isa InvalidStateException || rethrow()
    end
    return
end

# Fail a pending RPC: deliver an Exception so `take_pending!` rethrows it (M9),
# e.g. an MCP request whose relay channel went away.
function deliver_rpc_error!(state::ServerState, rid::AbstractString, message::AbstractString)
    deliver_rpc_response!(state, rid, ErrorException(message))
    return
end

"""
    deliver_chunk!(state, cmd)

Assemble the fragments of a chunked worker reply (`git_diff_chunk`). The
dispatch arm in the worker control loop feeds every decoded frame here; the
frame carries `request_id`, `index`/`total` (Int — `normalize_wire` widened
them), `chunk` (String, binary-safe on the MsgPack wire), and on the FIRST
frame the reply's metadata (`repo`, `branch`, `head`, `base`, `scope`). Once
`received == total` the accumulator's channel gets the reassembled payload and
`git_diff_on_worker`'s `take_pending!` returns it.

Edge cases resolve exactly like the single-frame path:
  * error chunk                        → whole dict via `deliver_rpc_response!`
  * `total < 1` announced              → ErrorException
  * `index > total`                    → ErrorException
  * unknown/expired request_id         → no-op (caller already timed out)
"""
function deliver_chunk!(state::ServerState, cmd::AbstractDict)
    rid = String(get(cmd, "request_id", ""))
    isempty(rid) && return
    if haskey(cmd, "error")
        # A chunked request can also fail as ONE small frame (e.g. repo path
        # not inside the working copy); the caller checks for the `error` key.
        deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
        return
    end
    chunk = String(get(cmd, "chunk", ""))
    index = Int(get(cmd, "index", 0))
    total = Int(get(cmd, "total", 0))
    r = lock(state.lock) do
        acc = get(state.pending_chunks, rid, nothing)
        acc === nothing && return nothing  # timed out / never registered
        if acc.total === nothing
            # First frame: the worker ships repo/branch/head/base/scope here.
            if total < 1
                delete!(state.pending_chunks, rid)
                return (acc.ch, ErrorException("git_diff: chunk frame announced total < 1"))
            end
            acc.total = total
            for k in ("repo", "branch", "head", "base", "scope")
                acc.meta[k] = String(get(cmd, k, ""))
            end
        elseif index > acc.total
            delete!(state.pending_chunks, rid)
            return (acc.ch, ErrorException("git_diff: chunk index $index exceeds the announced $(acc.total)"))
        end
        write(acc.buf, chunk)
        acc.received += 1
        acc.received == acc.total || return nothing  # more frames to come
        # Last frame: reassemble and resolve the RPC with the full reply.
        acc.meta["patch"] = String(take!(acc.buf))
        delete!(state.pending_chunks, rid)
        return (acc.ch, acc.meta)
    end
    r === nothing && return
    ch, value = r
    try
        put!(ch, value)
    catch e
        e isa InvalidStateException || rethrow()
    end
    return
end

# What the hello frame says about this worker's install, against the spec this
# server hands out. A worker from before self-updating sends neither
# `auto_update` nor `update_spec`: it cannot install anything by itself and does
# not understand `force_update`, so the only remedy is a reinstall, and the card
# has to say so instead of showing it green. A current worker without a
# configured spec (a dev worker spawned from a checkout) cannot be judged and
# counts as current. Whether auto-update is on only changes the message: an
# outdated worker is outdated either way.
function worker_update_state(hello::AbstractDict, update_spec::AbstractDict)
    haskey(hello, "auto_update") || return (:reinstall,
        "This worker is too old to update itself. Reinstall it on that machine with the install command.")
    installed = get(hello, "update_spec", nothing)
    (installed === nothing || installed == update_spec) && return (:current, "")
    get(hello, "auto_update", false) === true && return (:available,
        "A worker update is available. It installs by itself once no chat runs here; Update now installs it right away and restarts this worker's chats.")
    return (:available,
        "A worker update is available. Auto-update is off here: Update now installs it right away and restarts this worker's chats, or reinstall.")
end

"""
    handle_worker_link(state, ws)

One connection to `/w`. Reads the worker's hello, checks its secret, and either
resumes the worker's link (the hello names it and it is still alive) or starts
a new one, which kills and tears down whatever link the worker had before.
Returns once this connection ends; the link can outlive it.
"""
function handle_worker_link(state::ServerState, ws)
    t = WorkerLink.WebSocketTransport(ws)
    worker_id = "?"
    try
        hello = WorkerLink.read_hello(t; timeout = 10)
        info = decode_control(hello.app)
        if get(info, "secret", "") != state.worker_secret
            WorkerLink.refuse(t, "unauthorized")
            return
        end
        name      = String(get(info, "name", get(info, "hostname", "anon")))
        worker_id = String(get(info, "worker_id", name))
        # A rename in the UI survives reconnects: the worker knows nothing of it.
        existing  = get(state.workers[], worker_id, nothing)
        shown_as  = existing === nothing ? name : existing.name
        link, resumed = claim_worker_link!(state, worker_id, hello.link_id)
        WorkerLink.welcome!(link, t, hello, MsgPack.pack(Dict(
            "ok"            => true,
            "registered_as" => shown_as,
            "worker_id"     => worker_id,
            # The same spec /install.jl serves, over the authenticated link.
            "update_spec"   => current_worker_update_spec())); resumed)
        # A resumed link is the same worker process as before, so its record
        # stands; a new link may be a new install, a renamed host, a new build.
        # Link and record are stored only now, together, with the link
        # connected: whoever sees the worker can reach it, and the other way
        # round.
        if !resumed
            register_worker!(state, worker_id, shown_as, info, link)
            # One reader per link: a resume keeps the control channel, and so
            # the reader that already serves it.
            Base.errormonitor(@async serve_worker_control(state, worker_id, link))
            worker_came_online!(state, worker_id)
        end
        # Returning closes the websocket, so stay until the connection ends.
        wait(t)
    catch e
        # Anything escaping here would vanish into the websocket layer, which
        # closes the socket without a word: the worker redials and loops forever
        # with nothing in our log.
        is_peer_gone(e) ||
            @error "Worker connection handler failed" worker_id exception = (e, catch_backtrace())
        WorkerLink.close_transport(t)
    end
    return nothing
end

# The link this connection continues: the worker's current one when the hello
# names it and it is still alive, otherwise a new one (stored by
# `register_worker!`). A link replaced here is killed first, so its `:dead`
# handler tears the old registration down (its agents and chats' sessions are
# gone with the worker process that ran them) before the new one exists.
function claim_worker_link!(state::ServerState, worker_id::String, link_id::Vector{UInt8})
    old = worker_link(state, worker_id)
    if old !== nothing && WorkerLink.link_id(old) == link_id && WorkerLink.state(old) !== :dead
        return old, true
    end
    old === nothing || WorkerLink.kill!(old, "the worker connected with a new link")
    link = WorkerLink.Link(:server; id = link_id,
                           grace         = state.worker_link_grace,
                           ping_interval = state.heartbeat_interval,
                           ping_deadline = state.heartbeat_deadline,
                           on_open       = ch -> accept_worker_channel(state, worker_id, ch),
                           on_state      = (l, st) -> worker_link_changed!(state, worker_id, l, st))
    return link, false
end

# A channel the worker opened: its relay's connection for a chat's MCP process
# (`"mcp"`) or for an eval worker's live-render bridge (`"eval"`), see
# BonitoWorker's mcp_relay.jl. A worker speaks for the chats it runs, and, as an
# eval host (`host`), for the chats that let it run their Julia. Answered the way
# the worker answers ours: `{ok: true}` (`accept_channel`) as the first frame
# once it is served, or an abort with the reason; the relay passes either on to
# the local process that asked.
accept_channel(ch::WorkerLink.LinkChannel) = send_control(ch, Dict("ok" => true))

function accept_worker_channel(state::ServerState, worker_id::String, ch::WorkerLink.LinkChannel)
    header = decode_control(WorkerLink.header(ch))
    project_id = String(get(header, "project_id", ""))
    host = get(header, "host", false) === true
    p = get(state.projects[], project_id, nothing)
    if p === nothing || (host ? !p.remote_eval : p.worker_id != worker_id)
        WorkerLink.abort(ch, "no chat '$(project_id)' this worker may speak for")
        return nothing
    end
    kind = get(header, "kind", "")
    if kind == "mcp"
        accept_channel(ch)
        serve_mcp_channel(state, MCPChannel(state, ch, project_id, host ? worker_id : ""))
    elseif kind == "eval"
        serve_eval_bridge(state, ch, project_id, String(get(header, "prefix", "")))
    else
        WorkerLink.abort(ch, "unknown channel kind '$(kind)'")
    end
    return nothing
end

# Record the worker a hello describes and the link it is reachable over, and
# return its record. The user's initials survive (the worker knows nothing of
# them), and so does the `online` observable: chats hold on to it, so it must
# stay the same object.
function register_worker!(state::ServerState, worker_id::String, name::String,
                          hello::AbstractDict, link::WorkerLink.Link)
    existing = get(state.workers[], worker_id, nothing)
    update_state, update_message = worker_update_state(hello, current_worker_update_spec())
    online = existing === nothing ? Observable(false) : existing.online
    w = WorkerInfo(
        worker_id,
        name,
        existing === nothing ? nothing : existing.initials,
        "<inbound-ws>",          # we never dial the worker; the URL is moot
        state.worker_secret,
        nothing,                 # ssh_target reserved for future rsync-over-ssh
        String(get(hello, "hostname", "")),
        String(get(hello, "home", "")),
        String(get(hello, "mcp_path", "")),
        Vector{String}(get(hello, "mcp_args", String[])),
        String(get(hello, "projects_root", "")),
        online,
        now(UTC),
        update_state,
        update_message,
    )
    lock(state.lock) do
        state.worker_links[worker_id] = link
        state.workers[][worker_id] = w
        migrate_legacy_worker_refs!(state, w)
        save_workers!(state)
    end
    # From here on the link keeps it current (`worker_link_changed!`); what it
    # did before it was stored went unseen, so catch up once.
    link_state = WorkerLink.state(link)
    link_state === :dead && (teardown_worker!(state, worker_id, link); return w)
    connected = link_state === :connected
    online[] == connected || (online[] = connected)
    # `migrate_legacy_worker_refs!` may have rewritten project rows, and the
    # project cards show the worker's name.
    notify_workers!(state)
    notify_projects!(state)
    @info "Worker registered" worker_id name hostname = w.hostname
    return w
end

# First contact of a new link: reconcile the worker's projects with its disk.
# Async, so the round trips never hold up the connection.
function worker_came_online!(state::ServerState, worker_id::String)
    # Drop projects whose folder is gone (scratch dirs cleared on reboot).
    Base.errormonitor(@async try
        prune_missing_projects!(state, worker_id)
    catch e
        @warn "prune_missing_projects! failed" worker = worker_id exception = e
    end)
    # Chats start lazily, when the user opens one; only the folder→threads
    # browser is filled, and only the first time (later: the Rescan button).
    if state.scan_on_connect && !haskey(state.discovered[], worker_id)
        Base.errormonitor(@async try
            scan_and_store!(state, worker_id)
        catch e
            @warn "auto-scan on connect failed" worker_id exception = e
        end)
    end
    return nothing
end

# The link's state is the worker's: connected is online, detached is offline
# with everything kept for the reconnect, dead is gone.
function worker_link_changed!(state::ServerState, worker_id::String,
                              link::WorkerLink.Link, st::Symbol)
    worker_link(state, worker_id) === link || return nothing   # replaced or removed
    st === :dead && return teardown_worker!(state, worker_id, link)
    w = get(state.workers[], worker_id, nothing)
    w === nothing && return nothing
    online = st === :connected
    w.online[] == online || (w.online[] = online)
    notify_workers!(state)
    if online
        @info "Worker connected" worker_id name = w.name
    else
        @info "Worker connection lost; its agents keep running until it reconnects" worker_id grace = state.worker_link_grace
    end
    return nothing
end

# The worker's replies on its control channel, for as long as `link` lives.
function serve_worker_control(state::ServerState, worker_id::String, link::WorkerLink.Link)
    ctrl = WorkerLink.control_channel(link)
    try
        # Every typed reply maps back to a pending RPC by request_id;
        # deliver_rpc_response! is a no-op if the caller already timed out.
        for frame in ctrl
            try
                cmd = decode_control(frame)
                t   = get(cmd, "type", "")
                rid = String(get(cmd, "request_id", ""))
                if t == "update_status"
                    apply_update_status!(state, worker_id, cmd)
                elseif t in ("list_dir_response", "make_dir_response", "ensure_dir_response",
                             "stat_path_response", "read_file_range_response",
                             "list_project_files_response", "clone_repo_response",
                             "inspect_path_response", "tail_file_response",
                             "kill_file_writers_response", "git_diff_response",
                             "find_repos_response", "worker_state_response",
                             "read_log_response", "debug_checkout_response",
                             "stage_session_response", "install_session_response",
                             "discard_staging_response", "open_eval_host_response",
                             "close_eval_host_response")
                    deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                elseif t == "scan_sessions_result"
                    sessions = [Dict{String,Any}(s) for s in get(cmd, "sessions", Any[])]
                    deliver_rpc_response!(state, rid, sessions)
                elseif t == "git_diff_chunk"
                    deliver_chunk!(state, cmd)
                else
                    # An allow-list: a NEW worker RPC whose reply type isn't
                    # listed above lands here, and its caller would otherwise
                    # sit out its full timeout with no clue why.
                    @warn "Worker control: unhandled reply type — the caller will time out" *
                          " (add it in serve_worker_control)" type = t worker_id maxlog = 5
                end
            catch e
                e isa InterruptException && rethrow()
                @warn "Worker control frame error" worker_id exception = (e, catch_backtrace())
            end
        end
    catch e
        # The control channel ends only with its link (aborted when it dies).
        e isa WebSockets.WebSocketError || rethrow()
    end
    return nothing
end

"""
    teardown_worker!(state, worker_id, link) -> Bool

Tear a worker's registration down once its link is dead, but ONLY if `link` is
still the worker's link. Returns `true` if it ran.

The chats are KEPT: their models, messages and panes stay, and the worker's
shared `online` observable shows them offline. Their agent sessions are stopped
(the agents died with the link), and a new link rebinds them on the next
message.
"""
function teardown_worker!(state::ServerState, worker_id::AbstractString, link::WorkerLink.Link)
    affected = String[]
    kept     = ChatModel[]
    is_current = lock(state.lock) do
        get(state.worker_links, worker_id, nothing) === link || return false
        delete!(state.worker_links, worker_id)
        for p in values(state.projects[])
            if p.worker_id == worker_id
                m = get(state.chat_models, p.id, nothing)
                m === nothing || push!(kept, m)
                push!(affected, p.id)
            end
        end
        return true
    end
    is_current || return false
    # Observable writes and agent teardown OUTSIDE the lock. The `online`
    # observable is shared into every one of the worker's ChatModels, so this
    # one flip pauses their pollers and shows the banner everywhere.
    haskey(state.workers[], worker_id) && (state.workers[][worker_id].online[] = false)
    for m in kept
        try; stop!(m.agent); catch e
            @warn "stopping agent on worker disconnect" project_id = m.project_id exception = e
        end
        shared(m).session_alive[] = false
    end
    # The worker's eval workers (and their bridges) are gone with it. So are its
    # chats' agent sessions, and with them the eval hosts those chats had on
    # OTHER workers: nobody is left to talk to them. Same as `stop_session!`.
    for pid in affected
        teardown_eval_bridge!(state, pid)
        close_eval_hosts!(state, pid)
    end
    notify_workers!(state)
    # NOT notify_chats!: the chats are kept, so the active-chats list is
    # unchanged; they render offline until the worker returns.
    release_projects_for_worker!(state, worker_id)
    @info "Worker gone (chats kept for its return)" worker_id
    return true
end

"""
    migrate_legacy_worker_refs!(state, w::WorkerInfo)

Pre-UUID `projects.json` rows stored the worker's display name in their
`worker_id` field (the JSON key was `worker_name` then; on load we feed it
into the same struct field). When the matching worker reconnects we know
the real UUID, so this rewrites those entries in place. Safe to call on
every connect — it's a no-op once everything is on the new schema.
"""
function migrate_legacy_worker_refs!(state::ServerState, w::WorkerInfo)
    legacy_keys = (w.name, w.hostname)
    rewrote = 0
    for p in values(state.projects[])
        if p.worker_id != w.worker_id && p.worker_id in legacy_keys
            @info "migrating project worker reference" project=p.name from=p.worker_id to=w.worker_id
            p.worker_id = w.worker_id
            rewrote += 1
        end
    end
    rewrote > 0 && save_projects!(state)
    return rewrote
end

"""
    rename_worker!(state, worker_id, new_name)

Update the display name of a connected worker. The worker_id (dict key)
is unchanged so all FK references in `projects` keep resolving.
"""
function rename_worker!(state::ServerState, worker_id::AbstractString,
                         new_name::AbstractString)
    haskey(state.workers[], worker_id) || error("Unknown worker_id: $worker_id")
    new = strip(String(new_name))
    isempty(new) && error("Worker name must not be empty")
    state.workers[][worker_id].name = new
    save_workers!(state)
    notify_workers!(state)
    return state.workers[][worker_id]
end

# Per-worker `[XX]` tag shown next to chat / project labels in the sidebar.
# Empty string clears the override (the UI then falls back to
# `derive_initials(name)`). Capped at 4 chars to leave room for short
# emoji sequences but not freeform text — that's what `name` is for.
function set_worker_initials!(state::ServerState, worker_id::AbstractString,
                              new_initials::AbstractString)
    haskey(state.workers[], worker_id) || error("Unknown worker_id: $worker_id")
    s = strip(String(new_initials))
    state.workers[][worker_id].initials = isempty(s) ? nothing :
        (length(s) > 4 ? String(first(s, 4)) : String(s))
    save_workers!(state)
    notify_workers!(state)
    return state.workers[][worker_id]
end

# A user's rename of a chat. Blank puts the default (the folder name) back.
# Writing the observable is all there is to it: the title hook
# (`track_project!`) persists and fans out. Same value = no-op, so committing
# an unchanged input doesn't rewrite projects.json.
function set_project_title!(p::ProjectInfo, new_title::AbstractString)
    s = String(strip(new_title))
    isempty(s) && (s = default_title(p))
    p.title[] == s || (p.title[] = s)
    return p
end
function set_project_title!(state::ServerState, project_id::AbstractString,
                            new_title::AbstractString)
    haskey(state.projects[], project_id) || error("Unknown project_id: $project_id")
    return set_project_title!(state.projects[][project_id], new_title)
end

"""
    remove_worker!(state, worker_id; remove_projects=true)

Forget a worker: drop it from `state.workers`, kill its link, and evict any
cached `ChatModel`s for its projects. By default its projects are also removed
from the list (their server-side chat history under `state_dir/chats/<id>/` is
left on disk, so a later re-import can still find it).

A worker whose process is still running dials again and re-registers itself
(on a new link: the old one is dead), so removal primarily targets
decommissioned (offline) workers.
"""
function remove_worker!(state::ServerState, worker_id::AbstractString;
                         remove_projects::Bool = true)
    wid = String(worker_id)
    link, dropped, evicted, affected = lock(state.lock) do
        # Out of the table BEFORE the kill below, so its `:dead` handler finds
        # it replaced and leaves the teardown to this function.
        l = get(state.worker_links, wid, nothing)
        delete!(state.worker_links, wid)
        delete!(state.workers[], wid)
        dropped  = String[]
        evicted  = ChatModel[]
        affected = String[]
        for p in collect(values(state.projects[]))
            p.worker_id == wid || continue
            push!(affected, p.id)
            m = get(state.chat_models, p.id, nothing)
            m === nothing || push!(evicted, m)
            delete!(state.chat_models, p.id)
            if remove_projects
                delete!(state.projects[], p.id)
                # Same reason as in `prune_projects_with_missing_paths`: the
                # review state is keyed by project id and carries pending
                # comments, so it goes when the project does. NOT on a plain
                # session stop — that keeps the project, and a review you were
                # halfway through should survive restarting the agent.
                delete!(state.review_states, p.id)
                push!(dropped, p.id)
            end
        end
        save_workers!(state)
        remove_projects && save_projects!(state)
        (l, dropped, evicted, affected)
    end
    # Close evicted models so their consumer + background poller don't leak (see
    # teardown_worker!). Outside the lock — close()/stop! signal tasks.
    for m in evicted
        try; close(m); stop!(m.agent); catch e
            @warn "evicting chat model on worker removal" exception=e
        end
    end
    # The worker host is gone → its eval-bridge workers AND host-side wiring
    # (EVAL_WORKERS / BRIDGE_ATTACHED / MOUNTS) are dead. Tear them down for every
    # affected project so they don't leak — the worker-DISCONNECT path does this
    # too; explicit removal must not skip it. Idempotent.
    for pid in affected
        teardown_eval_bridge!(state, pid)
    end
    link === nothing || WorkerLink.kill!(link, "worker removed")
    notify_workers!(state)
    remove_projects && notify_projects!(state)
    notify_chats!(state)        # evicted chats drop out of the active-chats sidebar
    @info "Worker removed" worker_id=wid removed_projects=length(dropped)
    return nothing
end

"""
    close_worker_links!(state)

End every worker link, for a server that is shutting down. A link's tasks run
until it dies, and a detached one would otherwise wait out its grace period.
"""
function close_worker_links!(state::ServerState)
    links = lock(() -> collect(values(state.worker_links)), state.lock)
    foreach(link -> WorkerLink.kill!(link, "server shutting down"), links)
    return nothing
end

"""
    open_worker_channel(state, worker_id, header; priority, timeout = 30) -> LinkChannel

A channel to the worker for one agent session or one file transfer. `header` is
the request; its `kind` says which. The worker answers `{ok: true}` once it is
ready, or aborts the channel with the reason it can't, which is thrown here.
Lower `priority` goes first on the shared connection; the control channel is 0.
"""
function open_worker_channel(state::ServerState, worker_id::AbstractString,
                             header::AbstractDict; priority::Int, timeout::Real = 30.0)
    what = "$(header["kind"]) on '$(worker_id)'"
    ch = WorkerLink.open_channel(connected_link(state, worker_id), MsgPack.pack(header); priority)
    timed_out = Threads.Atomic{Bool}(false)
    timer = Timer(timeout) do _
        timed_out[] = true
        WorkerLink.abort(ch, "no answer within $(timeout)s")
    end
    unreachable() = WorkerUnreachableError(what,
        "timed out after $(timeout)s — worker may be offline or stuck")
    reply = try
        WebSockets.receive(ch)
    catch e
        e isa WebSockets.WebSocketError || rethrow()
        timed_out[] && throw(unreachable())
        reason = e.message.reason
        error("$(what) failed: $(isempty(reason) ? "the worker closed the channel" : reason)")
    finally
        close(timer)
    end
    timed_out[] && throw(unreachable())      # the answer and the timer crossed
    if get(decode_control(reply), "ok", false) !== true
        WorkerLink.abort(ch, "unexpected answer")
        error("$(what): unexpected answer from the worker")
    end
    return ch
end

# A RemoteSync transfer's channel. Bulk data: the lowest priority, so control
# traffic and agent sessions never wait behind it.
transfer_channel(state::ServerState, worker_id::AbstractString, header::AbstractDict;
                 timeout::Real) =
    open_worker_channel(state, worker_id, merge(Dict{String,Any}("kind" => "transfer"), header);
                        priority = 3, timeout)

# File transport: RemoteSync (librsync) over a transfer channel. The worker
# runs its side in its own task; the server's runs here in the caller's task,
# interleaved with channel reads/writes and file IO that both yield.

"""
    sync_dir_to_worker!(worker_name, src, dst; on_progress=nothing, quick_check=true)

Send the contents of server-side `src` to worker-side `dst` via librsync.
Additive: files under `dst` that `src` lacks are left alone, always. The
only receiver that mirrors (deletes what the sender lacks) is the server's own
pull, `sync_dir_from_worker!`.
Resumable: subsequent calls compute deltas against the worker's existing
files, so unchanged content isn't retransmitted. `quick_check=false` makes
the worker delta-check files even when size+mtime match (rsync --checksum
semantics) — required for directional overwrites where the destination may
hold different content with identical metadata.
"""
function sync_dir_to_worker!(state::ServerState, worker_name::String,
                              src::String, dst::String;
                              handoff_timeout::Real = 30.0,
                              on_progress = nothing,
                              quick_check::Bool = true)
    isdir(src) || error("Source path is not a directory: $src")
    notify_progress(on_progress, :phase, (msg = "Connecting to worker…",))
    ch = transfer_channel(state, worker_name, Dict(
        "direction"   => "to_worker",
        "dst_path"    => dst,
        "quick_check" => quick_check); timeout = handoff_timeout)
    try
        notify_progress(on_progress, :phase, (msg = "Streaming via librsync…",))
        RemoteSync.send_directory(src, RemoteSync.WebSocketIO(ch); on_progress = on_progress)
        notify_progress(on_progress, :phase, (msg = "Done",))
    finally
        close(ch)
    end
    return nothing
end

"""
    sync_dir_from_worker!(worker_name, src, dst; on_progress=nothing, quick_check=true)

Inverse: receive worker-side `src` into server-side `dst` via librsync.
Resumable in the same way as `sync_dir_to_worker!`; `quick_check=false`
forces delta-checking files whose size+mtime already match locally.
"""
function sync_dir_from_worker!(state::ServerState, worker_name::String,
                                src::String, dst::String;
                                handoff_timeout::Real = 30.0,
                                on_progress = nothing,
                                quick_check::Bool = true)
    mkpath(dst)
    notify_progress(on_progress, :phase, (msg = "Connecting to worker…",))
    ch = transfer_channel(state, worker_name, Dict(
        "direction" => "from_worker",
        "src_path"  => src); timeout = handoff_timeout)
    try
        notify_progress(on_progress, :phase, (msg = "Streaming via librsync…",))
        # The server's mirror tracks the worker, deletions included: this is the
        # ONE receiver that mirrors, and the folder is the server's own. The
        # receiver still refuses to empty a populated mirror for an empty worker
        # folder.
        RemoteSync.receive_directory(dst, RemoteSync.WebSocketIO(ch); on_progress = on_progress,
                                     quick_check = quick_check, delete_extraneous = true)
        notify_progress(on_progress, :phase, (msg = "Done",))
    finally
        close(ch)
    end
    return nothing
end

# Human-readable byte counts used by the progress callbacks above.
function format_bytes(n::Integer)
    n < 1024            && return "$n B"
    n < 1024^2          && return string(round(n / 1024;     digits=1), " KB")
    n < 1024^3          && return string(round(n / 1024^2;   digits=1), " MB")
                           return string(round(n / 1024^3;   digits=2), " GB")
end
format_bytes(n) = format_bytes(Int(n))

"""
    list_worker_dir(state, worker_name, path; timeout=5.0) → (path, entries) | error

Ask the named worker to readdir() `path` over its control WS. Empty `path`
asks for the worker's \$HOME. Returns a NamedTuple of (path, entries) where
entries is a Vector of NamedTuple (name, dir).
"""
function list_worker_dir(state::ServerState, worker_name::String, path::AbstractString;
                          timeout::Real = 5.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")

    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict(
            "type"       => "list_dir",
            "request_id" => rid,
            "path"       => String(path),
        ))
        take_pending!(state, ch, rid, timeout, "list_dir on '$worker_name'")
    finally
        unregister_rpc!(state, rid)   # T10: no leak on send failure
    end
    resp isa AbstractDict || error("list_dir on '$worker_name': unexpected response shape")
    haskey(resp, "error") && error("list_dir on '$worker_name': $(resp["error"])")
    return (path = String(resp["path"]),
            entries = [(name = String(e["name"]), dir = Bool(e["dir"]),
                        size = Int(get(e, "size", 0)))
                       for e in resp["entries"]])
end

"""
    make_worker_dir(state, worker_name, parent, name; timeout = 5.0) -> String

Create `parent/name` on the worker and return its absolute path. Backs the
folder picker's "New folder", so a project can be started somewhere that doesn't
exist yet. The worker rejects anything but a single path segment.
"""
function make_worker_dir(state::ServerState, worker_name::String,
                          parent::AbstractString, name::AbstractString;
                          timeout::Real = 5.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")

    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict(
            "type"       => "make_dir",
            "request_id" => rid,
            "parent"     => String(parent),
            "name"       => String(name),
        ))
        take_pending!(state, ch, rid, timeout, "make_dir on '$worker_name'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("make_dir on '$worker_name': unexpected response shape")
    haskey(resp, "error") && error("make_dir on '$worker_name': $(resp["error"])")
    return String(resp["path"])
end

"""
    ensure_worker_dir(state, worker_name, path; timeout = 5.0) -> String

Ask the worker to `mkpath(path)` and return its normalized absolute path.
Unlike [`make_worker_dir`](@ref) the target is a FULL path that may span
several segments, and it is created if it doesn't exist (parents included).
Backs the picker's "type `/newname` to create it" flow. Throws if the path
exists as a non-directory (the worker refuses).
"""
function ensure_worker_dir(state::ServerState, worker_name::String,
                           path::AbstractString; timeout::Real = 5.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")

    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict(
            "type"       => "ensure_dir",
            "request_id" => rid,
            "path"       => String(path),
        ))
        take_pending!(state, ch, rid, timeout, "ensure_dir on '$worker_name'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("ensure_dir on '$worker_name': unexpected response shape")
    haskey(resp, "error") && error("ensure_dir on '$worker_name': $(resp["error"])")
    return String(resp["path"])
end

"""
    stat_worker_path(state, worker_name, path; timeout=5.0)
        -> (exists, isfile, isdir, size, mtime, path)

Stat a single `path` on the worker (the editor open-guard asks before fetching).
`(size, mtime)` is the file's version stamp — [`fetch_show_file`](@ref) uses it
as the freshness key for the server mirror. Throws if the worker is disconnected
or the RPC errors.
"""
function stat_worker_path(state::ServerState, worker_name::String, path::AbstractString;
                          timeout::Real = 5.0)
    worker_connected(state, worker_name) ||
        throw(WorkerUnreachableError("stat_path on '$worker_name'", "worker is not connected"))

    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict(
            "type"       => "stat_path",
            "request_id" => rid,
            "path"       => String(path),
        ))
        take_pending!(state, ch, rid, timeout, "stat_path on '$worker_name'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("stat_path on '$worker_name': unexpected response shape")
    haskey(resp, "error") && error("stat_path on '$worker_name': $(resp["error"])")
    return (exists = Bool(get(resp, "exists", false)),
            isfile = Bool(get(resp, "isfile", false)),
            isdir  = Bool(get(resp, "isdir", false)),
            range_reads = Bool(get(resp, "range_reads", false)),
            size   = Int(get(resp, "size", 0)),
            # A worker predating the mtime field reports 0.0 — that pins the
            # fingerprint to `size` alone, which is weaker but never WRONG
            # (a same-size rewrite just isn't detected), and the file-editor's
            # `refresh = true` path bypasses the fingerprint entirely.
            mtime  = Float64(get(resp, "mtime", 0.0)),
            path   = String(get(resp, "path", path)))
end

function read_worker_file_range(state::ServerState, worker_id::String,
                                path::String, start::Int, count::Int)
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict("type" => "read_file_range",
            "request_id" => rid, "path" => path, "start" => start, "count" => count))
        take_pending!(state, ch, rid, 30.0, "read_file_range on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    haskey(resp, "error") && error("read_file_range: $(resp["error"])")
    return ctrl_bytes(resp["data"])
end

"""
    list_worker_project_files(state, worker_name, root; timeout=20.0)
        -> (path, files::Vector{String}, truncated::Bool)

Ask the worker to walk `root` (skipping VCS / dependency / build dirs) and return
a flat, sorted list of file paths relative to `root` — the searchable project
file index. `timeout` is generous: a first scan of a large tree can take seconds.
"""
function list_worker_project_files(state::ServerState, worker_name::String,
                                   root::AbstractString; timeout::Real = 20.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")

    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict(
            "type"       => "list_project_files",
            "request_id" => rid,
            "path"       => String(root),
        ))
        take_pending!(state, ch, rid, timeout, "list_project_files on '$worker_name'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("list_project_files on '$worker_name': unexpected response shape")
    haskey(resp, "error") && error("list_project_files on '$worker_name': $(resp["error"])")
    return (path = String(resp["path"]),
            files = String[String(f) for f in get(resp, "files", Any[])],
            truncated = Bool(get(resp, "truncated", false)))
end

const PROJECT_INDEX_TTL = 60.0   # seconds — re-walk the worker tree if older

# Block-fetch the project file index into `proj.file_index`, replacing the cache.
# Runs inside the shared single-flight task (see `ensure_project_file_index!`).
function refresh_project_file_index!(state::ServerState, proj::ProjectInfo)
    idx = proj.file_index
    try
        res = list_worker_project_files(state, proj.worker_id, proj.worker_path)
        lock(idx.lock) do
            idx.files     = res.files
            idx.truncated = res.truncated
            idx.loaded_at = now(UTC)
        end
    catch e
        @warn "project file index refresh failed" project=proj.id exception=e
        # Record the attempt so a dead worker isn't re-walked on every keystroke;
        # keep whatever files we already had.
        lock(idx.lock) do
            idx.loaded_at = now(UTC)
        end
    end
    return nothing
end

"""
    ensure_project_file_index!(state, proj; ttl=PROJECT_INDEX_TTL, force=false) -> Task | nothing

Single-flight refresh of `proj`'s file index. Returns the in-flight (or freshly
started) refresh `Task` when the cache is missing/stale/forced — concurrent
callers share that one walk and may `wait` on it — or `nothing` when the cache is
already fresh (use [`project_index_files`](@ref) directly).
"""
function ensure_project_file_index!(state::ServerState, proj::ProjectInfo;
                                    ttl::Real = PROJECT_INDEX_TTL, force::Bool = false)
    idx = proj.file_index
    return lock(idx.lock) do
        if idx.refresh_task !== nothing && !istaskdone(idx.refresh_task)
            return idx.refresh_task                    # a walk is already running
        end
        age = idx.loaded_at === nothing ? Inf :
              (now(UTC) - idx.loaded_at).value / 1000
        if force || age > ttl
            idx.refresh_task = @async refresh_project_file_index!(state, proj)
            return idx.refresh_task
        end
        return nothing                                 # cache is fresh
    end
end

# Snapshot of the cached index (a copy, so callers can't mutate the shared vec).
project_index_files(proj::ProjectInfo) = lock(proj.file_index.lock) do
    copy(proj.file_index.files)
end

"""
    inspect_worker_path(state, worker_name, path; timeout=30.0) -> Dict

Ask the worker for a "what's in this directory" summary used by the
collision-aware import flow: file count, total bytes, latest mtime,
top-N most-recently-modified files, and a per-subrepo git block.
Path must exist and be a directory on the worker. Raises on missing
worker / timeout / worker-side error.

Returned dict shape:

    Dict("total_files"  => Int,
         "total_bytes"  => Int,
         "latest_mtime" => Float64,       # Unix seconds
         "recent_files" => Vector{Dict},  # {path,size,mtime}
         "git_subrepos" => Vector{Dict})  # {path,head_sha,head_time,
                                          #  dirty_count,branch}
"""
function inspect_worker_path(state::ServerState, worker_name::String,
                              path::AbstractString;
                              timeout::Real = 30.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict(
            "type"       => "inspect_path",
            "request_id" => rid,
            "path"       => String(path),
        ))
        take_pending!(state, ch, rid, timeout, "inspect_path on '$worker_name'")
    finally
        unregister_rpc!(state, rid)   # T10
    end
    resp isa AbstractDict || error("inspect_path: unexpected response shape")
    haskey(resp, "error") && error("inspect_path on '$worker_name': $(resp["error"])")
    summary = get(resp, "summary", nothing)
    summary isa AbstractDict || error("inspect_path: missing summary")
    return Dict{String,Any}(summary)
end

# Stream a worker file from byte `offset`. Returns the new chunk + offset and
# whether the file is still held open (the background-task "still running"
# signal — see the worker's `file_held_open`). `open_known=false` means the
# worker couldn't tell (non-Linux) and the caller should fall back to mtime.
function tail_worker_file(state::ServerState, worker_id::AbstractString,
                           path::AbstractString; offset::Int = 0,
                           max_bytes::Int = 65536, timeout::Real = 15.0)
    worker_connected(state, worker_id) ||
        error("Worker '$worker_id' is not connected")
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict(
            "type" => "tail_file", "request_id" => rid,
            "path" => String(path), "offset" => offset, "max_bytes" => max_bytes))
        take_pending!(state, ch, rid, timeout, "tail_file on '$worker_id'")
    finally
        unregister_rpc!(state, rid)   # T10
    end
    resp isa AbstractDict || error("tail_file: unexpected response shape")
    haskey(resp, "error") && error("tail_file on '$worker_id': $(resp["error"])")
    return (exists     = Bool(get(resp, "exists", false)),
            offset     = Int(get(resp, "offset", offset)),
            chunk      = String(get(resp, "chunk", "")),
            open       = Bool(get(resp, "open", true)),
            open_known = Bool(get(resp, "open_known", false)),
            mtime      = Float64(get(resp, "mtime", 0.0)))
end

# SIGTERM every process holding `path` open on the worker — the direct stop
# for a background shell (the SDK gives no ACP kill primitive, but the shell
# keeps its `>> output` redirect open until it exits). Returns the killed
# pids; `supported=false` on a non-Linux worker. Best-effort: errors are
# returned, not thrown, so the caller can still finalize the UI.
function kill_worker_file_writers(state::ServerState, worker_id::AbstractString,
                                   path::AbstractString; timeout::Real = 10.0)
    worker_connected(state, worker_id) ||
        error("Worker '$worker_id' is not connected")
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict(
            "type" => "kill_file_writers", "request_id" => rid, "path" => String(path)))
        take_pending!(state, ch, rid, timeout, "kill_file_writers on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("kill_file_writers: unexpected response shape")
    haskey(resp, "error") && error("kill_file_writers on '$worker_id': $(resp["error"])")
    return (killed    = Int.(get(resp, "killed", Int[])),
            supported = Bool(get(resp, "supported", false)))
end

# Is a project's `worker_path` DEFINITIVELY gone on a connected worker? True only
# when the worker explicitly reports the path isn't a directory; a timeout /
# disconnect / any other error is UNCERTAIN → false. We never prune on doubt —
# that would delete a perfectly valid project.
function worker_path_missing(state::ServerState, worker_id::AbstractString,
                              path::AbstractString)::Bool
    worker_connected(state, worker_id) || return false
    try
        inspect_worker_path(state, worker_id, path; timeout = 10.0)
        return false                       # path exists
    catch e
        msg = sprint(showerror, e)
        return occursin("not a directory", msg) || occursin("path is empty", msg)
    end
end

# Drop this worker's registered projects whose `worker_path` no longer exists
# (e.g. `/tmp/jl_*` scratch dirs cleared on reboot). Conservative: only
# definitively-missing paths, and never an in-use (locked) project. Returns the
# number pruned. Runs the inspect round-trips serially — fine off the hot path.
function prune_missing_projects!(state::ServerState, worker_id::AbstractString)
    # Snapshot candidates under the lock (T14) so we don't iterate
    # `state.projects[]` while a locked writer rehashes it.
    candidates = lock(state.lock) do
        [(id, p.worker_path) for (id, p) in state.projects[]
         if p.worker_id == worker_id && p.locked_by === nothing]
    end
    dead = String[]
    for (id, wp) in candidates
        worker_path_missing(state, worker_id, wp) && push!(dead, id)
    end
    isempty(dead) && return 0
    lock(state.lock) do
        for id in dead
            haskey(state.projects[], id) && delete!(state.projects[], id)
            # The review state is keyed by project id and holds pending comments.
            # Leaving it behind would hand a future project that reuses the id
            # someone else's half-written review.
            delete!(state.review_states, id)
        end
        save_projects!(state)
    end
    notify_projects!(state)
    @info "pruned project(s) with missing worker paths" worker = worker_id count = length(dead) ids = dead
    return length(dead)
end

"""
    scan_worker_sessions(state, worker_name; timeout=15.0) → Vector{Dict{String,Any}}

Ask the named worker to scan for existing Claude Code sessions (running processes
+ ~/.claude/projects/ history) and return the results. Blocks until the worker
replies or `timeout` seconds elapse.
"""
function scan_worker_sessions(state::ServerState, worker_name::String;
                                timeout::Real = 15.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_name, Dict("type" => "scan_sessions", "request_id" => rid))
        take_pending!(state, ch, rid, timeout, "scan_sessions on '$worker_name'")
    finally
        unregister_rpc!(state, rid)   # T10
    end
    return resp isa AbstractVector ? resp : Dict{String,Any}[]
end

"""
    scan_and_store!(state, worker_id) -> Vector{Dict}

Scan a worker for Claude Code sessions and persist the result into
`state.discovered[worker_id]` (→ `discovered.json`), then notify so the
dashboard's folder→threads browser updates. A scan error is stored as a
single `{"error" => …}` entry (the panel surfaces it) rather than thrown, so
this is safe to call from a connect handler or a Rescan click. Returns the
stored vector.
"""
function scan_and_store!(state::ServerState, worker_id::AbstractString)
    wid = String(worker_id)
    raw = try
        scan_worker_sessions(state, wid)
    catch e
        Any[Dict{String,Any}("error" => sprint(showerror, e))]
    end
    norm = Dict{String,Any}[Dict{String,Any}(r) for r in raw]
    lock(state.lock) do
        state.discovered[][wid] = norm
        state.last_scan[wid] = time()
        save_discovered!(state)
    end
    safe_notify!(state.discovered)
    # Opportunistic title-repair sweep: re-derive titles for this worker's
    # projects whose saved title leaks an injected wrapper (a pre-fix
    # `meaningful_title` would let `<ide_selection>…` or `<command-args
    # foo="bar">…` through). Bounded to projects on THIS worker so a Rescan
    # click doesn't churn unrelated state. See `refresh_broken_titles!`.
    refresh_broken_titles!(state, wid)
    return norm
end

# A title is "broken" if the current `meaningful_title` would change it —
# either reject it outright (wrapper-only blob ⇒ `nothing`) or return a
# different cleaned string (wrapper + prose where the wrapper part leaked
# through the older regex). Clean titles round-trip to themselves and the
# sweep ignores them.
function title_is_broken(provider::AgentProvider, t::AbstractString)
    s = String(t)
    cleaned = meaningful_title(provider, s)
    return cleaned === nothing || String(cleaned) != s
end

"""
    refresh_broken_titles!(state, worker_id) -> Int

Re-derive `p.title` for every project on `worker_id` whose saved title would
change under the current `meaningful_title` (wrapper leakage from an older
filter). For each broken title we try the original prompt from `chat.md`
first — that's almost always the best source. If chat.md is missing or its
first prompt also reduces to nothing, we fall back to the cleaned version
of the saved title; that's still better than leaving the leak.

Returns the number of titles touched. Idempotent — running it twice on the
same state is a no-op the second time.
"""
function refresh_broken_titles!(state::ServerState, worker_id::AbstractString)
    wid = String(worker_id)
    # Decide under the lock, write outside it: each title write runs the hook
    # (projects.json + a notify to every tab), which has no business inside
    # the table lock.
    repairs = lock(state.lock) do
        out = Pair{ProjectInfo,String}[]
        for (pid, p) in state.projects[]
            p.worker_id == wid || continue
            # The wrappers to peel are the ones of the agent that WROTE the
            # title, so ask the project. A project that predates the field says
            # nothing and resolves to the default — which is Claude, the
            # assumption this used to hardcode for every project alike.
            provider = project_provider(p)
            # A chat still on its default (the folder name) was never titled by
            # a prompt, so there is no wrapper to peel — whatever the filter
            # would make of the folder name.
            titled(p) || continue
            title_is_broken(provider, p.title[]) || continue
            # Prefer the original prompt — re-running the filter against the
            # raw first user message recovers any prose the old truncation
            # dropped on the floor.
            chat_dir = chat_storage_dir(state, pid, p.server_path)
            raw = first_user_prompt(chat_dir)
            new_title = raw === nothing ? nothing : meaningful_title(provider, raw)
            # Fall back to cleaning the saved title in place — strictly an
            # improvement over the leaked form even when chat.md isn't
            # available (cwd moved, project imported, …).
            new_title === nothing && (new_title = meaningful_title(provider, p.title[]))
            # Nothing usable anywhere: back to the default, so the next real
            # prompt can title it cleanly.
            push!(out, p => (new_title === nothing ? default_title(p) : String(new_title)))
        end
        out
    end
    for (p, t) in repairs
        p.title[] = t
    end
    isempty(repairs) ||
        @info "refresh_broken_titles!: repaired $(length(repairs)) project title(s)" worker_id=wid
    return length(repairs)
end

"""
    clone_repo_on_worker(state, worker_name, url, dst_path;
                          pr_number = nothing, timeout = 120.0)

Ask the named worker to `git clone <url>` into `dst_path` (a path on the
worker, must not exist yet). For PRs, also fetches `pull/<n>/head` and
checks it out as `pr-<n>`. Throws on timeout or worker-reported errors.
"""
function clone_repo_on_worker(state::ServerState, worker_name::String,
                                url::AbstractString, dst_path::AbstractString;
                                pr_number::Union{Integer,Nothing} = nothing,
                                timeout::Real = 120.0)
    worker_connected(state, worker_name) ||
        error("Worker '$worker_name' is not connected")
    rid, ch = register_rpc!(state)

    payload = Dict{String,Any}(
        "type"       => "clone_repo",
        "request_id" => rid,
        "url"        => String(url),
        "dst_path"   => String(dst_path),
    )
    pr_number === nothing || (payload["pr_number"] = Int(pr_number))
    resp = try
        send_command(state, worker_name, payload)
        take_pending!(state, ch, rid, timeout, "clone_repo on '$worker_name'")
    finally
        unregister_rpc!(state, rid)   # T10
    end
    resp isa AbstractDict || error("clone_repo '$url' on '$worker_name': unexpected response")
    haskey(resp, "error") &&
        error("clone_repo '$url' on '$worker_name': $(resp["error"])")
    return String(resp["dst_path"])
end

"""
    worker_state(state, worker_id; timeout = 15.0) -> Dict

Ask a worker to describe ITSELF: pid, uptime, memory, the agent binary it
resolves, and its live agent sessions (with whether each agent process is still
running and whether its ACP socket is up). The other half of the debug chat's
picture — the server knows what it *asked* the worker to do, this is what the
worker actually has.
"""
function worker_state(state::ServerState, worker_id::AbstractString; timeout::Real = 15.0)
    worker_connected(state, worker_id) ||
        throw(WorkerUnreachableError("worker_state on '$worker_id'", "worker is not connected"))
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict("type" => "worker_state", "request_id" => rid))
        take_pending!(state, ch, rid, timeout, "worker_state on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("worker_state on '$worker_id': unexpected response shape")
    haskey(resp, "error") && error(String(resp["error"]))
    return Dict{String,Any}(resp)
end

# Is an agent turn running in any chat on this worker? Only the server knows:
# the worker sees agent processes, which exist for every open chat, busy or not.
function worker_turn_in_flight(state::ServerState, worker_id::AbstractString)
    models = lock(state.lock) do
        ChatModel[m for (pid, m) in state.chat_models
                  if (p = get(state.projects[], pid, nothing)) !== nothing &&
                     p.worker_id == worker_id]
    end
    return any(m -> m.busy_active[], models)
end

# "Update now" means now. The worker is told to install immediately, cutting its
# idle agent processes (their chats respawn them on the next message); a turn
# in flight is the one thing we refuse to cut. The card's state flips to
# `:updating` here and back to `:current` when the replacement worker's hello
# arrives, so the button's feedback is the worker's real state, not a banner.
function force_worker_update!(state::ServerState, worker_id::AbstractString)
    wid = String(worker_id)
    worker_connected(state, wid) ||
        throw(WorkerUnreachableError("force update", "worker is not connected"))
    worker_turn_in_flight(state, wid) &&
        throw(ArgumentError("a chat on this worker is mid-turn; let it finish or stop it, then update"))
    send_command(state, wid, Dict("type" => "force_update", "immediate" => true,
                                  "update_spec" => current_worker_update_spec()))
    # Interim wording: the worker's own `update_status` frame replaces it within
    # a moment. A worker predating that frame never sends one, so this stays,
    # and stays true.
    set_worker_update!(state, wid, :updating, "Update requested; waiting for the worker to confirm.")
    return nothing
end

function set_worker_update!(state::ServerState, worker_id::AbstractString, st::Symbol, msg::AbstractString)
    found = lock(state.lock) do
        w = get(state.workers[], String(worker_id), nothing)
        w === nothing && return false
        w.update_state = st
        w.update_message = String(msg)
        true
    end
    found && notify_workers!(state)
    return found
end

# The worker's account of a requested update (`update_status` frame): what the
# card shows from here on is the worker's state, not our guess.
function apply_update_status!(state::ServerState, worker_id::AbstractString, cmd::AbstractDict)
    status = String(get(cmd, "status", ""))
    err    = String(get(cmd, "error", ""))
    st, msg = if status == "installing"
        (:updating, "Updating: the worker installs the server's build, then restarts and reconnects by itself. Its chats rebind on their next message.")
    elseif status == "waiting"
        (:updating, "Update requested; this worker installs it once no chat runs on it.")
    elseif status == "failed"
        (:available, "The update failed on the worker: $(rstrip(err, '.')). It retries in five minutes; see the worker's log.")
    elseif status == "unsupported"
        (:reinstall, "This worker cannot update itself: $(rstrip(err, '.')). Reinstall it with the install command.")
    else
        @warn "Worker update_status: unknown status" worker_id status
        return false
    end
    return set_worker_update!(state, worker_id, st, msg)
end

"""
    worker_log(state, worker_id; lines, since, until, grep, timeout = 45.0) -> Dict

That worker's own log file, read ON the worker and returned whole.

Unlike most worker RPCs this does NOT throw when the worker cannot answer the
question — a worker that never started a log file answers `ok = false` with the
reason, because the point of this call is a fan-out across a fleet where a
refusal from one machine must not lose the other five. It still throws when the
worker is UNREACHABLE, which is a different fact.
"""
function worker_log(state::ServerState, worker_id::AbstractString;
                        lines::Integer = 200, since::AbstractString = "",
                        until::AbstractString = "", grep::AbstractString = "",
                        timeout::Real = 45.0)
    worker_connected(state, worker_id) ||
        throw(WorkerUnreachableError("worker_log on '$worker_id'", "worker is not connected"))
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict("type" => "read_log", "request_id" => rid,
                                            "lines" => Int(lines), "since" => String(since),
                                            "until" => String(until), "grep" => String(grep)))
        take_pending!(state, ch, rid, timeout, "worker_log on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("worker_log on '$worker_id': unexpected response shape")
    return Dict{String,Any}(resp)
end

"""
    debug_checkout_on_worker(state, worker_id; repo, rev, packages, timeout = 900.0)
        -> path

Ask a worker for a BonitoAgents source checkout of its own and return where it
is — a path on the WORKER. That is the checkout it already runs from (a dev
install), or else a clone of `repo` at `rev` under its environment's `dev/`
with `packages` (the monorepo packages the installer put in that environment)
developed from it: `dev --local`, done for the user, so a worker restart runs
what gets edited there.

The timeout covers a first clone plus the precompile that follows the develop;
a repeat call finds the checkout in place and returns in seconds.
"""
function debug_checkout_on_worker(state::ServerState, worker_id::AbstractString;
                                  repo::AbstractString, rev::AbstractString,
                                  packages::Vector{String}, timeout::Real = 900.0)
    worker_connected(state, worker_id) ||
        throw(WorkerUnreachableError("debug_checkout on '$worker_id'", "worker is not connected"))
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, String(worker_id), Dict{String,Any}(
            "type"       => "debug_checkout",
            "request_id" => rid,
            "repo"       => String(repo),
            "rev"        => String(rev),
            "packages"   => packages))
        take_pending!(state, ch, rid, timeout, "debug_checkout on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("debug_checkout on '$worker_id': unexpected response shape")
    haskey(resp, "error") && error("debug_checkout on '$worker_id': $(resp["error"])")
    path = String(resp["path"])
    @info "debug checkout ready on worker" worker_id path mode = get(resp, "mode", "") created = get(resp, "created", false)
    return path
end

# One request/response round trip for the session-state RPCs below: send
# `{type, request_id, fields...}`, wait for the worker's reply, and turn a reply
# that carries `error` into a thrown error naming the RPC and the worker.
function worker_rpc(state::ServerState, worker_id::AbstractString, kind::AbstractString,
                    fields::AbstractDict; timeout::Real)
    what = "$(kind) on '$(worker_id)'"
    worker_connected(state, worker_id) ||
        throw(WorkerUnreachableError(what, "worker is not connected"))
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, String(worker_id),
                     merge(Dict{String,Any}("type" => kind, "request_id" => rid), fields))
        take_pending!(state, ch, rid, timeout, what)
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("$(what): unexpected response shape")
    haskey(resp, "error") && error("$(what): $(resp["error"])")
    return resp
end

"""
    stage_session_on_worker(state, worker_id; provider, cwd, session_id, staging)
        -> (path, entries, bytes)

Ask the worker to copy the agent's record of `session_id` (run by `provider` in
`cwd`) into `staging`, a directory under its projects root's
`TRANSFER_DIRNAME`, ready to be pulled with `sync_dir_from_worker!`. Errors when
there is no transcript to carry. First leg of "continue this chat on another
worker" — see `carry_session!`.
"""
function stage_session_on_worker(state::ServerState, worker_id::AbstractString;
                                 provider::AbstractString, cwd::AbstractString,
                                 session_id::AbstractString, staging::AbstractString,
                                 timeout::Real = 300.0)
    resp = worker_rpc(state, worker_id, "stage_session", Dict{String,Any}(
        "provider" => String(provider), "cwd" => String(cwd),
        "session_id" => String(session_id), "staging" => String(staging)); timeout)
    return (path = String(resp["path"]),
            entries = String[String(e) for e in get(resp, "entries", Any[])],
            bytes = Int(get(resp, "bytes", 0)))
end

"""
    install_session_on_worker(state, worker_id; provider, cwd, old_cwd, session_id, staging)
        -> path

Ask the worker to move the session record pushed into `staging` into the
transcript directory for `cwd`, rewriting the working directory it records from
`old_cwd`. Returns that directory. Last leg of `carry_session!`.
"""
function install_session_on_worker(state::ServerState, worker_id::AbstractString;
                                   provider::AbstractString, cwd::AbstractString,
                                   old_cwd::AbstractString, session_id::AbstractString,
                                   staging::AbstractString, timeout::Real = 300.0)
    resp = worker_rpc(state, worker_id, "install_session", Dict{String,Any}(
        "provider" => String(provider), "cwd" => String(cwd), "old_cwd" => String(old_cwd),
        "session_id" => String(session_id), "staging" => String(staging)); timeout)
    return String(resp["path"])
end

"""
    discard_staging_on_worker(state, worker_id; staging)

Remove a staging directory `stage_session_on_worker` left on the worker.
"""
function discard_staging_on_worker(state::ServerState, worker_id::AbstractString;
                                   staging::AbstractString, timeout::Real = 60.0)
    worker_rpc(state, worker_id, "discard_staging",
               Dict{String,Any}("staging" => String(staging)); timeout)
    return nothing
end

"""
    open_eval_host_on_worker(state, worker_id; project_id, env) -> (pid, existed)

Ask the worker to spawn (or confirm) the BonitoMCP eval host serving
`project_id`'s chat from that machine, with `env` (the project id) in the
process environment. The host connects through that worker's relay on its own;
`ensure_eval_host!` (remote_eval.jl) waits for that.
"""
function open_eval_host_on_worker(state::ServerState, worker_id::AbstractString;
                                  project_id::AbstractString, env::AbstractDict,
                                  timeout::Real = 60.0)
    resp = worker_rpc(state, worker_id, "open_eval_host", Dict{String,Any}(
        "project_id" => String(project_id),
        "env" => Dict{String,String}(String(k) => String(v) for (k, v) in env)); timeout)
    return (pid = Int(get(resp, "pid", 0)), existed = get(resp, "existed", false) === true)
end

"""
    close_eval_host_on_worker(state, worker_id; project_id) -> Bool

Kill the eval host the worker runs for `project_id`. `false` when there was none.
"""
function close_eval_host_on_worker(state::ServerState, worker_id::AbstractString;
                                   project_id::AbstractString, timeout::Real = 30.0)
    resp = worker_rpc(state, worker_id, "close_eval_host",
                      Dict{String,Any}("project_id" => String(project_id)); timeout)
    return get(resp, "killed", false) === true
end

"""
    git_diff_on_worker(state, worker_id, path; base = "", timeout = 60.0)
        -> (repo, branch, head, base, patch)

Ask the worker for one unified diff of the git repository containing `path` —
what the change-review tab shows. `base` empty means the working tree against
`HEAD` (everything uncommitted, which is what an agent's turn produces);
otherwise it's the working tree against that ref. Untracked files are included
as synthetic "new file" sections, so files the agent CREATED are reviewable too.

The patch comes back as raw text (transport: chunked as `git_diff_chunk`
frames, so no single control frame ever carries the whole multi-MB patch) and
is parsed by [`parse_unified_diff`](@ref) here on the server. `timeout` is
generous: a first diff of a big repo (cold page cache, thousands of files)
can take a while.
"""
function git_diff_on_worker(state::ServerState, worker_id::AbstractString,
                            path::AbstractString; base::AbstractString = "",
                            timeout::Real = 60.0)
    worker_connected(state, worker_id) ||
        throw(WorkerUnreachableError("git_diff on '$worker_id'", "worker is not connected"))
    # Chunked reply, not one-frame: the patch runs to tens of MB on a busy
    # repo, and a single giant frame stalls BOTH sides (the worker's send holds
    # the ws send lock while its inline pong queues behind it; the server's
    # inline decode falls behind its heartbeat). register_chunked_rpc! +
    # deliver_chunk! reassemble the same value take_pending! returns here.
    rid, ch = register_chunked_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict(
            "type" => "git_diff", "request_id" => rid,
            "path" => String(path), "base" => String(base)))
        take_pending!(state, ch, rid, timeout, "git_diff on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("git_diff on '$worker_id': unexpected response shape")
    haskey(resp, "error") && error(String(resp["error"]))
    return (repo   = String(get(resp, "repo", "")),
            branch = String(get(resp, "branch", "")),
            head   = String(get(resp, "head", "")),
            base   = String(get(resp, "base", "")),
            # "" when the project IS the repo root; otherwise the sub-path the
            # diff was limited to.
            scope  = String(get(resp, "scope", "")),
            patch  = String(get(resp, "patch", "")))
end

"""
    find_repos_on_worker(state, worker_id, path; max_depth = 4, timeout = 15.0)
        -> (repos, truncated, unreadable)

The git checkouts at or under `path` **on the worker**, for the review tab's
folder picker. A project folder is routinely a workspace holding several
checkouts rather than being one itself, and the server cannot answer this by
looking at its own filesystem.

`timeout` is short on purpose. This runs while a tab is opening and the answer
is a convenience — the picker still works from the project folder alone if the
scan is slow or the worker is busy, so waiting a minute for it would trade the
thing the user asked for against the thing they can already do.
"""
function find_repos_on_worker(state::ServerState, worker_id::AbstractString,
                              path::AbstractString; max_depth::Int = 4,
                              timeout::Real = 15.0)
    worker_connected(state, worker_id) ||
        throw(WorkerUnreachableError("find_repos on '$worker_id'", "worker is not connected"))
    rid, ch = register_rpc!(state)
    resp = try
        send_command(state, worker_id, Dict(
            "type" => "find_repos", "request_id" => rid,
            "path" => String(path), "max_depth" => max_depth))
        take_pending!(state, ch, rid, timeout, "find_repos on '$worker_id'")
    finally
        unregister_rpc!(state, rid)
    end
    resp isa AbstractDict || error("find_repos on '$worker_id': unexpected response shape")
    haskey(resp, "error") && error(String(resp["error"]))
    repos = String[String(p) for p in get(resp, "repos", [])]
    return (repos      = repos,
            truncated  = get(resp, "truncated", false) === true,
            unreadable = Int(get(resp, "unreadable", 0)))
end

"""
    fetch_file_from_worker(state, worker_name, src_path, dst_path;
                            handoff_timeout = 15.0, on_progress = nothing)

Stream a single file from the named worker into `dst_path` on the server.
A transfer channel like directory sync's, but with direction
`"file_from_worker"` and `RemoteSync.send_file`/`receive_file` for
chunked, memory-bounded transfer. No size cap.

Used by the chat UI's bt_show preview renderer when the file isn't in
`<server_path>/<relpath>` yet (e.g. unsynced project, or a fresh tool
result before the file gets RemoteSync'd as part of a project sync).
"""
function fetch_file_from_worker(state::ServerState, worker_name::String,
                                  src_path::AbstractString,
                                  dst_path::AbstractString;
                                  handoff_timeout::Real = 15.0,
                                  on_progress = nothing)
    ch = transfer_channel(state, worker_name, Dict(
        "direction" => "file_from_worker",
        "src_path"  => String(src_path)); timeout = handoff_timeout)
    try
        RemoteSync.receive_file(String(dst_path), RemoteSync.WebSocketIO(ch); on_progress)
    finally
        close(ch)
    end
    return String(dst_path)
end

"""
    send_file_to_worker!(state, worker_name, src_path, dst_path;
                          handoff_timeout = 15.0, on_progress = nothing)

Inverse of `fetch_file_from_worker`: push a single file from the
server-side `src_path` to the worker-side `dst_path`. No directory
walking — used when only one file changed (image paste, single tool
output, Julia eval artifact) and a full project sync would be
overkill on a large project tree.

Worker writes the bytes via `RemoteSync.receive_file`, which writes
straight to disk in bounded chunks (memory-safe regardless of size)
and creates any missing parent directories.
"""
function send_file_to_worker!(state::ServerState, worker_name::String,
                                src_path::AbstractString,
                                dst_path::AbstractString;
                                handoff_timeout::Real = 15.0,
                                on_progress = nothing)
    isfile(src_path) || error("Source path is not a file: $src_path")
    ch = transfer_channel(state, worker_name, Dict(
        "direction" => "file_to_worker",
        "dst_path"  => String(dst_path)); timeout = handoff_timeout)
    try
        wsio = RemoteSync.WebSocketIO(ch)
        RemoteSync.send_file(String(src_path), wsio; on_progress)
        # The worker closes once the file is on its disk: returning after that
        # means the file is there.
        RemoteSync.wait_peer_close(wsio)
    finally
        close(ch)
    end
    return String(dst_path)
end

# NOTE: WS-backed ACP I/O now lives in `WorkerTransport` (src/transport.jl)
# as `AgentClientProtocol.send` / `recv` and `Base.close` overloads — the
# Connection talks to the transport via dispatched verbs, not callbacks.
