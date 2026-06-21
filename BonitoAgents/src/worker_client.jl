# Server-side handlers for inbound worker connections. Workers dial the
# server; the server tracks each worker's "control" WS and pairs per-session
# ACP WSs with the right project.
#
# Endpoints (registered as Bonito websocket_route!s):
#   /worker-ws    → control channel. Worker sends a hello frame; we register
#                   it in state.workers, mark online, and keep the WS for
#                   sending commands like "open_session" / "open_transfer".
#   /worker-acp   → per-session WS. Worker dials this in response to an
#                   "open_session" command and identifies the WS by sid; we
#                   pair it with a Channel that `start!(::WorkerAgent)` is
#                   blocked on.
#   /transfer-ws  → directional librsync transfer; worker dials this in
#                   response to an "open_transfer" command; pairs the WS
#                   with whichever sync_dir_*_worker! call is waiting.

using HTTP, HTTP.WebSockets, JSON, AgentClientProtocol, RemoteSync

# All worker-related state lives on `state::ServerState`:
#   state.worker_control_ws — name → live HTTP.WebSocket
#   state.pending_rpcs      — request_id/sync_id/sid → Channel{Any}
#                              one dict for every RPC type (list_dir, scan_sessions,
#                              clone_repo, /transfer-ws handoff, /worker-acp handoff).
#                              The keys are uuids so collisions across types can't
#                              happen, and the unified shape is simpler than the
#                              previous five typed dicts.

# Send a JSON command to a worker over its control WS. Throws if the worker
# isn't currently connected.
function send_command(state::ServerState, worker_name::String, payload::AbstractDict)
    # Snapshot the socket under the lock (T14): `haskey` then index unlocked
    # raced `teardown_worker_control!`/`remove_worker!` deleting the entry — a
    # raw KeyError in the middle of a UI handler. One locked lookup decides.
    ws = lock(state.lock) do
        get(state.worker_control_ws, worker_name, nothing)
    end
    ws === nothing && error("Worker '$worker_name' is not connected")
    WebSockets.send(ws, JSON.json(payload))
    return nothing
end

# Push a JSON error frame to a peer whose request we just rejected
# (unauthorized / missing id / unknown id). The peer may have hung up
# before reading the response — that's the state we were going to leave
# them in anyway, so an IOError / WebSocketError during the send is
# expected and silently ignored. Anything else propagates.
function send_ws_error(ws, payload::AbstractDict)
    try
        WebSockets.send(ws, JSON.json(payload))
    catch e
        e isa Union{Base.IOError, HTTP.WebSockets.WebSocketError} || rethrow()
    end
    return nothing
end

# Close a worker-side WebSocket that may have been torn down concurrently
# by the peer (worker reboot, network drop, normal end-of-transfer cleanup).
# A closed-WS exception during the close means the resource is already in
# the state we wanted — silently ignored. Anything else propagates.
function close_ws_safe(ws)
    HTTP.WebSockets.isclosed(ws) && return nothing
    try
        close(ws)
    catch e
        e isa Union{Base.IOError, HTTP.WebSockets.WebSocketError} || rethrow()
    end
    return nothing
end

# Register a pending RPC: returns (request_id, channel). Caller sends the
# command (with `request_id`/`sync_id`/`sid` set to the returned id) and waits
# on the channel via `take_pending!`. The matching control-frame handler /
# WS upgrade pops the id out of `pending_rpcs` and puts the response on the
# channel.
function register_rpc!(state::ServerState)
    rid = string(uuid4())
    ch  = Channel{Any}(1)
    lock(state.lock) do
        state.pending_rpcs[rid] = ch
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
        haskey(state.pending_rpcs, String(key)) && delete!(state.pending_rpcs, String(key))
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
        # deliver_rpc_response! popping the same key.
        had = lock(state.lock) do
            if haskey(state.pending_rpcs, key)
                delete!(state.pending_rpcs, key)
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
    val === nothing && error("$op_name timed out after $(timeout)s — worker may be offline or stuck")
    # M9/M13: the worker can report a definitive failure (e.g. open_session_failed)
    # by delivering an Exception, so we fail fast instead of waiting out the timeout.
    val isa Exception && throw(val)
    return val
end

