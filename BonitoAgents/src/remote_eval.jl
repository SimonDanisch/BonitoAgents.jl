# ── Running Julia on ANOTHER worker ──────────────────────────────────────────
# `bt_julia_eval(worker = "MacBook")` from a chat whose agent lives on the
# desktop. The chat's own MCP forwards the call over its control channel
# (`dev_request` op `remote_eval`); this file answers it: it checks the chat's
# switch, resolves the worker, spawns a BonitoMCP EVAL HOST on that worker for
# this chat if none is up (the worker command `open_eval_host`; the host connects
# through that worker's relay with a host grant, see `accept_worker_channel`),
# relays the call to it and hands the host's tool result back verbatim. The
# host's live stdout streams into the chat like a local eval's, and its eval
# workers open the live-render bridge for this project, so a plot returned on the
# MacBook renders in the chat on the desktop.
#
# Live results from both machines coexist: a host's bridges are filed under the
# chat AND its worker (`eval_bridge_key`), and a result finds its bridge by the
# prefix in its id (`bridge_for_ref`). What remains is the limit the note at
# `serve_eval_bridge` records for two `env_path`s on ONE worker: one bridge per
# (chat, worker), so there the newer session displaces the older one's embeds.
#
# OFF BY DEFAULT, per chat: `ProjectInfo.remote_eval`. The switch sits in the
# chat's ⋯ menu, next to 'Dev mode'. It is enforced HERE, at relay time —
# not in the MCP process, which the agent drives — so it takes effect without a
# restart and cannot be argued around. Switching it off shuts the chat's hosts
# down; so does the end of the chat's session (`stop_session!`).
#
# `bt_sync_folder` (op `sync_folder`) is the companion: the other machine has
# its own filesystem, so code and data are streamed there first through the
# server over the workers' existing authenticated connections.

const EVAL_HOST_SPAWN_TIMEOUT_S = 180.0
# `runs` answers with run statuses as data (`bt_julia_wait` polling a remote run).
const REMOTE_OPS = ("eval", "continue", "interrupt", "restart", "sessions", "runs")

eval_host_key(project_id::AbstractString, worker_id::AbstractString) =
    "$(project_id)\0$(worker_id)"

eval_host_ws(state::ServerState, project_id::AbstractString, worker_id::AbstractString) =
    lock(state.lock) do
        get(state.eval_hosts, eval_host_key(project_id, worker_id), nothing)
    end

# Every live host of one chat, as `(worker_id, ws)`.
function eval_hosts_of(state::ServerState, project_id::AbstractString)
    prefix = project_id * "\0"
    lock(state.lock) do
        [(String(k[(length(prefix) + 1):end]), ws) for (k, ws) in state.eval_hosts
         if startswith(k, prefix)]
    end
end

"""
    set_remote_eval!(state, project_id, on) -> ProjectInfo

Flip the chat's "remote julia" switch. Persisted with the project; switching it
off shuts down every eval host the chat has on other workers.
"""
function set_remote_eval!(state::ServerState, project_id::AbstractString, on::Bool)
    p = get(state.projects[], String(project_id), nothing)
    p === nothing && error("unknown chat '$(project_id)'")
    if p.remote_eval != on
        p.remote_eval = on
        lock(state.lock) do; save_projects!(state); end
        notify_projects!(state)
        on || close_eval_hosts!(state, p.id)
        # The ONLY record that this was ever flipped. Without it a report of
        # "the header says on and the agent still says off" has nothing to check
        # against: no log line, and the flag is not in any report either (it is
        # in `project_report` now, which it was not when this first bit).
        @info "remote julia switched" project_id = p.id name = p.name on = on
    end
    return p
end

"""
    resolve_worker(state, ref) -> WorkerInfo

The online worker called `ref` (its display name, case-insensitively, or its id).
"""
function resolve_worker(state::ServerState, ref::AbstractString)
    r = String(strip(ref))
    isempty(r) && error("no worker named")
    workers = collect(values(state.workers[]))
    hits = filter(w -> w.worker_id == r || w.name == r, workers)
    isempty(hits) && (hits = filter(w -> lowercase(w.name) == lowercase(r), workers))
    if isempty(hits)
        online = sort([w.name for w in workers if isopen(w)])
        error("no worker named '$(r)' — online workers: " *
              (isempty(online) ? "(none)" : join(online, ", ")))
    end
    length(hits) > 1 &&
        error("several workers are named '$(r)' — use a worker id instead: " *
              join((w.worker_id for w in hits), ", "))
    w = only(hits)
    isopen(w) || error("worker '$(w.name)' is offline")
    return w
end

