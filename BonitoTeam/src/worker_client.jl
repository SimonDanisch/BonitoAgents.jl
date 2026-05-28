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
#                   pair it with a Channel that `start_session(::WorkerTransport)` is
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
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    WebSockets.send(state.worker_control_ws[worker_name], JSON.json(payload))
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

# Take from a pending-RPC channel with a bounded wait. If `timeout` seconds
# elapse without the worker replying, evict the entry (so a late reply gets
# "unknown id") and surface a clear error to the caller.
function take_pending!(state::ServerState, ch::Channel, key::String,
                       timeout::Real, op_name::AbstractString)
    Base.errormonitor(@async begin
        sleep(timeout)
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
            # The channel may have been closed by a peer-cleanup
            # between the `had` check above and this put!. That's
            # exactly the race this whole timeout dance handles —
            # not a real error.
            try
                put!(ch, nothing)
            catch e
                e isa InvalidStateException || rethrow()
            end
        end
    end)
    val = take!(ch)
    val === nothing && error("$op_name timed out after $(timeout)s — worker may be offline or stuck")
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

        # Build / refresh the WorkerInfo from the hello frame.
        w = WorkerInfo(
            worker_id,
            display_name,
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
        projects_to_attach = lock(state.lock) do
            state.workers[][worker_id] = w
            state.worker_control_ws[worker_id] = ws
            migrate_legacy_worker_refs!(state, w)
            save_workers!(state)
            # Snapshot the projects we want to attach BEFORE leaving the
            # lock — `ensure_project_session!` itself takes the lock and
            # also does network I/O, so we don't want to hold the mutex
            # across that work.
            [p for p in values(state.projects[]) if p.worker_id == worker_id]
        end
        # Worker added → fan out to worker-cards consumers. If any
        # legacy projects had their worker_id rewritten by
        # migrate_legacy_worker_refs!, the project list also needs to
        # know (the project card shows the worker name and that lookup
        # was previously broken).
        safe_notify!(state.workers)
        safe_notify!(state.projects)
        @info "Worker connected" worker_id=worker_id name=display_name hostname=w.hostname

        for p in projects_to_attach
            try
                ensure_project_session!(state, p)
            catch e
                @warn "Failed to (re)attach project on connect" project=p.name exception=e
            end
        end

        # Process inbound frames from the worker. Every typed reply maps
        # back to a pending RPC by request_id; deliver_rpc_response! is a
        # no-op if the id is unknown (caller already timed out).
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
                elseif t == "open_session_failed"
                    # Worker couldn't spawn the agent (e.g. binary missing).
                    # `sid` is the pending RPC key (not `request_id`); pre-emptively
                    # fail the open_session call so the UI's busy banner clears
                    # immediately instead of waiting 30s for the WS handoff.
                    sid    = String(get(cmd, "sid", ""))
                    reason = String(get(cmd, "reason", "open_session failed"))
                    deliver_rpc_response!(state, sid,
                        Dict{String,Any}("error" => reason))
                end
            catch e
                @warn "Worker control frame error" exception=e
            end
        end
    finally
        # Atomic teardown: mark offline, drop the WS handle, evict the
        # ChatModels for this worker's projects. release_projects_for_worker!
        # also takes the lock per release; safe because ReentrantLock is.
        lock(state.lock) do
            delete!(state.worker_control_ws, worker_id)
            if haskey(state.workers[], worker_id)
                state.workers[][worker_id].status = :offline
            end
            for p in values(state.projects[])
                if p.worker_id == worker_id
                    delete!(state.chat_models, p.id)
                end
            end
        end
        safe_notify!(state.workers)
        release_projects_for_worker!(state, worker_id)
        @info "Worker disconnected" worker_id=worker_id
    end
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
    haskey(state.pending_rpcs, id) || begin
        send_ws_error(ws, Dict("ok"=>false,
                               "error"=>"unknown or expired $id_field"))
        return
    end
    ch = pop!(state.pending_rpcs, id)
    WebSockets.send(ws, JSON.json(Dict("ok" => true)))
    put!(ch, ws)

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
    sync_dir_to_worker!(worker_name, src, dst; on_progress=nothing)

Send the contents of server-side `src` to worker-side `dst` via librsync.
Resumable: subsequent calls compute deltas against the worker's existing
files, so unchanged content isn't retransmitted.
"""
function sync_dir_to_worker!(state::ServerState, worker_name::String,
                              src::String, dst::String;
                              handoff_timeout::Real = 30.0,
                              on_progress = nothing)
    isdir(src) || error("Source path is not a directory: $src")
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")

    sync_id, ch = register_rpc!(state)

    notify_progress(on_progress, :phase, (msg = "Connecting to worker…",))
    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "to_worker",
        "dst_path"  => dst,
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
                      "sync to '$worker_name'")
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
    sync_dir_from_worker!(worker_name, src, dst; on_progress=nothing)

Inverse: receive worker-side `src` into server-side `dst` via librsync.
Resumable in the same way as `sync_dir_to_worker!`.
"""
function sync_dir_from_worker!(state::ServerState, worker_name::String,
                                src::String, dst::String;
                                handoff_timeout::Real = 30.0,
                                on_progress = nothing)
    haskey(state.worker_control_ws, worker_name) ||
        error("Worker '$worker_name' is not connected")
    mkpath(dst)

    sync_id, ch = register_rpc!(state)

    notify_progress(on_progress, :phase, (msg = "Connecting to worker…",))
    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "from_worker",
        "src_path"  => src,
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
                      "sync from '$worker_name'")
    try
        notify_progress(on_progress, :phase, (msg = "Streaming via librsync…",))
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.receive_directory(dst, wsio; on_progress = on_progress)
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
    send_command(state, worker_name, Dict(
        "type"       => "list_dir",
        "request_id" => rid,
        "path"       => String(path),
    ))

    resp = take_pending!(state, ch, rid, timeout, "list_dir on '$worker_name'")
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
    send_command(state, worker_name, Dict(
        "type"       => "inspect_path",
        "request_id" => rid,
        "path"       => String(path),
    ))
    resp = take_pending!(state, ch, rid, timeout, "inspect_path on '$worker_name'")
    resp isa AbstractDict || error("inspect_path: unexpected response shape")
    haskey(resp, "error") && error("inspect_path on '$worker_name': $(resp["error"])")
    summary = get(resp, "summary", nothing)
    summary isa AbstractDict || error("inspect_path: missing summary")
    return Dict{String,Any}(summary)
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
    compare_for_collision(state, existing_project, candidate_worker_name,
                           candidate_worker_path; timeout=30.0) -> NamedTuple