# Try to deliver a worker-pushed RPC reply by request_id. No-op if the id is
# unknown (caller already timed out, or the response races a re-registration).
function deliver_rpc_response!(state::ServerState, rid::AbstractString, value)
    ch = lock(state.lock) do
        haskey(state.pending_rpcs, rid) ? pop!(state.pending_rpcs, rid) : nothing
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

# Fail a pending RPC: deliver an Exception so `take_pending!` rethrows it (M9).
# Used when the worker reports a definitive failure for a registered operation
# (e.g. `open_session_failed`) instead of dialing back.
function deliver_rpc_error!(state::ServerState, rid::AbstractString, message::AbstractString)
    deliver_rpc_response!(state, rid, ErrorException(message))
    return
end

# Handler for /worker-ws — runs once per worker, for the worker's lifetime.
function handle_worker_control(state::ServerState, ws)
    worker_id = "?"
    try
        hello_raw = WebSockets.receive(ws)
        hello = JSON.parse(String(hello_raw))
        if get(hello, "secret", "") != state.worker_secret
            send_ws_error(ws, Dict("ok"=>false, "error"=>"unauthorized"))
            return
        end
        # Worker identity. Newer workers send `worker_id` (stable UUID); old
        # ones (and the migration pass for an existing install) only have
        # `name`. Fall back so legacy workers keep working — the dict key
        # is just a string either way.
        name      = String(get(hello, "name", get(hello, "hostname", "anon")))
        worker_id = String(get(hello, "worker_id", name))

        # If the user previously renamed this worker via the UI, preserve
        # that name across reconnects instead of overwriting it with the
        # worker's hello-frame default.
        existing_name = haskey(state.workers[], worker_id) ?
                        state.workers[][worker_id].name : nothing
        display_name  = existing_name === nothing ? name : existing_name

        WebSockets.send(ws, JSON.json(Dict("ok" => true,
                                            "registered_as" => display_name,
                                            "worker_id"     => worker_id)))

        # Build / refresh the WorkerInfo from the hello frame. Preserve a
        # user-set `initials` override across reconnects (the worker doesn't
        # know about it; it lives entirely on the server side).
        prev_initials = let existing = get(state.workers[], worker_id, nothing)
            existing === nothing ? nothing : existing.initials
        end
        w = WorkerInfo(
            worker_id,
            display_name,
            prev_initials,
            "<inbound-ws>",          # we no longer dial the worker; URL is moot
            state.worker_secret,
            nothing,                 # ssh_target reserved for future rsync-over-ssh
            String(get(hello, "hostname", "")),
            String(get(hello, "home", "")),
            String(get(hello, "mcp_path", "")),
            Vector{String}(get(hello, "mcp_args", String[])),
            String(get(hello, "projects_root", "")),
            :online,
            now(UTC),
        )
        # All shared-state writes for this worker's registration go in one
        # critical section so the workers/worker_control_ws/projects tables
        # are mutually consistent across concurrent observers (other RPC
        # handlers, App-body re-renders).
        lock(state.lock) do
            state.workers[][worker_id] = w
            state.worker_control_ws[worker_id] = ws
            migrate_legacy_worker_refs!(state, w)
            save_workers!(state)
        end
        # Worker added → fan out to worker-cards consumers. If any
        # legacy projects had their worker_id rewritten by
        # migrate_legacy_worker_refs!, the project list also needs to
        # know (the project card shows the worker name and that lookup
        # was previously broken).
        safe_notify!(state.workers)
        safe_notify!(state.projects)
        @info "Worker connected" worker_id=worker_id name=display_name hostname=w.hostname

        # Reconcile this worker's projects against its filesystem: drop any whose
        # `worker_path` is gone (scratch dirs cleared on reboot). Async so the
        # inspect round-trips never block registration.
        Base.errormonitor(@async try
            prune_missing_projects!(state, worker_id)
        catch e
            @warn "prune_missing_projects! failed" worker = worker_id exception = e
        end)

        # Bring-up is LAZY: we no longer spawn a chat (claude process) for every
        # project the moment a worker connects. A chat starts only when the user
        # opens one of its threads (ensure_project_session! via the loading view
        # / dashboard), at which point it appears in the active-chats sidebar.
        # Eager bring-up meant N claude processes per worker on every reconnect
        # and made "active" meaningless.

        # Populate the persistent folder→threads browser on FIRST connect only
        # (if we have no cached scan for this worker yet). Subsequent refreshes
        # are explicit via the Rescan button — so "no need to click Discover
        # again" after the first time, and reconnects don't re-scan every time.
        if !haskey(state.discovered[], worker_id)
            @async try
                scan_and_store!(state, worker_id)
            catch e
                @warn "auto-scan on connect failed" worker_id=worker_id exception=e
            end
        end

        # Process inbound frames from the worker. Every typed reply maps
        # back to a pending RPC by request_id; deliver_rpc_response! is a
        # no-op if the id is unknown (caller already timed out).
        #
        # The `for frame in ws` iteration calls `receive(ws)` under the hood,
        # which THROWS (EOFError / IOError / WebSocketError) when the socket
        # drops abruptly — a worker kill, crash, or any ungraceful disconnect,
        # i.e. the common case. That throw escapes the per-frame try below (it
        # happens in the iterator, not the body), so without this guard every
        # worker disconnect dumps a stacktrace to the server console. Swallow
        # the benign close errors; the `finally` runs teardown either way.
        try
            for frame in ws
                try
                    cmd = JSON.parse(String(frame))
                    t   = get(cmd, "type", "")
                    rid = String(get(cmd, "request_id", ""))
                    if t == "list_dir_response"
                        deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                    elseif t == "scan_sessions_result"
                        sessions = [Dict{String,Any}(s)
                                    for s in get(cmd, "sessions", Any[])]
                        deliver_rpc_response!(state, rid, sessions)
                    elseif t == "clone_repo_response"
                        deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                    elseif t == "inspect_path_response"
                        deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                    elseif t == "tail_file_response"
                        deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                    elseif t == "kill_file_writers_response"
                        deliver_rpc_response!(state, rid, Dict{String,Any}(cmd))
                    elseif t == "open_session_failed"
                        # M9/M13: worker couldn't spawn/dial the ACP session; fail the
                        # pending open_session (keyed by `sid`) now instead of waiting
                        # out the 30s timeout in transport.jl.
                        sid = String(get(cmd, "sid", ""))
                        deliver_rpc_error!(state, sid,
                            String(get(cmd, "error", "worker failed to open ACP session")))
                    end
                catch e
                    @warn "Worker control frame error" exception=e
                end
            end
        catch e
            # Benign socket drop (worker killed/crashed/disconnected) — the
            # iterator raises these on EOF. A real error still surfaces.
            is_stale_session_error(e) ||
                @warn "Worker control loop ended" worker_id=worker_id exception=(e, catch_backtrace())
        end
    finally
        teardown_worker_control!(state, worker_id, ws)
    end