# The chat behind a control channel, provided its switch is on. The messages
# are written for the AGENT, which relays them to the user.
function remote_eval_project(state::ServerState, caller::AbstractString)
    isempty(caller) && error("running Julia on another worker needs a chat (this control channel carries no project id)")
    p = get(state.projects[], caller, nothing)
    p === nothing && error("unknown chat '$(caller)'")
    if !p.remote_eval
        # Name the chat the SERVER resolved. The user reads the switch in one
        # chat's header; this call arrives on the control channel of whatever
        # project id was baked into that MCP process at spawn. When the two
        # disagree — several chats open on the same folder, a session that
        # outlived a re-registered project — the old message ("switched OFF for
        # this chat") sent everyone looking at the right switch on the wrong
        # chat. The id makes that mismatch visible in the transcript itself.
        @warn "remote julia refused" caller = caller project = p.name worker_path = p.worker_path
        error("Running Julia on another worker is switched OFF for chat '$(caller)' " *
              "($(p.name)). Turn it on in THAT chat's ⋯ menu → 'Remote julia' — if its " *
              "header already reads on, you are looking at a different chat on the same " *
              "folder, and this is the one that needs it. Ask rather than retrying.")
    end
    return p
end

# The target of a remote op: the named worker, which must not be the chat's own.
function remote_target(state::ServerState, p::ProjectInfo, args::AbstractDict)
    w = resolve_worker(state, String(get(args, "worker", "")))
    w.worker_id == p.worker_id &&
        error("'$(w.name)' is this chat's own worker — call without `worker` to run here")
    return w
end

"""
    ensure_eval_host!(state, p, w) -> ws

The live control socket of the eval host serving chat `p` on worker `w`,
spawning the host through the worker if there is none. Single-flight per host:
concurrent first calls share one spawn. Waits for the host's channel (a julia
start plus `using BonitoMCP`; bounded by `EVAL_HOST_SPAWN_TIMEOUT_S`).
"""
ensure_eval_host!(state::ServerState, p::ProjectInfo, w::WorkerInfo) =
    ensure_eval_host!(state, p.id, p.name, w)

# `project_id` is a chat's, or `SHARES_PROJECT` for the worker's share host
# (shares.jl); `label` names it in the log.
function ensure_eval_host!(state::ServerState, project_id::String, label::String, w::WorkerInfo)
    ws = eval_host_ws(state, project_id, w.worker_id)
    ws === nothing || return ws
    key = eval_host_key(project_id, w.worker_id)
    lk = lock(state.lock) do
        get!(state.eval_host_locks, key, ReentrantLock())
    end
    lock(lk) do
        ws = eval_host_ws(state, project_id, w.worker_id)
        ws === nothing || return ws
        env = Dict{String,String}("BONITOAGENTS_PROJECT_ID" => project_id)
        r = open_eval_host_on_worker(state, w.worker_id; project_id, env)
        @info "eval host spawned" project = label worker = w.name pid = r.pid existed = r.existed
        deadline = time() + EVAL_HOST_SPAWN_TIMEOUT_S
        while time() < deadline
            ws = eval_host_ws(state, project_id, w.worker_id)
            ws === nothing || return ws
            sleep(0.1)
        end
        error("the eval host on '$(w.name)' did not connect within " *
              "$(round(Int, EVAL_HOST_SPAWN_TIMEOUT_S))s — see that worker's log")
    end
end

# One request/reply over a host's channel. The reply is the host's
# `eval_host_result` frame; its `result` is the tool result the chat's MCP
# returns to the agent verbatim.
function host_rpc(state::ServerState, ws, op::AbstractString, args::AbstractDict;
                  timeout::Real)
    rid, ch = register_rpc!(state)
    resp = try
        HTTP.WebSockets.send(ws, JSON.json(Dict{String,Any}(
            "op" => String(op), "request_id" => rid, "args" => args)))
        take_pending!(state, ch, rid, timeout, "eval host $(op)")
    finally
        unregister_rpc!(state, rid)
        untrack_mcp_request!(ws, rid)
    end
    resp isa AbstractDict || error("eval host '$(op)': unexpected reply shape")
    haskey(resp, "error") && error("eval host '$(op)': $(resp["error"])")
    return resp
end