Build the side-by-side summary used by the import-collision UI. Returns
`(existing = summary_dict, existing_source = :worker|:mirror,
   candidate = summary_dict)`. The existing-side summary is preferred
from the project's bound worker (live state); falls back to the server
mirror if the worker is offline.
"""
function compare_for_collision(state::ServerState, p::ProjectInfo,
                                candidate_worker_name::String,
                                candidate_worker_path::String;
                                timeout::Real = 30.0)
    candidate = inspect_worker_path(state, candidate_worker_name,
                                     candidate_worker_path; timeout = timeout)
    existing, source = if haskey(state.worker_control_ws, p.worker_id)
        try
            inspect_worker_path(state, p.worker_id, p.worker_path; timeout = timeout),
                :worker
        catch e
            @warn "compare_for_collision: live inspect failed, falling back to mirror" exception=e
            inspect_path_local(p.server_path), :mirror
        end
    else
        inspect_path_local(p.server_path), :mirror
    end
    return (existing = existing, existing_source = source, candidate = candidate)
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
    send_command(state, worker_name, Dict("type" => "scan_sessions", "request_id" => rid))
    resp = take_pending!(state, ch, rid, timeout, "scan_sessions on '$worker_name'")
    return resp isa AbstractVector ? resp : Dict{String,Any}[]
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
    send_command(state, worker_name, payload)

    resp = take_pending!(state, ch, rid, timeout, "clone_repo on '$worker_name'")
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

    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "file_from_worker",
        "src_path"  => String(src_path),
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
                      "fetch_file from '$worker_name'")
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

    send_command(state, worker_name, Dict(
        "type"      => "open_transfer",
        "sync_id"   => sync_id,
        "direction" => "file_to_worker",
        "dst_path"  => String(dst_path),
    ))

    ws = take_pending!(state, ch, sync_id, handoff_timeout,
                      "send_file to '$worker_name'")
    try
        wsio = RemoteSync.WebSocketIO(ws)
        RemoteSync.send_file(String(src_path), wsio; on_progress)
    finally
        close_ws_safe(ws)
    end
    return String(dst_path)
end

# NOTE: WS-backed ACP I/O now lives in `WorkerTransport` (src/transport.jl)
# as `AgentClientProtocol.send` / `recv` and `Base.close` overloads — the
# Connection talks to the transport via dispatched verbs, not callbacks.
