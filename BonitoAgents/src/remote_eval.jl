# ── Running Julia on ANOTHER worker ──────────────────────────────────────────
# `bt_julia_eval(worker = "MacBook")` from a chat whose agent lives on the
# desktop. The chat's own MCP forwards the call over its control channel
# (`dev_request` op `remote_eval`); this file answers it: it checks the chat's
# switch, resolves the worker, spawns a BonitoMCP EVAL HOST on that worker for
# this chat if none is up (the worker command `open_eval_host`; the host dials
# `/mcp-ws` back with a host handshake, see `handle_mcp_ctrl_ws`), relays the
# call to it and hands the host's tool result back verbatim. The host's live
# stdout streams into the chat like a local eval's, and its eval workers dial the
# eval-ws bridge for this project, so a plot returned on the MacBook renders in
# the chat on the desktop.
#
# ⚠ ONE LIVE BRIDGE PER CHAT. `state.eval_workers` is keyed by project, so a
# remote eval that returns a LIVE value displaces the chat's local bridge, and
# the next local one displaces it back (each displacement retires the other's
# host-side wiring — see `handle_eval_ws`). Text output, stdout streaming and
# every non-live result are unaffected; it is only interleaved LIVE embeds from
# two machines in one chat that lose their older half. This is the same
# limitation the file's note there already records for two `env_path`s in one
# chat, and it has the same fix: the eval-ws handshake has to carry which
# session dialed (worker + env), so bridges can coexist per session instead of
# per project.
#
# OFF BY DEFAULT, per chat: `ProjectInfo.remote_eval`. The switch sits in the
# chat's ⋯ menu, next to 'Dev mode'. It is enforced HERE, at relay time —
# not in the MCP process, which the agent drives — so it takes effect without a
# restart and cannot be argued around. Switching it off shuts the chat's hosts
# down; so does the end of the chat's session (`stop_session!`).
#
# `bt_sync_folder` (op `sync_folder`) is the companion: the other machine has
# its own filesystem, so code and data are copied there first — through the
# server's mirror, like every other transfer between two workers.