"""
    close_eval_hosts!(state, project_id)

Shut down every eval host of a chat: tell each host to stop (it kills its eval
workers and exits), drop its channel, and have its worker reap the process in
case the host did not go on its own. Nothing to do for a chat without hosts.
"""
function close_eval_hosts!(state::ServerState, project_id::AbstractString)
    hosts = eval_hosts_of(state, project_id)
    for (wid, ws) in hosts
        try
            host_rpc(state, ws, "shutdown", Dict{String,Any}(); timeout = 5.0)
        catch e
            e isa InterruptException && rethrow()
            @warn "eval host did not acknowledge its shutdown" project_id worker_id = wid exception = e
        end
        close(ws)   # leaves the registry, and ends the channel of a host still alive
        lock(state.lock) do
            key = eval_host_key(project_id, wid)
            # The spawn lock goes with the host, so one entry per (chat, worker) that
            # ever ran a remote eval doesn't stay for the server's life — unless
            # a spawn is holding it right now, in which case dropping it would
            # let the next caller mint a second lock for the same key and defeat
            # the single-flight. That one is left for the next close.
            lk = get(state.eval_host_locks, key, nothing)
            lk === nothing || islocked(lk) || delete!(state.eval_host_locks, key)
        end
        worker_connected(state, wid) || continue
        try
            close_eval_host_on_worker(state, wid; project_id)
        catch e
            e isa InterruptException && rethrow()
            @warn "could not have the worker reap its eval host" project_id worker_id = wid exception = e
        end
    end
    isempty(hosts) || @info "eval hosts closed" project_id count = length(hosts)
    return nothing
end

"""
    host_channel_closed!(state, project_id, host_worker; grace = 60.0)

An eval host's control channel closed. A live-render bridge of its sessions
whose channel is still down `grace` later is dead (the host exited: its chat's
session ended, remote Julia was switched off, it crashed, its worker stopped; a
dropped link reconnects well within it), and is torn down. Nothing to do for a
chat's own MCP.
"""
function host_channel_closed!(state::ServerState, project_id::AbstractString,
                              host_worker::AbstractString; grace::Real = 60.0)
    isempty(host_worker) && return nothing
    Base.errormonitor(@async begin
        sleep(grace)
        foreach(key -> teardown_eval_bridge!(state, key),
                filter(key -> bridge_down(state, key), host_bridge_keys(state, project_id, host_worker)))
    end)
    return nothing
end

# The bridges of one eval host's sessions: a chat's host has one, filed under the
# chat and the worker; the share host one per session (shares.jl).
host_bridge_keys(state::ServerState, project_id::AbstractString, host_worker::AbstractString) =
    project_id == SHARES_PROJECT ? share_bridge_keys(state, host_worker) :
                                   [eval_bridge_key(project_id, host_worker)]

function bridge_down(state::ServerState, key::AbstractString)
    eb = eval_bridge_for(state, key)
    return eb !== nothing && lock(() -> eb.ws === nothing, eb.wlock)
end

# How long the server waits for the host: the MCP side waits `remote_wait` for
# the same call (tools/eval.jl); answering a little earlier means the agent gets
# the server's message ("host did not answer") rather than a bare timeout, and
# the eval keeps running on the host for a `bt_julia_continue`.
function remote_op_timeout(op::AbstractString, args::AbstractDict)
    op == "eval" &&
        return BonitoMCP.remote_wait(BonitoMCP.effective_timeout(
            String(get(args, "code", "")), get(args, "timeout", nothing))) - 5.0
    if op == "continue"
        t = get(args, "timeout", nothing)
        return BonitoMCP.remote_wait(t === nothing ? BonitoMCP.DEFAULT_TIMEOUT :
                                     (t > 0 ? t : nothing)) - 5.0
    end
    return op == "interrupt" ? 85.0 : op == "restart" ? 115.0 : op == "runs" ? 25.0 : 55.0
end

function dev_op(state::ServerState, ::Val{:remote_eval}, args::AbstractDict, caller::String)
    p = remote_eval_project(state, caller)
    w = remote_target(state, p, args)
    op = String(get(args, "op", "eval"))
    op in REMOTE_OPS || error("unknown remote op '$(op)' — expected one of " * join(REMOTE_OPS, ", "))
    raw = get(args, "args", Dict{String,Any}())
    fwd = raw isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in raw) : Dict{String,Any}()
    delete!(fwd, "worker")
    ws = ensure_eval_host!(state, p, w)
    resp = host_rpc(state, ws, op, fwd; timeout = remote_op_timeout(op, fwd))
    return get(resp, "result", nothing)
end

# The other online workers a chat could run on, with each one's live host
# sessions when a host is up — what `bt_julia_list_sessions` prints below the
# local sessions. No permission needed to LOOK; the reply says whether the
# switch is on.
function dev_op(state::ServerState, ::Val{:remote_workers}, args::AbstractDict, caller::String)
    p = get(state.projects[], caller, nothing)
    own = p === nothing ? "" : p.worker_id
    workers = sort([w for w in values(state.workers[]) if isopen(w) && w.worker_id != own];
                   by = w -> w.name)
    # All hosts at once, each bounded: one that does not answer must not take the
    # listing past the MCP's own wait (it did, asking them one after another).
    rows = fetch.([Threads.@spawn worker_row(state, p, w) for w in workers])
    return Dict{String,Any}("enabled" => p !== nothing && p.remote_eval, "workers" => rows)