end

"""
    teardown_worker_control!(state, worker_id, ws) -> Bool

Tear down a worker's registration when its control socket closes — but ONLY if
`ws` is still the registered socket for `worker_id`. Returns `true` if it ran
the teardown, `false` if the connection was superseded.

Two connections can share a `worker_id`: a duplicate worker process, or a
reconnect that re-registered before this old socket's `finally` ran. The
registration map is last-writer-wins (`worker_control_ws[id] = ws` at connect),
so a stale connection dying must NOT delete the entry, flip the worker offline,
or evict its chat models — that would destroy the LIVE connection that replaced
it (the bug that made duplicate workers mutually destructive). The `=== ws`
identity check is the guard.
"""
function teardown_worker_control!(state::ServerState, worker_id::AbstractString, ws)
    affected = String[]
    evicted  = ChatModel[]
    is_current = lock(state.lock) do
        current = get(state.worker_control_ws, worker_id, nothing)
        current === ws || return false           # superseded — leave the live one alone
        delete!(state.worker_control_ws, worker_id)
        if haskey(state.workers[], worker_id)
            state.workers[][worker_id].status = :offline
        end
        for p in values(state.projects[])
            if p.worker_id == worker_id
                m = get(state.chat_models, p.id, nothing)
                m === nothing || push!(evicted, m)
                delete!(state.chat_models, p.id)
                push!(affected, p.id)
            end
        end
        return true
    end
    if is_current
        # CLOSE the evicted chat models — dropping them from `chat_models` is NOT
        # enough: each leaves a `run_chat!` consumer AND a 1 Hz background poller
        # alive (a running `poller_task` keeps the model referenced), leaking on every
        # worker disconnect. `close(model)` closes `user_messages`, ending both;
        # `stop!(agent)` tears down the (already-dead) worker ACP session. Outside
        # the lock — these signal tasks / do I/O.
        for m in evicted
            try; close(m); stop!(m.agent); catch e
                @warn "evicting chat model on worker disconnect" exception=e
            end
        end
        # The worker host is gone → its eval workers (and their bridges) are gone.
        # Tear them down explicitly outside the lock (close asset host is I/O); a
        # WS drop alone no longer does this — the bridge follows the worker session.
        for pid in affected
            teardown_eval_bridge!(state, pid)
        end
        safe_notify!(state.workers)
        notify_chats!(state)    # evicted chats drop out of the active-chats sidebar
        release_projects_for_worker!(state, worker_id)
        @info "Worker disconnected" worker_id=worker_id
    else
        @info "Worker control socket closed but superseded; keeping live registration" worker_id=worker_id
    end
    return is_current
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
    safe_notify!(state.workers)
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
    safe_notify!(state.workers)
    return state.workers[][worker_id]