const EVAL_HOST_SPAWN_TIMEOUT_S = 180.0
const REMOTE_OPS = ("eval", "continue", "interrupt", "restart", "sessions")

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
        safe_notify!(state.projects)
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
concurrent first calls share one spawn. Waits for the host's dial-back (a julia
start plus `using BonitoMCP`; bounded by `EVAL_HOST_SPAWN_TIMEOUT_S`).
"""
function ensure_eval_host!(state::ServerState, p::ProjectInfo, w::WorkerInfo)
    ws = eval_host_ws(state, p.id, w.worker_id)
    ws === nothing || return ws
    key = eval_host_key(p.id, w.worker_id)
    lk = lock(state.lock) do
        get!(state.eval_host_locks, key, ReentrantLock())
    end
    lock(lk) do
        ws = eval_host_ws(state, p.id, w.worker_id)
        ws === nothing || return ws
        env = Dict{String,String}("BONITOAGENTS_SECRET" => state.worker_secret,
                                  "BONITOAGENTS_PROJECT_ID" => p.id)
        r = open_eval_host_on_worker(state, w.worker_id; project_id = p.id, env)
        @info "eval host spawned" project = p.name worker = w.name pid = r.pid existed = r.existed
        deadline = time() + EVAL_HOST_SPAWN_TIMEOUT_S
        while time() < deadline
            ws = eval_host_ws(state, p.id, w.worker_id)
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
        lock(state.lock) do
            key = eval_host_key(project_id, wid)
            get(state.eval_hosts, key, nothing) === ws && delete!(state.eval_hosts, key)
            # The spawn lock goes with it, so one entry per (chat, worker) that
            # ever ran a remote eval doesn't stay for the server's life — unless
            # a spawn is holding it right now, in which case dropping it would
            # let the next caller mint a second lock for the same key and defeat
            # the single-flight. That one is left for the next close.
            lk = get(state.eval_host_locks, key, nothing)
            lk === nothing || islocked(lk) || delete!(state.eval_host_locks, key)
        end
        haskey(state.worker_control_ws, wid) || continue
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
    return op == "interrupt" ? 85.0 : op == "restart" ? 115.0 : 55.0
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
    rows = Any[]
    for w in workers
        row = Dict{String,Any}("name" => w.name, "worker_id" => w.worker_id,
                               "hostname" => w.hostname, "projects_root" => w.projects_root,
                               "host_live" => false, "sessions" => Any[])
        ws = p === nothing ? nothing : eval_host_ws(state, p.id, w.worker_id)
        if ws !== nothing
            row["host_live"] = true
            try
                r = host_rpc(state, ws, "sessions", Dict{String,Any}(); timeout = 15.0)
                res = get(r, "result", nothing)
                text = res isa AbstractDict && !isempty(get(res, "content", Any[])) ?
                    String(get(first(res["content"]), "text", "")) : ""
                row["sessions"] = [Dict{String,Any}("env_path" => strip(l[3:end]),
                                                    "in_flight" => occursin("EVAL IN FLIGHT", l))
                                   for l in split(text, '\n') if startswith(l, "  - ")]
            catch e
                e isa InterruptException && rethrow()
                @warn "eval host did not list its sessions" worker = w.name exception = e
            end
        end
        push!(rows, row)
    end
    return Dict{String,Any}("enabled" => p !== nothing && p.remote_eval, "workers" => rows)
end

# Where a folder being copied between two workers is staged on the server. Per
# (chat, source folder, target worker), so a second copy of the same folder is a
# delta against the first instead of a full transfer.
folder_mirror(state::ServerState, p::ProjectInfo, w::WorkerInfo, src::AbstractString) =
    joinpath(state.state_dir, "transfers",
             "sync-" * p.id * "-" * string(hash((String(src), w.worker_id)); base = 16))

"""
    sync_folder!(state, p, w, src, dst; progress = nothing) -> NamedTuple

Copy `src` (a folder on `p`'s worker) to `dst` on worker `w` through the server
mirror. Returns what crossed: how many files and bytes the folder holds, and the
push's own counts (written, deleted at `dst`, skipped as unchanged).
"""
function sync_folder!(state::ServerState, p::ProjectInfo, w::WorkerInfo,
                      src::AbstractString, dst::AbstractString; progress = nothing)
    src_w = get(state.workers[], p.worker_id, nothing)
    (src_w === nothing || !isopen(src_w)) && error("this chat's own worker is offline")
    isempty(strip(src)) && error("`src` is empty")
    isempty(strip(dst)) && error("`dst` is empty")
    mirror = folder_mirror(state, p, w, src)
    mkpath(mirror)
    notify_progress(progress, :phase, (msg = "Pulling $(src) from $(src_w.name)…",))
    sync_dir_from_worker!(state, src_w.worker_id, String(src), mirror; on_progress = progress)
    written = Ref(0); deleted = Ref(0); skipped = Ref(0)
    counting = (stage, info) -> begin
        if stage === :transfer_done
            written[] = Int(get(info, :written, get(info, :files, 0)))
            deleted[] = Int(get(info, :deleted, 0))
            skipped[] = Int(get(info, :skipped, 0))
        end
        notify_progress(progress, stage, info)
    end
    notify_progress(progress, :phase, (msg = "Pushing to $(dst) on $(w.name)…",))
    sync_dir_to_worker!(state, w.worker_id, mirror, String(dst); on_progress = counting)
    files = 0; bytes = 0
    for (root, _, fs) in walkdir(mirror), f in fs
        files += 1; bytes += filesize(joinpath(root, f))
    end
    return (files = files, bytes = bytes, written = written[],
            deleted = deleted[], skipped = skipped[])
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