end

function worker_row(state::ServerState, p::Union{ProjectInfo,Nothing}, w::WorkerInfo; timeout::Real = 10.0)
    row = Dict{String,Any}("name" => w.name, "worker_id" => w.worker_id,
                           "hostname" => w.hostname, "projects_root" => w.projects_root,
                           "host_live" => false, "sessions" => Any[])
    ws = p === nothing ? nothing : eval_host_ws(state, p.id, w.worker_id)
    ws === nothing && return row
    row["host_live"] = true
    try
        r = host_rpc(state, ws, "sessions", Dict{String,Any}(); timeout)
        res = get(r, "result", nothing)
        text = res isa AbstractDict && !isempty(get(res, "content", Any[])) ?
            String(get(first(res["content"]), "text", "")) : ""
        row["sessions"] = [Dict{String,Any}("env_path" => strip(l[3:end]),
                                            "in_flight" => occursin("EVAL IN FLIGHT", l))
                           for l in split(text, '\n') if startswith(l, "  - ")]
        # The chat's runs there (running, or finished and not collected).
        rr = get(host_rpc(state, ws, "runs", Dict{String,Any}(); timeout), "result", nothing)
        row["runs"] = rr isa AbstractDict ?
            [x for x in get(rr, "runs", Any[])
             if get(x, "status", "") == "running" || get(x, "collected", true) === false] : Any[]
    catch e
        e isa InterruptException && rethrow()
        (e isa WorkerUnreachableError || e isa ErrorException) || rethrow()
        @warn "eval host did not list its sessions" worker = w.name exception = e
        row["error"] = first(split(sprint(showerror, e), '\n'))
    end
    return row
end

"""
    sync_folder!(state, p, w, src, dst; progress = nothing) -> NamedTuple

Copy `src` (a folder on `p`'s worker) to `dst` on worker `w`, streaming through
the server without a disk mirror. The destination's own files are the delta
basis. Destination-only files are preserved. Returns the folder size and counts
of written, deleted (always zero), and unchanged files.
"""
function sync_folder!(state::ServerState, p::ProjectInfo, w::WorkerInfo,
                      src::AbstractString, dst::AbstractString; progress = nothing)
    src_w = get(state.workers[], p.worker_id, nothing)
    (src_w === nothing || !isopen(src_w)) && error("this chat's own worker is offline")
    isempty(strip(src)) && error("`src` is empty")
    isempty(strip(dst)) && error("`dst` is empty")
    started = time()
    notify_progress(progress, :phase, (msg = "Streaming from $(src_w.name) to $(w.name)…",))
    source = transfer_channel(state, src_w.worker_id,
        Dict("direction" => "from_worker", "src_path" => String(src)); timeout = 30.0)
    destination = nothing
    try
        destination = transfer_channel(state, w.worker_id,
            Dict("direction" => "to_worker", "dst_path" => String(dst)); timeout = 30.0)
        result = RemoteSync.relay_directory(RemoteSync.WebSocketIO(source),
            RemoteSync.WebSocketIO(destination); on_progress = progress)
        # Legacy receivers have no final protocol ACK. Their clean channel
        # close confirms completion. Inspect the channel directly: WebSocketIO
        # converts transport errors into EOF, which cannot distinguish success
        # from a receiver abort (disk full, permissions, interrupted transfer).
        try
            WebSockets.receive(destination)
            error("unexpected data after directory transfer")
        catch e
            e isa WebSockets.WebSocketError && WebSockets.isok(e) || rethrow()
        end
        @info "folder transfer completed" project_id = p.id source_worker = src_w.worker_id target_worker = w.worker_id files = result.files bytes = result.bytes written = result.written skipped = result.skipped seconds = round(time() - started; digits = 3)
        return result
    catch e
        WorkerLink.abort(source, "folder transfer failed")
        destination === nothing || WorkerLink.abort(destination, "folder transfer failed")
        rethrow()
    finally
        close(source)
        destination === nothing || close(destination)
    end
end

function dev_op(state::ServerState, ::Val{:sync_folder}, args::AbstractDict, caller::String)
    p = remote_eval_project(state, caller)
    w = remote_target(state, p, args)
    src = String(get(args, "src", ""))
    dst = String(get(args, "dst", src))
    r = sync_folder!(state, p, w, src, dst)
    return Dict{String,Any}("worker" => w.name, "dst" => dst, "files" => r.files,
                            "bytes" => r.bytes, "written" => r.written,
                            "deleted" => r.deleted, "skipped" => r.skipped)
end