end

# Project chat title — what `[WW] <title>` renders in the sidebar/card.
# Empty string clears the override (the UI falls back to `p.name`, the
# folder basename).
function set_project_title!(state::ServerState, project_id::AbstractString,
                            new_title::AbstractString)
    haskey(state.projects[], project_id) || error("Unknown project_id: $project_id")
    s = strip(String(new_title))
    state.projects[][project_id].title = isempty(s) ? nothing : String(s)
    save_projects!(state)
    safe_notify!(state.projects)
    return state.projects[][project_id]
end

"""
    remove_worker!(state, worker_id; remove_projects=true)

Forget a worker: drop it from `state.workers`, close and discard its
control WebSocket, and evict any cached `ChatModel`s for its projects. By
default its projects are also removed from the list (their server-side
chat history under `state_dir/chats/<id>/` is left on disk, so a later
re-import can still find it).

A worker whose process is still running will dial `/worker-ws` again and
re-register itself, so removal primarily targets decommissioned (offline)
workers; closing the control WS here just hangs up the current link.
"""
function remove_worker!(state::ServerState, worker_id::AbstractString;
                         remove_projects::Bool = true)
    wid = String(worker_id)
    ws, dropped, evicted, affected = lock(state.lock) do
        sock = get(state.worker_control_ws, wid, nothing)
        delete!(state.worker_control_ws, wid)
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
                push!(dropped, p.id)
            end
        end
        save_workers!(state)
        remove_projects && save_projects!(state)
        (sock, dropped, evicted, affected)
    end
    # Close evicted models so their consumer + background poller don't leak (see
    # teardown_worker_control!). Outside the lock — close()/stop! signal tasks.
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
    # Close the control WS outside the lock — it's network I/O, and closing it
    # ends the worker's `handle_worker_control` receive loop (its `finally`
    # teardown is idempotent against the eviction we just did).
    if ws !== nothing
        try
            close(ws)
        catch e
            @debug "remove_worker!: closing control WS failed" exception=e
        end
    end
    safe_notify!(state.workers)
    remove_projects && safe_notify!(state.projects)
    notify_chats!(state)        # evicted chats drop out of the active-chats sidebar
    @info "Worker removed" worker_id=wid removed_projects=length(dropped)
    return nothing
end

# Handler for /transfer-ws — one invocation per directional RemoteSync transfer.
# Worker (from inside its Malt subprocess) dials this in response to an
# `open_transfer` command on the control WS. We hand the live WS to the
# orchestrator task that called sync_dir_to_worker!/sync_dir_from_worker!.
function handle_transfer_ws(state::ServerState, ws)
    handle_handoff_ws(state, ws, "sync_id"; close_on_exit = false)
end

# Handler for /worker-acp — one invocation per ACP session.
function handle_worker_acp(state::ServerState, ws)
    handle_handoff_ws(state, ws, "sid"; close_on_exit = false)
end

# Shared handoff: auth on the first frame (`{secret, <id_field>}`), look up
# the matching pending RPC channel by the id, ack with `{ok:true}`, hand the
# live WS to the waiting orchestrator task, then block until close so Bonito
# doesn't tear the connection down underneath us.
function handle_handoff_ws(state::ServerState, ws, id_field::AbstractString;
                            close_on_exit::Bool = false)
    auth_raw = WebSockets.receive(ws)
    auth = JSON.parse(String(auth_raw))
    if get(auth, "secret", "") != state.worker_secret
        send_ws_error(ws, Dict("ok"=>false, "error"=>"unauthorized"))
        return
    end
    id = String(get(auth, id_field, ""))
    if isempty(id)
        send_ws_error(ws, Dict("ok"=>false, "error"=>"missing $id_field"))
        return
    end
    # Atomic take-if-present under `state.lock` (T3). `haskey` then `pop!`
    # unlocked raced the timeout task in `take_pending!` (which deletes the same
    # key under the lock): the bare `pop!` could KeyError mid-handshake, or two
    # paths could both think they own the channel. One locked pop decides the
    # winner.
    ch = lock(state.lock) do
        haskey(state.pending_rpcs, id) ? pop!(state.pending_rpcs, id) : nothing
    end
    if ch === nothing
        send_ws_error(ws, Dict("ok"=>false,
                               "error"=>"unknown or expired $id_field"))
        return
    end
    # Ack first (the worker waits for `{ok:true}` before it starts streaming),
    # then hand the live WS to the waiting orchestrator. The caller may have
    # already given up (closed the channel) between our pop and this put! — same
    # race `take_pending!` handles. If nobody consumed the WS, close it so we
    # don't leak a socket + this handler task parked in the sleep loop forever.
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))
    delivered = try
        put!(ch, ws)
        true
    catch e
        e isa InvalidStateException || rethrow()
        false
    end
    if !delivered
        close_ws_safe(ws)
        return
    end

    while !WebSockets.isclosed(ws)
        sleep(1)
    end
    close_on_exit && close_ws_safe(ws)
end

# File transport over WS

# RemoteSync transfer (librsync-based, IO-streamed over /transfer-ws).
# Both directions share the same orchestration: we generate a sync_id, tell
# the worker to dial in (the worker side spawns its own Malt subprocess so
# the librsync work doesn't pin the worker's ACP relay loop), wait for the
# WS handoff, then run the matching RemoteSync side here in a Task.
#
# The server side runs in-process (Task) rather than its own subprocess: the
# work is interleaved with WS reads/writes (which yield) and per-file IO
# (which yields), so the main task's heartbeat loop stays responsive even on
# multi-GB transfers.

"""
    sync_dir_to_worker!(worker_name, src, dst; on_progress=nothing, quick_check=true)

Send the contents of server-side `src` to worker-side `dst` via librsync.
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
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id, ch = register_rpc!(state)

    # try/finally so a throw in `send_command` (worker hung up between the
    # haskey check and the send) doesn't leak the pending registration (T10).
    # On the success path the handoff already popped the key, so this is a no-op.
    ws = try
        notify_progress(on_progress, :phase, (msg = "Connecting to worker…",))
        send_command(state, worker_name, Dict(
            "type"        => "open_transfer",
            "sync_id"     => sync_id,
            "direction"   => "to_worker",
            "dst_path"    => dst,
            "quick_check" => quick_check,
        ))
        take_pending!(state, ch, sync_id, handoff_timeout,
                      "sync to '$worker_name'")
    finally
        unregister_rpc!(state, sync_id)
    end
    try
        notify_progress(on_progress, :phase, (msg = "Streaming via librsync…",))
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.send_directory(src, wsio; on_progress = on_progress)
        notify_progress(on_progress, :phase, (msg = "Done",))
    finally
        close_ws_safe(ws)
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
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    mkpath(dst)

    sync_id, ch = register_rpc!(state)

    # try/finally to avoid leaking the pending registration on a send failure (T10).
    ws = try
        notify_progress(on_progress, :phase, (msg = "Connecting to worker…",))
        send_command(state, worker_name, Dict(
            "type"      => "open_transfer",
            "sync_id"   => sync_id,
            "direction" => "from_worker",
            "src_path"  => src,
        ))
        take_pending!(state, ch, sync_id, handoff_timeout,
                      "sync from '$worker_name'")
    finally
        unregister_rpc!(state, sync_id)
    end
    try
        notify_progress(on_progress, :phase, (msg = "Streaming via librsync…",))
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.receive_directory(dst, wsio; on_progress = on_progress,
                                     quick_check = quick_check)
        notify_progress(on_progress, :phase, (msg = "Done",))
    finally
        close_ws_safe(ws)
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
    haskey(state.worker_control_ws, worker_name) ||
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
            entries = [(name = String(e["name"]), dir = Bool(e["dir"]))
                       for e in resp["entries"]])
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
    haskey(state.worker_control_ws, worker_name) ||
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
    haskey(state.worker_control_ws, worker_id) ||
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
    haskey(state.worker_control_ws, worker_id) ||
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
    haskey(state.worker_control_ws, worker_id) || return false
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
        end
        save_projects!(state)
    end
    safe_notify!(state.projects)
    @info "pruned project(s) with missing worker paths" worker = worker_id count = length(dead) ids = dead
    return length(dead)
end

"""
    inspect_path_local(path) -> Dict

Same shape as `inspect_worker_path` but walks a directory on the SERVER
(used as a fallback when the project's current owner-worker is offline
— the server mirror is the best info we have in that case). Defers to
BonitoWorker's helper so the two sides always agree.
"""
function inspect_path_local(path::AbstractString)
    isdir(path) || error("not a directory: $path")
    return BonitoWorker.inspect_path_summary(String(path))
end

"""
    inspect_project(state, p; timeout=30.0) -> (summary::Dict, source::Symbol)

Content summary for a project, preferring its live worker (`:worker`) and
falling back to the server mirror (`:mirror`) when the worker is offline or
the live inspect fails. Shape matches `inspect_worker_path`.
"""
function inspect_project(state::ServerState, p::ProjectInfo; timeout::Real = 30.0)
    if haskey(state.worker_control_ws, p.worker_id)
        try
            return inspect_worker_path(state, p.worker_id, p.worker_path; timeout = timeout), :worker
        catch e
            @warn "inspect_project: live inspect failed, falling back to mirror" project=p.name exception=e
        end
    end
    return inspect_path_local(p.server_path), :mirror
end

"""
    compare_projects(state, a, b; timeout=30.0) -> NamedTuple

Symmetric side-by-side summary of two projects for the cross-worker sync
modal. Returns `(a, a_source, b, b_source)` where each summary is a Dict
from `inspect_project`.
"""
function compare_projects(state::ServerState, a::ProjectInfo, b::ProjectInfo;
                          timeout::Real = 30.0)
    a_sum, a_src = inspect_project(state, a; timeout = timeout)
    b_sum, b_src = inspect_project(state, b; timeout = timeout)
    return (a = a_sum, a_source = a_src, b = b_sum, b_source = b_src)
end

"""
    sync_across_workers!(state, src::ProjectInfo, dst::ProjectInfo; on_progress=nothing)

Directional overwrite: make `dst`'s worker tree match `src`'s content. There
is no worker↔worker transport, so this is server-mediated — refresh `src`'s
server mirror from its live worker, then push that mirror onto `dst`'s worker
path. `dst`'s divergent edits are overwritten (the caller has confirmed the
direction via the sync modal). Both workers must be online.
"""
function sync_across_workers!(state::ServerState, src::ProjectInfo, dst::ProjectInfo;
                              on_progress = nothing)
    src.id == dst.id && error("Source and target are the same project")
    haskey(state.workers[], src.worker_id) ||
        error("Source worker '$(src.worker_id)' is not connected")
    haskey(state.workers[], dst.worker_id) ||
        error("Target worker '$(dst.worker_id)' is not connected")

    # quick_check=false on both legs: this is a user-confirmed directional
    # overwrite, so files whose size+mtime happen to match must still be
    # delta-checked — otherwise divergent same-size edits silently survive.
    notify_progress(on_progress, :phase, (msg = "Pulling '$(src.name)' from source worker…",))
    sync_dir_from_worker!(state, src.worker_id, src.worker_path, src.server_path;
                          on_progress = on_progress, quick_check = false)
    src.backup_status = :synced
    src.last_sync_at  = now(UTC)

    notify_progress(on_progress, :phase, (msg = "Pushing onto target worker…",))
    sync_dir_to_worker!(state, dst.worker_id, src.server_path, dst.worker_path;
                        on_progress = on_progress, quick_check = false)
    # dst's worker tree now matches src; dst's own server mirror is out of date.
    dst.backup_status = :stale
    save_projects!(state)
    safe_notify!(state.projects)
    return nothing
end

"""
    scan_worker_sessions(state, worker_name; timeout=15.0) → Vector{Dict{String,Any}}

Ask the named worker to scan for existing Claude Code sessions (running processes
+ ~/.claude/projects/ history) and return the results. Blocks until the worker
replies or `timeout` seconds elapse.
"""
function scan_worker_sessions(state::ServerState, worker_name::String;
                                timeout::Real = 15.0)
    haskey(state.worker_control_ws, worker_name) ||
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
title_is_broken(t::Nothing) = false
function title_is_broken(t::AbstractString)
    s = String(t)
    cleaned = meaningful_title(s)
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
    fixed = 0
    lock(state.lock) do
        for (pid, p) in state.projects[]
            p.worker_id == wid || continue
            title_is_broken(p.title) || continue
            # Prefer the original prompt — re-running the filter against the
            # raw first user message recovers any prose the old truncation
            # dropped on the floor.
            chat_dir = chat_storage_dir(state, pid, p.server_path)
            raw = first_user_prompt(chat_dir)
            new_title = raw === nothing ? nothing : meaningful_title(raw)
            # Fall back to cleaning the saved title in place — strictly an
            # improvement over the leaked form even when chat.md isn't
            # available (cwd moved, project imported, …).
            new_title === nothing && (new_title = meaningful_title(String(p.title)))
            p.title = new_title === nothing ? nothing : String(new_title)
            fixed += 1
        end
        fixed > 0 && save_projects!(state)
    end
    fixed > 0 && (@info "refresh_broken_titles!: repaired $(fixed) project title(s)" worker_id=wid;
                   safe_notify!(state.projects))
    return fixed
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
    haskey(state.worker_control_ws, worker_name) ||
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
    fetch_file_from_worker(state, worker_name, src_path, dst_path;
                            handoff_timeout = 15.0, on_progress = nothing)

Stream a single file from the named worker into `dst_path` on the server.
Reuses the `/transfer-ws` handoff already used by directory sync, but with
direction `"file_from_worker"` and `RemoteSync.send_file`/`receive_file` for
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
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id, ch = register_rpc!(state)

    ws = try
        send_command(state, worker_name, Dict(
            "type"      => "open_transfer",
            "sync_id"   => sync_id,
            "direction" => "file_from_worker",
            "src_path"  => String(src_path),
        ))
        take_pending!(state, ch, sync_id, handoff_timeout,
                      "fetch_file from '$worker_name'")
    finally
        unregister_rpc!(state, sync_id)   # T10
    end
    try
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.receive_file(String(dst_path), wsio; on_progress)
    finally
        close_ws_safe(ws)
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
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id, ch = register_rpc!(state)

    ws = try
        send_command(state, worker_name, Dict(
            "type"      => "open_transfer",
            "sync_id"   => sync_id,
            "direction" => "file_to_worker",
            "dst_path"  => String(dst_path),
        ))
        take_pending!(state, ch, sync_id, handoff_timeout,
                      "send_file to '$worker_name'")
    finally
        unregister_rpc!(state, sync_id)   # T10
    end
    try
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.send_file(String(src_path), wsio; on_progress)
        # Wait for the worker (receiver) to drain + close first — closing before
        # it has the tail truncates the last frame(s) and EOFs its receive_file.
        RemoteSync.wait_peer_close(wsio)
    finally
        close_ws_safe(ws)
    end
    return String(dst_path)
end

# NOTE: WS-backed ACP I/O now lives in `WorkerTransport` (src/transport.jl)
# as `AgentClientProtocol.send` / `recv` and `Base.close` overloads — the
# Connection talks to the transport via dispatched verbs, not callbacks.
