# Project lock + chat / dashboard orchestration. State (workers, projects,
# pending RPCs, etc.) lives in `state.jl::ServerState`; every public function
# in this file takes a `state::ServerState` argument as its first parameter.
# Worker registration is handled in worker_client.jl when the worker dials
# the server's /worker-ws endpoint. Liveness comes from the WS itself; no
# periodic probing or heartbeat task.

# Project lock
"""
Mark a project as claimed (i.e. has an active ACP session) by a worker.
Errors if the project is already claimed by a different worker.
`worker_id` is the worker's stable UUID, NOT its display name.

The claim is persisted to projects.json so it survives a server restart,
and the matching project card shows a "locked by …" badge in the UI.
"""
function claim_project!(state::ServerState, p::ProjectInfo, worker_id::String)
    lock(state.lock) do
        if p.locked_by !== nothing && p.locked_by != worker_id
            error("Project '$(p.name)' is claimed by worker '$(p.locked_by)'")
        end
        p.locked_by = worker_id
        p.locked_at = now(UTC)
        save_projects!(state)
    end
    safe_notify!(state.projects)
    return p
end

function release_project!(state::ServerState, p::ProjectInfo)
    lock(state.lock) do
        p.locked_by = nothing
        p.locked_at = nothing
        save_projects!(state)
    end
    safe_notify!(state.projects)
    return p
end

# Release every project claim held by `worker_id` (called from
# handle_worker_control's finally branch when the WS drops). Snapshot the
# matching projects under the lock so we don't iterate `state.projects[]`
# while a concurrent writer is mutating it; `release_project!` re-takes the
# lock per project (reentrant, harmless).
function release_projects_for_worker!(state::ServerState, worker_id::String)
    targets = lock(state.lock) do
        [p for p in values(state.projects[]) if p.locked_by == worker_id]
    end
    foreach(p -> release_project!(state, p), targets)
end

"""
Create a new project on the named worker. Steps:
1. Seed `<server_working_dir>/<name>` from the picked source folder (if not
   already there).
2. Mirror to `<worker.projects_root>/<name>` (via rsync — local or ssh).
3. Build the project's ChatModel (its `WorkerAgent` asks the worker over
   its control WS to spawn an ACP session and dial back) and cache it in
   `state.chat_models[id]` so `unified_main` can render it when the user
   selects this project in the sidebar.
"""
function create_project!(state::ServerState, name::String, src_path::String,
                          worker_name::String;
                          progress = nothing)
    haskey(state.workers[], worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only")
    isempty(src_path) && error("Source path is required (pick a folder).")
    isdir(src_path)   || error("Source path is not a directory: $src_path")

    w = state.workers[][worker_name]
    server_path = compute_server_path(state, worker_name, name)
    worker_path = joinpath(w.projects_root, name)

    # Idempotent re-import: if the same folder on the same worker is already
    # registered, return the existing entry instead of creating a duplicate.
    existing = find_project_by_location(state, worker_name, worker_path)
    if existing !== nothing
        @info "create_project!: existing project at this worker_path; reusing" id=existing.id name=existing.name
        ensure_project_session!(state, existing)
        return existing
    end

    id = string(uuid4())[1:8]

    # 1. Seed the canonical server-side copy from the picked source (local
    # rsync; this is always on the server box, no SSH).
    if abspath(src_path) != abspath(server_path)
        notify_progress(progress, :phase, (msg = "Seeding server-side mirror…",))
        @info "Seeding server-side mirror" src_path server_path
        mkpath(state.working_dir)
        run(`rsync -az $(rstrip(src_path, '/'))/ $(rstrip(server_path, '/'))/`)
    end

    # 2. Push server → worker over the worker's WS (no SSH, no inbound port).
    @info "Pushing project to worker" worker=worker_name dst=worker_path
    sync_dir_to_worker!(state, worker_name, server_path, worker_path; on_progress = progress)

    p = ProjectInfo(id, name, worker_name, server_path, worker_path, now(UTC))
    lock(state.lock) do
        state.projects[][id] = p
        save_projects!(state)
    end
    safe_notify!(state.projects)

    # 3 + 4: build the chat app + register the route.
    notify_progress(progress, :phase, (msg = "Starting chat session…",))
    ensure_project_session!(state, p)
    return p
end

"""
    create_project_from_worker!(srv, worker_name, worker_path;
                                 name, sync=false, resume_session_id=nothing, progress)

Register a project rooted at an existing folder ON THE WORKER. By default
NO bytes are pulled to the server — the project is immediately usable for
chat (which only needs `worker_path`), and the operator can later trigger an
async sync via `sync_project_to_server!` (e.g. the "Sync to server" button on
the project card or in the chat header menu). Pass `sync=true` to force a
synchronous pull at create time.

If `resume_session_id` is set to a claude-agent-acp session ID (the .jsonl
basename in `~/.claude/projects/<encoded>/`), the chat will use ACP's
`session/load` to resume that conversation — its history replays into the
chat UI and the agent regains full context. The ID persists across server
restarts.
"""
function create_project_from_worker!(state::ServerState, worker_name::String,
                                      worker_path::String;
                                      name::String = basename(rstrip(worker_path, '/')),
                                      sync::Bool = false,
                                      resume_session_id::Union{String,Nothing} = nothing,
                                      start_session::Bool = true,
                                      progress = nothing)
    # `start_session=false` skips the post-registration ACP session
    # bring-up. Used by tests that exercise the import logic without
    # needing a real worker subprocess; production callers always want
    # the chat ready, so the default stays `true`.
    maybe_start = p -> start_session && ensure_project_session!(state, p)
    haskey(state.workers[], worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty (folder has no basename?)")
    occursin(r"^[a-zA-Z0-9_\-]+$", name) ||
        error("Project name must be alphanumeric/_/- only — got '$name'")
    isempty(worker_path) && error("Worker path is required (pick a folder).")

    # Threads: a folder can hold several conversations, identified by
    # (worker, path, chat_id) where chat_id is the claude session id. Importing
    # the SAME session id reuses its thread; importing a DIFFERENT session of
    # the same folder creates a sibling thread; a no-session import
    # (resume_session_id === nothing) always starts a fresh thread. This is the
    # fix for "opening a folder→subchat locks that one in".
    existing = find_thread(state, worker_name, worker_path, resume_session_id)
    if existing !== nothing
        @info "create_project_from_worker!: reusing existing thread" id=existing.id name=existing.name session=resume_session_id
        notify_progress(progress, :phase, (msg = "Reusing existing chat…",))
        maybe_start(existing)
        return existing
    end

    # Same-name-different-(worker,path) is NOT a collision: we want to let
    # each worker have its own "BonitoAgents" project that opens to its own
    # chat. server_path is disambiguated via `compute_server_path` (which
    # prefixes the worker name), so the two mirrors live side-by-side.
    # Reconciling them is an explicit, sync-time operation — not an
    # open-time decision.
    id = string(uuid4())[1:8]
    server_path = compute_server_path(state, worker_name, name)

    p = ProjectInfo(id, name, worker_name, server_path, worker_path, now(UTC))
    p.resume_session_id = resume_session_id
    lock(state.lock) do
        state.projects[][id] = p
    end

    if sync
        @info "Pulling project from worker" worker=worker_name worker_path server_path
        p.backup_status = :syncing
        try
            sync_dir_from_worker!(state, worker_name, worker_path, server_path; on_progress = progress)
            p.backup_status = :synced
            p.last_sync_at  = now(UTC)
        catch e
            p.backup_status = :unsynced
            rethrow(e)
        end
    else
        notify_progress(progress, :phase, (msg = "Registered (no sync)",))
        @info "Registering project from worker (no sync)" worker=worker_name worker_path
    end

    lock(state.lock) do
        save_projects!(state)
    end
    safe_notify!(state.projects)

    notify_progress(progress, :phase, (msg = "Starting chat session…",))
    maybe_start(p)
    return p
end

# Triggered by the chat header's "Sync to server" menu item. Looks up the
# project, runs sync_project_to_server! in a Task, pushes status updates
# back to the chat's sync_status observable so the menu shows progress
# without redirecting to the dashboard.
function handle_chat_sync_click(state::ServerState, project_id::AbstractString,
                                 sync_status::Observable{String})
    haskey(state.projects[], project_id) || (safe_set!(sync_status, "unknown project"); return)
    p = state.projects[][project_id]
    p.backup_status === :syncing && (safe_set!(sync_status, "already syncing…"); return)
    safe_set!(sync_status, "starting…")
    @async begin
        try
            sync_project_to_server!(state, p;
                on_progress = (stage, info) ->
                    safe_set!(sync_status, format_progress_string(stage, info)))
            safe_set!(sync_status,
                "✓ synced $(Dates.format(p.last_sync_at, "HH:MM:SS")) UTC")
        catch e
            bt = catch_backtrace()
            @warn "handle_chat_sync_click failed" project=p.name exception=(e, bt)
            safe_set!(sync_status, "failed: $(sprint(showerror, e))")
        end
    end
    return
end

"""
    sync_project_to_server!(state, p::ProjectInfo; on_progress=nothing)

Pull the worker's current `worker_path` into the project's server-side
mirror via librsync. Resumable — only changed bytes go over the wire.
Updates `p.backup_status` to `:syncing` for the duration, then `:synced`
on success or `:stale` on failure.
"""
function sync_project_to_server!(state::ServerState, p::ProjectInfo; on_progress = nothing)
    haskey(state.workers[], p.worker_id) ||
        error("Worker '$(p.worker_id)' is not connected")
    # Atomic test-and-set of `backup_status` under the lock (T7). The unlocked
    # "is it :syncing? → set :syncing" had a window where two receivers both
    # passed the check and both started writing the same server directory. One
    # locked transition makes the loser error out cleanly.
    lock(state.lock) do
        p.backup_status === :syncing &&
            error("Project '$(p.name)' is already syncing")
        p.backup_status = :syncing
    end
    safe_notify!(state.projects)
    try
        sync_dir_from_worker!(state, p.worker_id, p.worker_path, p.server_path;
                              on_progress = on_progress)
        p.backup_status = :synced
        p.last_sync_at  = now(UTC)
        save_projects!(state)
        safe_notify!(state.projects)
    catch e
        p.backup_status = :stale
        safe_notify!(state.projects)
        rethrow(e)
    end
    return p
end

"""
    ensure_project_session!(state, p; target_worker="", progress=nothing) → ChatModel

Build (or return) the chat ChatModel for `p` running on `target_worker`.

If `target_worker` is unset or matches the project's current `worker_id`,
this is the fast path: returns the cached model or builds + claims on the
current worker. Idempotent.

If `target_worker` is a *different* online worker, this routes through
`start!` to run the full transparent-move flow (pre-pull from current
worker → push to target → re-bind → claim). The user-visible effect is
"opening the chat on B"; the file shuffling underneath is bookkeeping.

Called from project creation flows, worker reconnect, and the dashboard's
"Open chat on <worker>" handler. The unified app's main panel pulls the
cached model out of state.chat_models when the user selects this project
in the sidebar.
"""
function ensure_project_session!(state::ServerState, p::ProjectInfo;
                                  target_worker::AbstractString = "",
                                  progress = nothing)
    # When a target worker is specified that differs from the current
    # owner, delegate to `start!` which handles the atomic move. The
    # `start!` body updates `p.worker_id` and then calls back here with
    # no `target_worker` — so we hit the fast path below on the way out.
    if !isempty(target_worker) && String(target_worker) != p.worker_id
        return start!(state, p, target_worker; progress = progress)
    end
    # Funnel concurrent bring-ups for the SAME project through ONE in-flight
    # task (T1). Without this, two tabs opening the same project both pass the
    # unlocked `haskey(state.chat_models, p.id)` check (the cache write happens
    # seconds later, at the end of `start_chat_client!`), spawn two
    # claude-agent-acp processes on the worker, and the second ChatModel
    # overwrites the first — orphaning a live agent + its stream task.
    #
    # Same pattern as RESTART_INFLIGHT: under `state.lock` we either find a live
    # bring-up task to await, find the finished cache entry, or insert OUR task
    # as the in-flight placeholder before releasing the lock. The check, the
    # cache lookup, and the task insertion are one atomic step.
    local task::Task
    own = lock(state.lock) do
        haskey(state.chat_models, p.id) && return (state.chat_models[p.id]::ChatModel, false)
        existing = get(state.session_inflight, p.id, nothing)
        if existing !== nothing
            return (existing, false)
        end
        t = @task bring_up_project_session!(state, p; progress = progress)
        state.session_inflight[p.id] = t
        task = t
        return (t, true)
    end
    if own[2]
        # We own the bring-up: schedule the task, ensure the inflight entry is
        # cleared on completion (success OR failure) before we surface the
        # result, so a failed bring-up doesn't wedge later callers.
        schedule(task)
        try
            return fetch_bring_up(task)
        finally
            lock(state.lock) do
                get(state.session_inflight, p.id, nothing) === task &&
                    delete!(state.session_inflight, p.id)
            end
        end
    else
        # Someone else owns it (or it's already cached).
        winner = own[1]
        winner isa Task && return fetch_bring_up(winner)
        return winner
    end
end

# `fetch` on a failed task wraps the cause in a `TaskFailedException`; callers
# (e.g. the loading view's `sprint(showerror, e)`) expect the ORIGINAL error
# `ensure_project_session!` used to throw directly, so unwrap it.
function fetch_bring_up(t::Task)
    try
        return fetch(t)
    catch e
        e isa TaskFailedException && throw(t.result)
        rethrow()
    end
end

# project_id → in-flight `ensure_project_session!` bring-up task. Guarded by
# `state.lock` (the same lock that guards `chat_models`), so the "is it cached /
# is a bring-up in flight / start one" decision is atomic. Keyed by the stable
# project id (a String) rather than the ProjectInfo so two per-session views of
# the same project funnel together. Entry lifetime is one bring-up.

# The actual bring-up, run inside the single in-flight task funnelled by
# `ensure_project_session!`. Never call this directly from concurrent callers —
# go through `ensure_project_session!` so duplicates collapse.
function bring_up_project_session!(state::ServerState, p::ProjectInfo;
                                   progress = nothing)
    haskey(state.workers[], p.worker_id) ||
        error("Worker '$(p.worker_id)' is not connected")
    w = state.workers[][p.worker_id]

    # Opening a chat un-closes it: a previously ✕-dismissed thread is being
    # brought back, so it must reappear in the homebar. Persist + notify so the
    # sidebar re-adds the entry (every bring-up path is user-initiated open —
    # worker reconnect does NOT auto-bring-up, so this never resurrects a chat
    # the user closed).
    if p.dismissed
        p.dismissed = false
        lock(state.lock) do; save_projects!(state); end
        safe_notify!(state.projects)
    end

    claim_project!(state, p, w.worker_id)

    # The worker reports its BonitoMCP launch as a `julia` binary (`mcp_path`)
    # plus an argv array (`mcp_args`) — no shell wrapper, so it's identical on
    # Windows. claude-agent-acp spawns `command + args` directly.
    # `env` carries the eval-worker dial-back coordinates so BonitoMCP's eval
    # session can connect back to the server for interactive app proxying.
    #
    # The server name must NOT collide with any MCP server the user has in their
    # global/project config: claude-agent-acp runs the agent with
    # settingSources ["user","project","local"], so it ALSO loads the user's
    # `~/.claude.json` mcpServers. A same-named (e.g. stale/broken) entry there
    # shadows the one we inject here, and the tools silently vanish. `btworker`
    # is deliberately specific to avoid that — see `mcp__btworker__*` tool names.
    mcp = isempty(w.mcp_path) ? AgentClientProtocol.MCPServer[] :
        [AgentClientProtocol.MCPServer("btworker", w.mcp_path;
                                       args = w.mcp_args,
                                       env  = eval_dialback_env(state, p.id))]

    # The agent carries everything start! needs — including the
    # `resume_session_id` so the worker bring-up path uses session/load
    # instead of session/new for imported claude sessions.
    agent = WorkerAgent(state, w.worker_id, p.worker_path;
                        mcp               = mcp,
                        resume_session_id = p.resume_session_id)

    # Ensure server_path exists so BonitoBook (which reads files from cwd to
    # render the chat notebook + tools) doesn't crash on a never-synced
    # project. Empty dir is fine; project files live on the worker and only
    # get pulled here if the user clicks "Sync to server".
    mkpath(p.server_path)

    model = ChatModel(state, p.server_path;
                       project_id  = p.id,
                       mcp_servers = mcp,
                       agent       = agent)
    register_chat_model!(model)      # LAZY: register for viewing; bind on first turn

    # A RESUMED chat keeps its conversation only in claude's session — it replays
    # via `session/load` when the agent binds. Lazy binding defers that to the
    # first turn, so a freshly imported chat (no server-side `chat.md` history
    # yet) opens BLANK until the user types ("an old chat is sometimes empty").
    # When we're resuming and have no local history to show, bind the agent NOW
    # so the history replays straight away. Async so the chat view still mounts
    # instantly; the replayed `msgs.count` fills it in. (A chat that already has
    # `chat.md` history renders it immediately and needs no eager bind — and
    # skipping it there also avoids a needless `reconcile_replay!`.)
    # ALSO bind eagerly when we DO have local history but the session's jsonl
    # has advanced since our last reconcile (the user continued the session in
    # the Claude Code CLI / another server): without this the chat shows a
    # frozen snapshot until the first send — and the bind-triggered reconcile
    # then floods the adopted history in around the user's message. The
    # watermark is a per-chat stamp file updated after every reconcile; the
    # session's freshness comes from the worker scan (`state.discovered`).
    if p.resume_session_id !== nothing &&
       (isempty(shared(model).msgs_store) || session_advanced_since_sync(state, p))
        Base.errormonitor(@async try
            restart_chat_session!(model)
        catch e
            @warn "eager history replay on open failed" project_id = p.id exception = (e, catch_backtrace())
        end)
    end

    fire_auto_prompt!(model)
    return model
end

# Short alias used by the move/copy plumbing below + the "Sync to server"
# button. `sync_project_to_server!` is the long, explicit name; both refer
# to the same operation: pull the worker's current state into the server's
# canonical mirror.
sync!(state::ServerState, p::ProjectInfo; progress = nothing) =
    sync_project_to_server!(state, p; on_progress = progress)

"""
    stop_session!(state, p)

Tear down the active ACP session for `p`: `stop!` the WorkerAgent (the
worker sees the WS drop and reaps the claude subprocess), evict the
ChatModel from `state.chat_models`, and release the project lock. Safe to
call when no session is active — it just no-ops.
"""
function stop_session!(state::ServerState, p::ProjectInfo)
    model = lock(state.lock) do
        m = get(state.chat_models, p.id, nothing)
        m === nothing || delete!(state.chat_models, p.id)
        filter!(!=(p.id), state.bound_lru)   # drop from the live-agent LRU
        m
    end
    # close is idempotent + total now; a real error here is worth surfacing.
    # `close(model)` (T4) closes `user_messages` (ending the `run_chat!` consumer)
    # and the TaskBar's own 1 Hz poll loop — without it both leak forever, the
    # running loops keeping the ChatModel referenced. Close the model BEFORE the
    # client so the consumer's `for … in user_messages` exits cleanly rather
    # than erroring on a torn-down client mid-turn.
    if model !== nothing
        close(model)
        # Tear down the agent's ACP CONNECTION. `stop!(agent)` → `close(client)`
        # → `close(conn)` sets `conn.closed = true` BEFORE closing the socket, so
        # the reader loop exits on its `while !conn.closed` guard (a plain
        # transport close would leave `conn.closed == false` and spin the reader
        # at 100% CPU). `stop!` is idempotent + total: a never-started agent just
        # no-ops. `permanent=true` latches the agent dead: a turn buffered past
        # this close must not lazily re-bind it into an orphaned subprocess (the
        # leak_cycle leak). Unlike the restart path's `stop!(model.agent)`, a
        # closed chat never reuses THIS agent — a reopen builds a fresh one.
        stop!(model.agent; permanent = true)
        notify_chats!(state)   # drop from the active-chats sidebar
    end
    release_project!(state, p)
    # The reaped claude subprocess takes its MCP server + eval worker with it, so
    # the eval bridge's worker session is gone — tear the bridge down explicitly
    # (a WS drop alone no longer does; its lifetime is the worker session).
    teardown_eval_bridge!(state, p.id)
    return nothing
end

"""
    transfer_project!(state, p, target_worker_id; progress=nothing)

File-shuffling half of a project move. Pre-pulls from the current
worker (if online), pushes the server's mirror to `target_worker_id`,
then re-binds `p.worker_id` / `p.worker_path` / clears
`resume_session_id`. Does NOT bring up a chat session — that's
`ensure_project_session!`'s job. `start!` chains the two together.

Split out from `start!` so the file-movement contract can be tested
without standing up an ACP session.
"""
function transfer_project!(state::ServerState, p::ProjectInfo,
                            target_worker_id::AbstractString;
                            progress = nothing)
    target_id = String(target_worker_id)
    haskey(state.workers[], target_id) ||
        error("Unknown worker: $target_id")
    target_w = state.workers[][target_id]
    isopen(target_w) ||
        error("Worker '$(target_w.name)' is offline")
    target_id == p.worker_id && return p   # no-op

    target_path = joinpath(target_w.projects_root, p.name)
    notify_progress(progress, :phase,
        (msg = "Stopping session on $(p.worker_id)…",))
    stop_session!(state, p)

    # Pre-pull: if the source worker is online, capture its latest
    # filesystem state into the server's mirror BEFORE we push. Without
    # this, any edits made on the source worker in an external editor
    # since the last "Sync to server" would be silently lost on the move.
    source_online = haskey(state.workers[], p.worker_id) &&
                    isopen(state.workers[][p.worker_id])
    if source_online
        source_name = state.workers[][p.worker_id].name
        notify_progress(progress, :phase,
            (msg = "Pulling latest from $(source_name)…",))
        try
            sync_project_to_server!(state, p; on_progress = progress)
        catch e
            # Stale-mirror fallback: prefer continuing the move with
            # whatever the server has over aborting. Surfaced as a warning
            # so the user can see they were on the optimistic path.
            @warn "pre-pull from source worker failed; continuing with server's existing mirror" project=p.name source=p.worker_id exception=e
        end
    else
        @info "source worker offline; moving from server's existing mirror" project=p.name source=p.worker_id target=target_id
    end

    notify_progress(progress, :phase,
        (msg = "Pushing $(p.name) → $(target_w.name)…",))
    sync_dir_to_worker!(state, target_id, p.server_path, target_path;
                         on_progress = progress)

    # Re-bind. resume_session_id cleared because claude's jsonl lives on
    # the old worker's fs and isn't transportable. Persistent state is
    # written before we return so a server crash mid-`start!` (between
    # this point and ensure_project_session!) doesn't leave projects.json
    # disagreeing with the bytes on disk.
    p.worker_id          = target_id
    p.worker_path        = target_path
    p.resume_session_id  = nothing
    save_projects!(state)
    safe_notify!(state.projects)
    return p
end

"""
    start!(state, p, worker_id; progress=nothing) → ChatModel

Bring up `p`'s chat session on `worker_id`, transparently re-syncing
through the server. The server is the source of truth; workers are
caches that may drift between sessions (the user might edit files in
their own editor on the worker's filesystem outside BonitoAgents).

If `worker_id == p.worker_id` this is just `ensure_project_session!`.

Otherwise: `transfer_project!` does the atomic file-move (pre-pull
from source → push to target → re-bind), then a fresh session boots
on the target.

Failure semantics: if any step before `transfer_project!`'s re-bind
fails, `worker_id` is NOT flipped — the project remains bound to the
source. The error propagates to the caller (the dashboard's open-on
handler renders it in the error banner).
"""
function start!(state::ServerState, p::ProjectInfo, worker_id::AbstractString;
                progress = nothing)
    target_id = String(worker_id)
    if target_id == p.worker_id
        return ensure_project_session!(state, p)
    end
    transfer_project!(state, p, target_id; progress = progress)
    notify_progress(progress, :phase,
        (msg = "Starting chat on $(state.workers[][target_id].name)…",))
    return ensure_project_session!(state, p)
end

"""
    copy_to!(state, p, target_worker_id; name=p.name, progress=nothing) → ProjectInfo

Snapshot `p` to a new project on `target_worker_id` via the server. Source
project is left untouched. Steps: (1) `sync!(p)` so the server has the
latest of the source, (2) seed a fresh server-side mirror at
`working_dir/<name>` (collision-free via `-<id>` suffix if needed), (3)
push that mirror to `target_worker_id:projects_root/<name>`, (4) register
a new ProjectInfo. The new project starts un-resumed (fresh claude session
when the user opens its chat).
"""
function copy_to!(state::ServerState, p::ProjectInfo, target_worker_id::AbstractString;
                  name::AbstractString = p.name,
                  progress = nothing)
    target_id = String(target_worker_id)
    haskey(state.workers[], target_id) ||
        error("Unknown worker: $target_id")
    target_w = state.workers[][target_id]
    occursin(r"^[a-zA-Z0-9_\-]+$", String(name)) ||
        error("Project name must be alphanumeric/_/- only — got '$name'")

    target_path = joinpath(target_w.projects_root, String(name))
    existing = find_project_by_location(state, target_id, target_path)
    existing === nothing ||
        error("$(target_w.name) already has a project at $(target_path)")

    # 1. Pull source worker → server, so server has latest. Safe to skip
    # if source worker is offline — we still copy from whatever's on disk.
    if haskey(state.workers[], p.worker_id) &&
       isopen(state.workers[][p.worker_id])
        notify_progress(progress, :phase,
            (msg = "Pulling latest from $(p.worker_id)…",))
        sync!(state, p; progress = progress)
    else
        notify_progress(progress, :phase,
            (msg = "Source worker offline — copying server snapshot…",))
    end

    # 2. Fresh server-side mirror under the target's name. Collision-free
    # via short id suffix if working_dir already has a folder by that name.
    new_id = string(uuid4())[1:8]
    base_server_path = joinpath(state.working_dir, String(name))
    new_server_path  = ispath(base_server_path) ?
        "$(base_server_path)-$(new_id)" : base_server_path
    mkpath(dirname(new_server_path))
    if isdir(p.server_path)
        run(`rsync -a $(rstrip(p.server_path, '/'))/ $(rstrip(new_server_path, '/'))/`)
    else
        mkpath(new_server_path)
    end

    # 3. Push server → target worker.
    notify_progress(progress, :phase,
        (msg = "Pushing copy → $(target_w.name)…",))
    sync_dir_to_worker!(state, target_id, new_server_path, target_path;
                         on_progress = progress)

    # 4. Register the new project.
    new_p = ProjectInfo(new_id, String(name), target_id,
                         new_server_path, target_path, now(UTC))
    new_p.backup_status = :synced
    new_p.last_sync_at  = now(UTC)
    lock(state.lock) do
        state.projects[][new_id] = new_p
        save_projects!(state)
    end
    safe_notify!(state.projects)
    return new_p
end

# Dashboard styles — modern surface + spacing system, status dots, smooth transitions
const DashboardStyles = Bonito.Styles(
    # ── Tokens ───────────────────────────────────────────────────────────────
    CSS(":root",
        "--bt-bg"            => "#fafaf9",
        "--bt-surface"       => "#ffffff",
        "--bt-surface-2"     => "#f8fafc",
        "--bt-border"        => "rgba(15,23,42,0.08)",
        "--bt-border-strong" => "rgba(15,23,42,0.14)",
        "--bt-text"          => "#0f172a",
        "--bt-text-muted"    => "#64748b",
        "--bt-text-faint"    => "#94a3b8",
        "--bt-accent"        => "#3b82f6",
        "--bt-accent-hover"  => "#2563eb",
        "--bt-success"       => "#10b981",
        "--bt-error"         => "#ef4444",
        "--bt-shadow-sm"     => "0 1px 2px rgba(15,23,42,0.05)",
        "--bt-shadow-md"     => "0 4px 12px rgba(15,23,42,0.08)",
        "--bt-radius"        => "8px",
        "--bt-radius-sm"     => "6px"),

    # ── Shell ────────────────────────────────────────────────────────────────
    # No own max-width: the whole app is bounded by `.bt-shell` (defined in
    # sidebar.jl::UnifiedShellStyles). The dashboard fills whatever space the
    # main panel gives it, so the sidebar and the dashboard are visually
    # adjacent instead of being separated by an arbitrary gap.
    # `.bt-main` clips overflow (chat owns its own scroll region), so
    # `.bt-dash` becomes the dashboard's scroll container itself. Without
    # this, a long worker / project / discovered-session list overflows
    # the viewport with nowhere to scroll on mobile.
    CSS(".bt-dash",
        "font-family"  => "'Inter', system-ui, -apple-system, sans-serif",
        "font-size"    => "14px", "line-height" => "1.5",
        "color"        => "var(--bt-text)", "background" => "var(--bt-bg)",
        "flex"         => "1 1 auto", "min-height" => "0",
        "overflow-y"   => "auto",
        "padding"      => "32px 24px",
        "-webkit-font-smoothing" => "antialiased"),
    # Wrapper for a list of `.bt-card` rows. Single column today; we can
    # later switch to `repeat(auto-fit, minmax(420px, 1fr))` if the workers
    # / projects lists grow long.
    CSS(".bt-cards",
        "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    # Per-worker cell: the card + its (toggled-visible) picker form and
    # discover panel. Stacks vertically; toggled siblings collapse via
    # `bt-hidden`.
    CSS(".bt-worker-cell",
        "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    # Class-toggle helper used by WorkerCard for picker / discover / install
    # blocks: collapses the element without removing it from the DOM, so
    # interactive state (folder selection, scan results, focus) survives.
    CSS(".bt-hidden", "display" => "none !important"),
    # Wrappers around the toggled blocks; semantic class for the test
    # suite to query.
    CSS(".bt-form-wrapper", "display" => "block"),
    CSS(".bt-install-wrap", "display" => "block"),
    CSS(".bt-empty-wrap", "display" => "block"),
    # Per-project cell — sibling to the card slot, currently a thin pass-
    # through. Reserved for future per-project annexes (collision detail,
    # transfer progress, etc.) so the card itself stays compact.
    CSS(".bt-project-cell",
        "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    # Discover panel internals — section wrappers for the active /
    # historical KeyedLists, plus the errors-list block.
    CSS(".bt-discover-section",
        "display" => "flex", "flex-direction" => "column", "gap" => "6px"),
    CSS(".bt-errors-list",
        "display" => "flex", "flex-direction" => "column", "gap" => "4px"),

    # ── Header + tagline ─────────────────────────────────────────────────────
    # `wrap` so the recent-chats overview (flex-basis 100%, overview.jl) drops
    # onto its own full-width line under the wordmark + tagline row.
    CSS(".bt-header",
        "display" => "flex", "align-items" => "baseline",
        "flex-wrap" => "wrap",
        "justify-content" => "space-between", "gap" => "16px",
        "margin-bottom" => "4px"),
    CSS(".bt-header h1",
        "font-size" => "22px", "font-weight" => "600",
        "letter-spacing" => "-0.01em", "margin" => "0",
        "display" => "flex", "align-items" => "center", "gap" => "10px"),
    # The hexagon logo next to the wordmark — same asset as the favicon.
    CSS(".bt-logo",
        "width" => "28px", "height" => "28px",
        "display" => "block", "flex-shrink" => "0",
        "user-select" => "none"),
    CSS(".bt-tagline",
        "color" => "var(--bt-text-muted)", "font-size" => "13px"),

    # ── Stats strip ──────────────────────────────────────────────────────────
    CSS(".bt-stats",
        "display" => "flex", "gap" => "20px", "flex-wrap" => "wrap",
        "padding" => "12px 16px", "margin-top" => "16px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "font-size" => "13px"),
    CSS(".bt-stat",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-stat-value", "font-weight" => "600"),
    CSS(".bt-stat-label", "color" => "var(--bt-text-muted)"),
    CSS(".bt-stat-sep",   "color" => "var(--bt-text-faint)"),

    # ── Section headings ─────────────────────────────────────────────────────
    CSS(".bt-section",
        "display" => "flex", "align-items" => "baseline",
        "justify-content" => "space-between",
        "margin" => "32px 0 12px"),
    CSS(".bt-section h2",
        "font-size" => "11px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-muted)", "margin" => "0"),

    # ── Card ─────────────────────────────────────────────────────────────────
    CSS(".bt-card",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "14px 16px",
        "margin-bottom" => "8px",
        "display" => "flex", "flex-direction" => "column",
        "align-items" => "stretch", "gap" => "8px",
        "transition" => "border-color 120ms ease, box-shadow 120ms ease"),
    CSS(".bt-card:hover",
        "border-color" => "var(--bt-border-strong)",
        "box-shadow" => "var(--bt-shadow-sm)"),
    # The top row of a worker card — what `.bt-card` itself used to be (title +
    # actions on one line). The card is now a column so the nested project
    # `<details>` can sit beneath the row INSIDE the same pill chrome.
    CSS(".bt-card-row",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "16px"),
    CSS(".bt-card-body",
        "min-width" => "0", "flex" => "1 1 auto"),
    CSS(".bt-card-title",
        "font-weight" => "600", "font-size" => "14px",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "min-width" => "0"),
    # Name spans inside titles: don't break on hyphens, ellipsis when too long
    CSS(".bt-card-name",
        "min-width" => "0",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "white-space" => "nowrap",
        "word-break" => "keep-all"),
    # Remove-worker affordance: a faint ✕ pinned to the right of the title
    # row (margin-left:auto), turning red on hover so it reads as destructive.
    CSS(".bt-card-remove",
        "margin-left" => "auto",
        "flex-shrink" => "0",
        "cursor" => "pointer",
        "color" => "var(--bt-text-faint)",
        "font-size" => "13px",
        "line-height" => "1",
        "padding" => "2px 6px",
        "border-radius" => "var(--bt-radius-sm)",
        "user-select" => "none",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-card-remove:hover",
        "background" => "rgba(239,68,68,0.12)",
        "color" => "var(--bt-error)"),
    # Inline-editable variant for the worker name. Reads as plain text until
    # the user clicks/focuses it; on focus we surface a soft border so it's
    # discoverable that the field is editable.
    CSS("input.bt-card-name-edit",
        "border" => "none",
        "background" => "transparent",
        "padding" => "2px 6px",
        "margin" => "-2px -6px",
        "border-radius" => "var(--bt-radius-sm)",
        "font" => "inherit",
        "color" => "inherit",
        "min-width" => "0",
        "max-width" => "100%",
        "outline" => "none",
        "cursor" => "text",
        "transition" => "background 80ms, box-shadow 80ms"),
    CSS("input.bt-card-name-edit:hover",
        "background" => "var(--bt-surface-2)"),
    CSS("input.bt-card-name-edit:focus",
        "background" => "var(--bt-surface-2)",
        "box-shadow" => "inset 0 0 0 1px var(--bt-border-strong)"),
    # Worker initials `[XX]` tag — small monospace input next to the name.
    # Width fits ~4 chars + padding; sits flush, shows a subtle pill outline
    # so it reads as a tag rather than free text.
    CSS("input.bt-card-initials",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface-2)",
        "padding" => "1px 6px",
        "border-radius" => "999px",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11px",
        "font-weight" => "600",
        "color" => "var(--bt-text-muted)",
        "letter-spacing" => "0.04em",
        "text-align" => "center",
        "width" => "44px",
        "flex-shrink" => "0",
        "outline" => "none",
        "cursor" => "text",
        "transition" => "background 80ms, box-shadow 80ms"),
    CSS("input.bt-card-initials:hover",
        "background" => "var(--bt-surface)"),
    CSS("input.bt-card-initials:focus",
        "background" => "var(--bt-surface)",
        "box-shadow" => "inset 0 0 0 1px var(--bt-border-strong)",
        "color" => "var(--bt-text)"),
    # `[XX]` pill in front of a project's title — read-only mirror of the
    # worker's initials. Same pill shape as the editable input above so the
    # tag reads consistently across worker / project cards.
    CSS(".bt-card-worker-tag",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface-2)",
        "padding" => "1px 6px",
        "border-radius" => "999px",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11px",
        "font-weight" => "600",
        "color" => "var(--bt-text-muted)",
        "letter-spacing" => "0.04em",
        "flex-shrink" => "0"),
    # Folder name shown under the title as a meta line. Same tone as the
    # rest of `.bt-card-meta`; explicit class so the test suite can target it.
    CSS(".bt-card-folder-name",
        "color" => "var(--bt-text-muted)",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12px"),
    CSS(".bt-card-meta",
        "color" => "var(--bt-text-muted)", "font-size" => "12px",
        "margin-top" => "2px",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-card-actions",
        "display" => "flex", "gap" => "6px", "flex-shrink" => "0",
        "align-items" => "center"),
    CSS(".bt-mono",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11.5px",
        "color" => "var(--bt-text-faint)"),

    # ── Status dot ───────────────────────────────────────────────────────────
    CSS(".bt-dot",
        "display" => "inline-block",
        "width" => "8px", "height" => "8px",
        "border-radius" => "50%", "flex-shrink" => "0"),
    CSS(".bt-dot-online",
        "background" => "var(--bt-success)",
        "box-shadow" => "0 0 0 3px rgba(16,185,129,0.18)"),
    CSS(".bt-dot-offline", "background" => "var(--bt-error)"),
    CSS(".bt-dot-unknown", "background" => "var(--bt-text-faint)"),

    # ── Pill (small text-bearing badge) ──────────────────────────────────────
    CSS(".bt-pill",
        "display" => "inline-flex", "align-items" => "center",
        "padding" => "1px 8px",
        "border-radius" => "999px",
        "font-size" => "11px", "font-weight" => "500",
        "letter-spacing" => "0.02em",
        # Keep pill text on a single line and don't let the flex parent
        # shrink the pill below its content width — otherwise "not backed
        # up" wraps onto three lines inside the card title row on mobile.
        "white-space" => "nowrap", "flex-shrink" => "0"),
    CSS(".bt-pill-active",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-pill-online",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-pill-muted",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text-muted)"),
    CSS(".bt-pill-warn",
        "background" => "rgba(234,179,8,0.15)", "color" => "#a16207"),
    CSS(".bt-pill-syncing",
        "background" => "rgba(59,130,246,0.12)", "color" => "#1d4ed8",
        "gap" => "6px"),

    # ── Buttons ──────────────────────────────────────────────────────────────
    CSS(".bt-btn",
        "appearance" => "none", "border" => "none",
        "padding" => "7px 12px",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-accent)", "color" => "#fff",
        "font-size" => "13px", "font-weight" => "500",
        "cursor" => "pointer",
        # Never break the label across lines — on narrow viewports `.bt-section`
        # / `.bt-card-actions` would otherwise let "+ New project" wrap to two
        # lines inside the button.
        "white-space" => "nowrap",
        "display" => "inline-flex", "align-items" => "center", "gap" => "6px",
        "transition" => "background 120ms ease, transform 80ms ease, opacity 120ms ease, color 120ms"),
    CSS(".bt-btn:hover",  "background" => "var(--bt-accent-hover)"),
    CSS(".bt-btn:active", "transform" => "translateY(1px)"),
    CSS(".bt-btn-secondary",
        "background" => "var(--bt-surface)", "color" => "var(--bt-text)",
        "border" => "1px solid var(--bt-border-strong)"),
    CSS(".bt-btn-secondary:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-btn-ghost",
        "background" => "transparent", "color" => "var(--bt-text-muted)",
        "padding" => "6px 8px"),
    CSS(".bt-btn-ghost:hover",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text)"),
    CSS(".bt-btn-loading",
        "opacity" => "0.7", "cursor" => "wait"),
    CSS(".bt-btn-sm",
        "padding" => "3px 9px", "font-size" => "12px"),

    # ── Forms ────────────────────────────────────────────────────────────────
    CSS(".bt-form",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "16px", "margin-top" => "12px",
        "display" => "grid",
        # minmax(0, 1fr) lets the column shrink below content min-width so the
        # picker's address bar can scroll horizontally without expanding the form
        "grid-template-columns" => "120px minmax(0, 1fr)",
        "gap" => "12px 16px", "align-items" => "start"),
    CSS(".bt-form label",
        "color" => "var(--bt-text-muted)", "font-size" => "13px",
        "padding-top" => "8px"),
    CSS(".bt-form input, .bt-form select",
        "padding" => "8px 10px",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "14px",
        "background" => "var(--bt-surface)",
        "width" => "100%", "box-sizing" => "border-box",
        "outline" => "none",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-form input:focus, .bt-form select:focus",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-form-actions",
        "grid-column" => "1 / -1",
        "display" => "flex", "gap" => "8px",
        "justify-content" => "flex-end",
        "padding-top" => "4px"),
    CSS(".bt-form-hint",
        "color" => "#047857", "font-size" => "12px", "margin-top" => "4px"),

    # ── Notices ──────────────────────────────────────────────────────────────
    CSS(".bt-error",
        "background" => "#fef2f2", "color" => "#b91c1c",
        "border" => "1px solid #fee2e2",
        "padding" => "10px 12px",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "13px", "margin-top" => "12px"),
    CSS(".bt-empty",
        "color" => "var(--bt-text-faint)", "font-size" => "13px",
        "padding" => "20px",
        "text-align" => "center",
        "border" => "1px dashed var(--bt-border)",
        "border-radius" => "var(--bt-radius)"),

    # ── Folder picker ────────────────────────────────────────────────────────
    CSS(".bt-picker",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "6px",
        "background" => "var(--bt-surface)",
        "max-height" => "260px", "overflow-y" => "auto",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px"),
    CSS(".bt-picker-row",
        "padding" => "5px 8px",
        "border-radius" => "4px", "cursor" => "pointer",
        "transition" => "background 80ms"),
    CSS(".bt-picker-row:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-picker-cur",
        "display" => "flex", "align-items" => "center",
        "gap" => "8px", "margin-bottom" => "8px",
        "flex-wrap" => "wrap",
        "min-width" => "0"),
    # ── Windows-style address bar ────────────────────────────────────────────
    CSS(".bt-addr-bar",
        "flex" => "1 1 0",   "min-width" => "0",
        "display" => "flex", "align-items" => "center",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "2px 4px",
        "min-height" => "32px",
        "cursor" => "text",
        "overflow-x" => "auto",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-addr-bar:hover",
        "border-color" => "var(--bt-accent)"),
    CSS(".bt-addr-seg",
        "padding" => "4px 6px",
        "border-radius" => "4px",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12px",
        "color" => "var(--bt-text)",
        "white-space" => "nowrap",
        "cursor" => "pointer",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-addr-seg:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    CSS(".bt-addr-seg-root",
        "padding" => "4px 4px"),
    CSS(".bt-addr-chevron",
        "color" => "var(--bt-text-faint)",
        "user-select" => "none",
        "padding" => "0 1px",
        "font-size" => "11px",
        "flex-shrink" => "0"),
    # Empty area to the right of the segments — clicking it enters edit mode
    CSS(".bt-addr-filler",
        "flex" => "1 1 auto", "min-width" => "8px",
        "align-self" => "stretch",
        "cursor" => "text"),
    CSS(".bt-addr-input",
        "flex" => "1 1 auto", "min-width" => "0",
        "padding" => "6px 10px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-accent)",
        "border-radius" => "var(--bt-radius-sm)",
        "min-height" => "32px",
        "box-sizing" => "border-box",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12px",
        "color" => "var(--bt-text)",
        "outline" => "none",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-addr-icon-btn",
        "background" => "transparent", "border" => "none",
        "color" => "var(--bt-text-faint)", "cursor" => "pointer",
        "padding" => "4px 6px", "border-radius" => "4px",
        "font-size" => "13px",
        "transition" => "background 80ms, color 80ms",
        "flex-shrink" => "0"),
    CSS(".bt-addr-icon-btn:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    CSS(".bt-picker-loading",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "color" => "var(--bt-text-muted)",
        "padding" => "12px", "font-size" => "12px"),

    # ── Discover panel (collapsable <details>) ───────────────────────────────
    # `<details>` keeps the worker pill compact by default; clicking the header
    # toggles the folder→threads tree. Rescan inside the summary
    # preventDefault's the toggle and force-opens, so scan progress is visible.
    # Nested inside `.bt-card` now — no separate pill chrome (the card's
    # background/border IS the chrome). A faint top divider separates the
    # "▸ projects (N)" toggle from the worker title row above it.
    CSS(".bt-card > details.bt-discover-panel",
        "background" => "transparent",
        "border" => "none",
        "border-top" => "1px solid var(--bt-border)",
        "border-radius" => "0",
        "padding" => "8px 0 0", "margin" => "0"),
    CSS(".bt-card > details.bt-discover-panel[open]", "padding-bottom" => "4px"),
    CSS(".bt-discover-header",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between",
        "cursor" => "pointer",
        "list-style" => "none",
        # Add some breathing room between the chevron and title.
        "gap" => "10px",
        # The toggle is meant to be unobtrusive — small text, muted by default,
        # full-color on hover (the :hover rule below).
        "font-size" => "12px",
        "color" => "var(--bt-text-muted)"),
    CSS("details[open] > .bt-discover-header", "margin-bottom" => "10px"),
    # Hide the default disclosure triangle (Chrome / Safari).
    CSS(".bt-discover-header::-webkit-details-marker", "display" => "none"),
    # Custom chevron — matches `.bt-group-summary::before` so the two collapsable
    # surfaces feel like one design language.
    CSS(".bt-discover-header::before",
        "content" => "\"▸\"",
        "color" => "var(--bt-text-faint)", "font-size" => "10px",
        "flex-shrink" => "0"),
    CSS("details.bt-discover-panel[open] > .bt-discover-header::before",
        "content" => "\"▾\""),
    CSS(".bt-discover-header:hover",
        "background" => "var(--bt-surface)"),
    CSS(".bt-discover-title",
        "font-weight" => "500", "font-size" => "12px",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-discover-actions",
        "display" => "flex", "gap" => "6px", "align-items" => "center",
        "flex-shrink" => "0"),

    CSS(".bt-section-label",
        "font-size" => "10.5px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-faint)",
        "margin" => "12px 4px 6px"),
    CSS(".bt-session-row",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between",
        "gap" => "8px",
        "padding" => "10px 12px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "margin-bottom" => "6px",
        "transition" => "border-color 120ms"),
    # `min-width: 0` lets the path ellipsize instead of pushing the
    # Import/Resume button off the row's right edge.
    CSS(".bt-session-info",
        "min-width" => "0", "flex" => "1 1 auto"),
    CSS(".bt-session-row:hover",
        "border-color" => "var(--bt-border-strong)"),
    CSS(".bt-session-name",
        "font-weight" => "600", "font-size" => "13px",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "min-width" => "0"),
    # The name string lives inside this span (rather than as a raw text
    # node) so it can ellipsize when the parent row is narrow. Without
    # this, a long name like "ClaudeExperiments" pushes the active badge
    # under the Resume button on mobile.
    CSS(".bt-session-name-text",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "white-space" => "nowrap",
        "min-width" => "0"),
    CSS(".bt-session-path",
        "font-family" => "ui-monospace, monospace", "font-size" => "11px",
        "color" => "var(--bt-text-muted)", "margin-top" => "2px",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    # First-user-prompt preview shown in place of the path inside group rows.
    # Italic + slightly larger than the mono path so it reads as content,
    # not metadata. One-line ellipsis; truncation happens server-side at
    # PREVIEW_MAX_CHARS so the layout stays predictable.
    CSS(".bt-session-preview",
        "font-size" => "11.5px",
        "color" => "var(--bt-text-muted)", "margin-top" => "2px",
        "font-style" => "italic",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".bt-session-meta",
        "font-size" => "11px",
        "color" => "var(--bt-text-faint)", "margin-top" => "2px"),

    # ── Project-group disclosure (two-level session list) ────────────────────
    # One <details> per project cwd; expands to reveal child .bt-session-row
    # widgets. Chevron is a CSS `::before` content swap on `[open]`, never a
    # `transform: rotate()` — same reason documented for `.bt-subsection-*`.
    CSS(".bt-group",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-surface)",
        "margin-bottom" => "6px",
        "overflow" => "hidden"),
    CSS(".bt-group-summary",
        "display" => "flex", "align-items" => "baseline", "gap" => "10px",
        "padding" => "10px 12px",
        "cursor" => "pointer",
        "list-style" => "none",
        "background" => "var(--bt-surface)"),
    CSS(".bt-group-summary::-webkit-details-marker", "display" => "none"),
    CSS(".bt-group-summary::before",
        "content" => "\"▸\"",
        "color" => "var(--bt-text-faint)", "font-size" => "10px",
        "flex-shrink" => "0"),
    CSS("details.bt-group[open] > .bt-group-summary::before",
        "content" => "\"▾\""),
    CSS(".bt-group-summary:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-group-name",
        "font-weight" => "600", "font-size" => "13px",
        "flex-shrink" => "0"),
    CSS(".bt-group-path",
        "font-family" => "ui-monospace, monospace", "font-size" => "11px",
        "color" => "var(--bt-text-muted)",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap", "min-width" => "0",
        "flex" => "1 1 auto"),
    CSS(".bt-group-meta",
        "font-size" => "11px", "color" => "var(--bt-text-faint)",
        "flex-shrink" => "0"),
    # "+ New thread" in a folder's summary row — reveal on hover so it doesn't
    # clutter the collapsed list.
    CSS(".bt-new-thread",
        "flex-shrink" => "0",
        "font-size" => "11px", "font-weight" => "500",
        "color" => "var(--bt-accent)", "cursor" => "pointer",
        "padding" => "2px 8px", "border-radius" => "var(--bt-radius-sm)",
        "white-space" => "nowrap",
        "opacity" => "0", "transition" => "opacity 80ms, background 80ms"),
    CSS(".bt-group-summary:hover .bt-new-thread", "opacity" => "1"),
    CSS(".bt-new-thread:hover", "background" => "var(--bt-surface-2)"),
    CSS(".bt-group-body",
        "padding" => "8px 10px 4px",
        "border-top" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface-2)"),
    # Child rows inside a group — drop their own border so the group's
    # border carries the visual outer frame.
    CSS(".bt-group-body .bt-session-row",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)"),

    # ── Spinner ──────────────────────────────────────────────────────────────
    CSS(".bt-spinner-row",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "color" => "var(--bt-text-muted)", "font-size" => "13px"),
    # Per-side borders so the accent arc shows (the `border` shorthand was
    # overriding `border-top-color` → uniform grey ring, invisible rotation).
    CSS(".bt-spinner",
        "width" => "14px", "height" => "14px",
        "border-radius" => "50%", "box-sizing" => "border-box",
        "border-top" => "2px solid var(--bt-accent)",
        "border-right" => "2px solid var(--bt-border)",
        "border-bottom" => "2px solid var(--bt-border)",
        "border-left" => "2px solid var(--bt-border)",
        "will-change" => "transform",   # compositor-driven; survives main-thread jank
        "animation" => "bt-spin 0.7s linear infinite",
        "flex-shrink" => "0"),
    CSS(".bt-spinner-sm",
        "width" => "11px", "height" => "11px", "border-width" => "1.5px"),
    # MUST have an explicit `from`: with only `to { rotate(360deg) }` the
    # browser interpolates from the element's base transform (a matrix) to
    # rotate(360deg) — which is the identity matrix — so it never visibly turns.
    # Both keyframes using rotate() makes it an ANGLE interpolation (0°→360°).
    CSS("@keyframes bt-spin",
        CSS("from", "transform" => "rotate(0deg)"),
        CSS("to", "transform" => "rotate(360deg)")),

    # ── Chat loading screen (project_loading_view) ───────────────────────────
    # Centered in the main panel while a chat's ACP session is brought up, or
    # to explain that the project's worker is offline.
    CSS(".bt-loading",
        "flex" => "1 1 auto",
        "display" => "flex", "flex-direction" => "column",
        "align-items" => "center", "justify-content" => "center",
        "gap" => "12px", "padding" => "40px", "text-align" => "center"),
    # `will-change: transform` promotes the spinner to its own compositor
    # layer so the rotation keeps running while the main thread is busy —
    # which it very much is right when this spinner shows (chat bring-up:
    # Monaco bundle eval, virtual-scroll measuring). Without the promotion
    # the animation runs on the main thread and freezes for seconds at a
    # time — "the spinner doesn't spin".
    # Per-side borders (not the `border` shorthand + `border-top-color`) so the
    # accent arc never depends on property emission order — the shorthand was
    # overriding the top colour, leaving a uniform grey ring with no visible
    # arc. `will-change: transform` keeps the rotation on the compositor while
    # the main thread is busy during bring-up.
    CSS(".bt-loading-spinner",
        "width" => "30px", "height" => "30px",
        "border-radius" => "50%",
        "box-sizing" => "border-box",
        "border-top" => "3px solid var(--bt-accent)",
        "border-right" => "3px solid var(--bt-border)",
        "border-bottom" => "3px solid var(--bt-border)",
        "border-left" => "3px solid var(--bt-border)",
        "flex-shrink" => "0",
        "will-change" => "transform",
        "animation" => "bt-spin 0.7s linear infinite"),
    # Stacked text under the spinner (loading state) / standalone message
    # (offline / error). Both centre their own contents; the message variant
    # brings its own ⚠ glyph, so the shared spinner is hidden for it.
    CSS(".bt-loading-text, .bt-loading-msg",
        "display" => "flex", "flex-direction" => "column",
        "align-items" => "center", "gap" => "8px", "text-align" => "center"),
    CSS(".bt-loading:has(.bt-loading-msg) .bt-loading-spinner", "display" => "none"),
    CSS(".bt-loading-glyph", "font-size" => "28px", "opacity" => "0.7"),
    CSS(".bt-loading-title",
        "font-size" => "15px", "font-weight" => "600",
        "color" => "var(--bt-text)"),
    CSS(".bt-loading-sub",
        "font-size" => "13px", "color" => "var(--bt-text-muted)",
        "max-width" => "360px", "line-height" => "1.5"),

    # ── Open chat link ───────────────────────────────────────────────────────
    CSS(".bt-link",
        "color" => "var(--bt-accent)", "text-decoration" => "none",
        "font-size" => "13px", "font-weight" => "500",
        "padding" => "6px 10px",
        "border-radius" => "var(--bt-radius-sm)",
        "display" => "inline-flex", "align-items" => "center", "gap" => "6px",
        "transition" => "background 120ms"),
    CSS(".bt-link:hover",
        "background" => "rgba(59,130,246,0.08)"),
    CSS(".bt-link-loading",
        "color" => "var(--bt-text-muted)", "pointer-events" => "none"),
    # Pure UI feedback for the "Open chat →" link. JS just adds the
    # `.bt-link-clicked` class on click; the CSS animation flashes the link
    # and self-clears via `animation-fill-mode: forwards`. No server-side
    # observable, no @async timer — the new tab loading IS the feedback.
    CSS(".bt-link-clicked",
        "background" => "rgba(59,130,246,0.18)",
        "color" => "var(--bt-text-muted)",
        "pointer-events" => "none",
        "animation" => "bt-link-flash 1.6s ease-out forwards"),
    CSS("@keyframes bt-link-flash",
        CSS("0%",   "background" => "rgba(59,130,246,0.32)"),
        CSS("60%",  "background" => "rgba(59,130,246,0.18)"),
        CSS("100%", "background" => "transparent",
                    "color"      => "var(--bt-accent)")),

    # "Open chat on <worker>" — link styled wrapper containing a label and a
    # native <select>. Dropdown stays inline so the whole control reads as a
    # single button. Default-selected option is the project's current worker;
    # picking a different one → click handler runs the move sequence.
    CSS(".bt-open-on", "gap" => "4px"),
    CSS(".bt-open-on-label",
        "color" => "var(--bt-accent)",
        "font-weight" => "500"),
    CSS(".bt-open-on-select",
        "background"     => "transparent",
        "border"         => "1px solid var(--bt-border)",
        "border-radius"  => "var(--bt-radius-sm)",
        "color"          => "var(--bt-accent)",
        "font-weight"    => "500",
        "font-size"      => "13px",
        "padding"        => "2px 4px",
        "cursor"         => "pointer"),
    CSS(".bt-open-on-select:hover",
        "background" => "rgba(59,130,246,0.06)"),

    # ── Global busy progress pill ────────────────────────────────────────────
    # Fixed top-centered, single text line. One UI for every long-running op
    # (sync, project import, GitHub clone). Hidden via class toggle so the
    # wrapper stays mounted; child <span>s bind to derived Observable{String}s
    # which hit Bonito's innerText fast-path — no DOM swap, no flash, even
    # when librsync fires hundreds of file events per second.
    CSS(".bt-busy-card",
        "position" => "fixed",
        "top" => "12px",
        "left" => "50%",
        "transform" => "translateX(-50%)",
        "max-width" => "min(720px, 92vw)",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-accent)",
        "border-radius" => "999px",
        "padding" => "5px 14px",
        "box-shadow" => "var(--bt-shadow-md)",
        "z-index" => "9998",
        "font-size" => "13px",
        "line-height" => "1.4",
        "color" => "var(--bt-text)",
        "display" => "flex",
        "align-items" => "center",
        "gap" => "10px",
        "white-space" => "nowrap",
        "overflow" => "hidden"),
    CSS(".bt-busy-card.bt-busy-hidden",
        "display" => "none"),
    CSS(".bt-busy-title",
        "font-weight" => "600",
        "color" => "var(--bt-text)",
        "flex" => "0 0 auto"),
    CSS(".bt-busy-pct",
        "font-variant-numeric" => "tabular-nums",
        "color" => "var(--bt-text-muted)",
        "min-width" => "32px",
        "text-align" => "right",
        "flex" => "0 0 auto"),
    CSS(".bt-busy-msg",
        "color" => "var(--bt-text-muted)",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12.5px",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "flex" => "1 1 auto",
        "min-width" => "0"),

    # ── Inline "loading" state for click-fired DOM buttons ───────────────────
    # Used by the Discover Import button — JS flips this class on click for
    # instant visual feedback (the WS round-trip to surface the busy card
    # can take tens of ms; the click should respond immediately).
    CSS(".bt-btn.bt-clicked",
        "opacity" => "0.55", "cursor" => "wait",
        "pointer-events" => "none"),

    # ── Slide-in for forms / panels ──────────────────────────────────────────
    CSS(".bt-slide-in", "animation" => "bt-slide 160ms ease-out"),
    CSS("@keyframes bt-slide",
        CSS("from", "opacity" => "0", "transform" => "translateY(-4px)"),
        CSS("to",   "opacity" => "1", "transform" => "translateY(0)")),

    # ── Install hint (empty-state with copy button) ──────────────────────────
    CSS(".bt-install-block",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "16px 18px"),
    CSS(".bt-install-os",
        "color" => "var(--bt-text-faint)", "font-size" => "11px",
        "font-weight" => "600", "letter-spacing" => "0.04em",
        "text-transform" => "uppercase", "margin-top" => "12px"),
    CSS(".bt-install-cmd",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "8px",
        "background" => "#0f172a", "color" => "#e2e8f0",
        "font-family" => "ui-monospace, monospace", "font-size" => "12.5px",
        "padding" => "10px 12px", "border-radius" => "var(--bt-radius-sm)",
        "margin-top" => "4px"),
    CSS(".bt-install-cmd code",
        "white-space" => "pre", "overflow-x" => "auto"),
    CSS(".bt-install-copy",
        "background" => "rgba(255,255,255,0.06)",
        "color" => "#e2e8f0",
        "border" => "1px solid rgba(255,255,255,0.12)",
        "padding" => "4px 10px", "border-radius" => "4px",
        "font-size" => "12px", "cursor" => "pointer",
        "transition" => "background 120ms"),
    CSS(".bt-install-copy:hover",
        "background" => "rgba(255,255,255,0.12)"),

    # ── Global agent instructions (AGENTS.md) editor ─────────────────────────
    CSS(".bt-agents-body",
        "display" => "flex", "flex-direction" => "column", "gap" => "8px",
        "padding-top" => "8px"),
    CSS(".bt-agents-hint",
        "font-size" => "12px", "color" => "var(--bt-text-muted)",
        "line-height" => "1.5"),
    CSS(".bt-agents-textarea",
        "width" => "100%", "box-sizing" => "border-box",
        "padding" => "10px 12px",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "12.5px", "line-height" => "1.5",
        "resize" => "vertical",
        "outline" => "none",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-agents-textarea:focus",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-agents-actions",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "justify-content" => "flex-end"),
    CSS(".bt-agents-status",
        "font-size" => "12px", "color" => "var(--bt-text-muted)",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),

    # ── Responsive ───────────────────────────────────────────────────────────
    # Below ~560px is the "phone" branch. Each rule pairs with a non-mobile
    # default; the comment names which layout we're switching FROM →
    # so changes here aren't independent of the desktop styles above.
    CSS("@media (max-width: 560px)",
        # Header: title + tagline stack instead of sitting on one row
        CSS(".bt-header",
            "flex-direction" => "column",
            "align-items" => "flex-start",
            "gap" => "4px"),
        CSS(".bt-tagline", "font-size" => "12px"),
        # Section headings: h2 takes the full first row, action buttons
        # wrap onto a second row right-aligned. Without this, the buttons
        # squeeze in next to the tiny "PROJECTS" h2 and "+ New project"
        # wraps its own text onto two lines.
        CSS(".bt-section",
            "flex-wrap" => "wrap", "gap" => "8px"),
        CSS(".bt-section h2",
            "flex" => "1 0 100%"),
        # Form: label-above-input single-column layout for touch widths
        CSS(".bt-form",
            "grid-template-columns" => "minmax(0, 1fr)",
            "gap" => "8px"),
        CSS(".bt-form label",
            "padding-top" => "0", "font-size" => "12px"),
        # Cards: body + actions stack instead of sitting on one row. The card
        # is column-flex now (project list lives inside it), so wrapping is on
        # the top row (`.bt-card-row`) rather than the card itself.
        CSS(".bt-card-row", "flex-wrap" => "wrap"),
        # Card title row (name + badges): if the natural widths don't all
        # fit, let the pills wrap onto a second row below the name rather
        # than shrinking the name to "Cl..." just to keep one row.
        CSS(".bt-card-title",
            "flex-wrap" => "wrap", "row-gap" => "4px"),
        # The actions cluster takes the full card width so its children
        # (Sync btn + "Open chat on <worker>") can wrap onto a second row
        # instead of overflowing the card. `margin-left: 0` overrides
        # the desktop `margin-left: auto`; without it the cluster sizes
        # to its content and right-aligns, leaving `flex-wrap` no
        # horizontal room to actually act on.
        CSS(".bt-card-actions",
            "width" => "100%", "margin-left" => "0",
            "flex-wrap" => "wrap", "justify-content" => "flex-end"),
        # Discover panel header: long title ("Claude Code sessions on
        # <worker>") + Rescan + close button can't fit on one row at
        # 360–390px. Stack title above the action row.
        CSS(".bt-discover-header",
            "flex-direction" => "column",
            "align-items" => "stretch",
            "gap" => "8px"),
        CSS(".bt-discover-actions",
            "justify-content" => "flex-end"),
        # Stats strip: tighter gap so the inline pills don't overflow
        CSS(".bt-stats", "gap" => "12px")),

    # ── Collision-resolution modal ───────────────────────────────────────────
    CSS(".bt-collision-overlay",
        "position" => "fixed",
        "top" => "0", "left" => "0", "right" => "0", "bottom" => "0",
        "background" => "rgba(0,0,0,0.55)",
        "z-index" => "1000",
        "display" => "flex",
        "align-items" => "center",
        "justify-content" => "center",
        "padding" => "16px"),
    CSS(".bt-collision-card",
        "background" => "var(--bt-bg, #fff)",
        "color" => "var(--bt-text, #111)",
        "border-radius" => "12px",
        "max-width" => "900px", "width" => "100%",
        "max-height" => "85vh", "overflow-y" => "auto",
        "padding" => "20px",
        "box-shadow" => "0 8px 32px rgba(0,0,0,0.25)",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "16px"),
    CSS(".bt-collision-card h3",
        "margin" => "0",
        "font-size" => "18px"),
    CSS(".bt-collision-card h5",
        "margin" => "8px 0 4px 0",
        "font-size" => "12px",
        "text-transform" => "uppercase",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-collision-sub",
        "color" => "var(--bt-text-muted)",
        "font-size" => "13px",
        "margin-top" => "4px"),

    CSS(".bt-collision-sides",
        "display" => "grid",
        "grid-template-columns" => "1fr 1fr",
        "gap" => "12px"),
    CSS("@media (max-width: 720px)",
        CSS(".bt-collision-sides",
            "grid-template-columns" => "1fr")),

    CSS(".bt-collision-side",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "8px",
        "padding" => "12px",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "8px",
        "min-width" => "0"),
    # Highlight the side that's been touched more recently.
    CSS(".bt-collision-newer .bt-collision-side",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 2px rgba(59,130,246,0.18)"),
    CSS(".bt-collision-side-title",
        "font-weight" => "600",
        "font-size" => "14px"),
    CSS(".bt-collision-side-path",
        "font-family" => "monospace",
        "font-size" => "11px",
        "color" => "var(--bt-text-muted)",
        "white-space" => "nowrap",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis"),

    CSS(".bt-collision-stats",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "2px",
        "font-size" => "13px"),
    CSS(".bt-collision-label",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-collision-value",
        "font-weight" => "600"),
    CSS(".bt-collision-value-faint",
        "color" => "var(--bt-text-muted)"),

    CSS(".bt-collision-recent, .bt-collision-git",
        "font-size" => "12px"),
    CSS(".bt-collision-file-row, .bt-collision-git-row",
        "display" => "flex",
        "justify-content" => "space-between",
        "gap" => "8px",
        "padding" => "2px 0",
        "white-space" => "nowrap",
        "overflow" => "hidden"),
    CSS(".bt-collision-file-path",
        "font-family" => "monospace",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "flex" => "1 1 auto",
        "min-width" => "0"),
    CSS(".bt-collision-file-age",
        "color" => "var(--bt-text-muted)",
        "flex-shrink" => "0"),
    CSS(".bt-collision-empty",
        "color" => "var(--bt-text-muted)",
        "font-style" => "italic",
        "font-size" => "12px"),

    CSS(".bt-collision-git-row",
        "flex-direction" => "column",
        "gap" => "2px",
        "padding-bottom" => "6px"),
    CSS(".bt-collision-git-path",
        "font-family" => "monospace",
        "font-size" => "12px"),
    CSS(".bt-collision-git-ref",
        "font-family" => "monospace",
        "color" => "var(--bt-text-muted)",
        "font-size" => "11px"),
    CSS(".bt-collision-git-clean",
        "color" => "#065f46",
        "font-size" => "11px",
        "margin-left" => "8px"),
    CSS(".bt-collision-git-dirty",
        "color" => "var(--bt-error, #b91c1c)",
        "font-size" => "11px",
        "margin-left" => "8px"),
    CSS(".bt-collision-git-age",
        "color" => "var(--bt-text-muted)",
        "font-size" => "11px",
        "margin-left" => "8px"),

    CSS(".bt-collision-actions",
        "display" => "flex",
        "justify-content" => "flex-end",
        "gap" => "8px",
        "padding-top" => "8px",
        "border-top" => "1px solid var(--bt-border)"),
)

# Windows-style address bar: clickable breadcrumb segments by default;
# clicking the empty area or the ✎ button switches to a text input where the
# user can type/paste a path. Enter commits, Esc cancels.
"""
    address_bar(cur, editing) → Bonito DOM node

`cur::Observable{String}` is the path being browsed; `editing::Observable{Bool}`
toggles between breadcrumb mode and text-input mode. Both are mutated in
response to user clicks/keystrokes.
"""
# Normalize a path for use inside the picker / for JS string interpolation.
# Julia accepts forward slashes on Windows for all FS operations, while raw
# backslashes are invalid escape sequences in JS string literals (`\U`, `\s`,
# …) — embedding them produces either silent corruption or SyntaxErrors. By
# routing every picker path through forward slashes we sidestep both issues
# without losing Windows-correctness.
js_path(p::AbstractString) = replace(String(p), '\\' => '/')

function address_bar(cur::Observable{String}, editing::Observable{Bool})
    map(cur, editing) do path, edit
        if edit
            DOM.input(
                type    = "text",
                value   = js_path(path),
                class   = "bt-addr-input",
                autofocus = true,
                onfocus = js"event => event.target.select()",
                # Normalize user-typed backslashes to forward slashes in JS
                # before notifying — same reason as `js_path` above.
                onkeydown = js"""event => {
                    if (event.key === 'Enter') {
                        $(cur).notify(event.target.value.replace(/\\/g, '/'));
                        $(editing).notify(false);
                    } else if (event.key === 'Escape') {
                        $(editing).notify(false);
                    }
                }""")
        else
            paths = breadcrumb_paths(js_path(path))
            nodes = []
            for (i, full) in enumerate(paths)
                label = i == 1 ? breadcrumb_root_label(full) : basename(full)
                push!(nodes, DOM.span(label;
                    class   = i == 1 ? "bt-addr-seg bt-addr-seg-root" : "bt-addr-seg",
                    onclick = js"event => { event.stopPropagation(); $(cur).notify($full); }",
                    title   = full))
                if i < length(paths)
                    push!(nodes, DOM.span("›"; class = "bt-addr-chevron"))
                end
            end
            # Filler at the end takes remaining width — clicking it enters edit mode.
            push!(nodes, DOM.div("";
                class = "bt-addr-filler",
                onclick = js"event => $(editing).notify(true)"))
            push!(nodes, DOM.button("✎";
                class    = "bt-addr-icon-btn",
                title    = "Edit path",
                onclick  = js"event => $(editing).notify(true)"))
            DOM.div(nodes...;
                class   = "bt-addr-bar",
                onclick = js"""event => {
                    if (event.target === event.currentTarget) $(editing).notify(true);
                }""")
        end
    end
end

# Build cumulative paths for breadcrumb rendering. Cross-platform: input must
# already be normalized to forward slashes (see `js_path`).
#   Linux:   "/home/server/BonitoAgents" → ["/", "/home", "/home/server", "/home/server/BonitoAgents"]
#   Windows: "C:/Users/sdani/Proj"     → ["C:/", "C:/Users", "C:/Users/sdani", "C:/Users/sdani/Proj"]
function breadcrumb_paths(cur::String)::Vector{String}
    isempty(cur)  && return ["/"]
    parts = split(cur, '/'; keepempty = false)
    isempty(parts) && return ["/"]
    # Detect a Windows-style drive prefix ("C:", "D:", …).
    has_drive = length(parts[1]) == 2 && parts[1][2] == ':' &&
                ('a' <= lowercase(parts[1][1]) <= 'z')
    if has_drive
        drive = String(parts[1])
        paths = String[drive * "/"]
        acc   = drive
        for p in Iterators.drop(parts, 1)
            acc *= "/" * String(p)
            push!(paths, acc)
        end
        return paths
    else
        paths = String["/"]
        acc   = ""
        for p in parts
            acc *= "/" * String(p)
            push!(paths, acc)
        end
        return paths
    end
end

# Label shown on the leftmost breadcrumb segment (the filesystem root).
breadcrumb_root_label(full::AbstractString) =
    length(full) >= 3 && full[2] == ':' ? String(full[1:2]) : "/"

# Folder picker component
"""
Slim server-side folder picker. `selected` is an Observable{String} the caller
listens to. Renders as: address bar + Up / Choose buttons + a flat list of
subdirectories below the bar.
"""
mutable struct FolderPicker
    cur::Observable{String}        # current directory being browsed
    selected::Observable{String}   # final chosen directory
    expanded::Observable{Bool}
    editing::Observable{Bool}      # address bar in text-edit mode
end

FolderPicker(start::String = pwd()) = FolderPicker(
    Observable(js_path(abspath(start))), Observable(""), Observable(false), Observable(false))

function folder_picker_render(session::Bonito.Session, p::FolderPicker)
    up_btn     = Bonito.Button("↑"; style=nothing, class = "bt-btn bt-btn-secondary",
                               title = "Up one level")
    choose_btn = Bonito.Button("Choose"; style=nothing, class = "bt-btn")

    on(session, up_btn.value) do clicked
        clicked || return
        parent = js_path(dirname(rstrip(p.cur[], '/')))
        isempty(parent) || parent == p.cur[] || (p.cur[] = parent)
    end
    on(session, choose_btn.value) do clicked
        clicked || return
        p.selected[] = p.cur[]
    end

    # Always show the listing — drop the explicit Browse-to-expand mode.
    p.expanded[] = true

    list = map(p.cur) do path
        entries = try
            sort!(filter(n -> isdir(joinpath(path, n)) && !startswith(n, "."),
                         readdir(path)))
        catch e
            return DOM.div("error: $e"; class = "bt-picker", style = Styles("color" => "#b91c1c"))
        end
        rows = isempty(entries) ?
            [DOM.div("(no subfolders)";
                class = "bt-picker-row", style = Styles("color" => "var(--bt-text-faint)"))] :
            [DOM.div("📁 $name";
                class   = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(js_path(joinpath(path, name))));")
             for name in entries]
        DOM.div(rows...; class = "bt-picker")
    end

    DOM.div(
        DOM.div(
            address_bar(p.cur, p.editing),
            up_btn, choose_btn;
            class = "bt-picker-cur"),
        list)
end

# Remote folder picker — reads the worker's filesystem over its control WS via
# `list_worker_dir`. Async: the WS round-trip would otherwise block Bonito's map
# during render and freeze the UI for hundreds of ms per browse click.
const PickerEntry = NamedTuple{(:name, :dir), Tuple{String, Bool}}

mutable struct RemoteFolderPicker
    worker_name::String
    cur::Observable{String}
    selected::Observable{String}
    expanded::Observable{Bool}
    editing::Observable{Bool}          # address bar in text-edit mode
    entries::Observable{Vector{PickerEntry}}
    loading::Observable{Bool}
    err::Observable{String}
    fetch_id::Ref{Int}                 # increments per request; older replies bail
    listeners_set_up::Ref{Bool}        # idempotency for setup_listeners!
end

RemoteFolderPicker(worker_name::String, start::String = "") = RemoteFolderPicker(
    worker_name, Observable(start), Observable(""), Observable(false),
    Observable(false),
    Observable(PickerEntry[]), Observable(false), Observable(""),
    Ref(0), Ref(false))

# Kick off a WS list_worker_dir for `p.cur[]` and update entries/loading/err.
# Older in-flight responses are discarded via fetch_id.
function fetch_remote_entries!(p::RemoteFolderPicker)
    p.fetch_id[] += 1
    my_id  = p.fetch_id[]
    target = p.cur[]
    p.loading[] = true
    p.err[]     = ""
    @async begin
        try
            resp = list_worker_dir(p.worker_name, target)
            my_id == p.fetch_id[] || return        # stale response, abandon
            if resp.path != target
                # Worker resolved cur="" → its $HOME. Cascading on(cur) will
                # trigger a fresh fetch — leave loading=true so the spinner
                # bridges the gap.
                p.cur[] = resp.path
                return
            end
            p.entries[] = PickerEntry[(name = String(e.name), dir = Bool(e.dir))
                                      for e in resp.entries if e.dir]
            p.loading[] = false
        catch e
            my_id == p.fetch_id[] || return
            p.err[]     = sprint(showerror, e)
            p.loading[] = false
        end
    end
end

function setup_remote_picker_listeners!(session::Bonito.Session, p::RemoteFolderPicker)
    p.listeners_set_up[] && return
    p.listeners_set_up[] = true
    on(session, p.cur)      do _;   p.expanded[] && fetch_remote_entries!(p); end
    on(session, p.expanded) do exp; exp && fetch_remote_entries!(p); end
    return
end

function remote_folder_picker_render(session::Bonito.Session, p::RemoteFolderPicker)
    setup_remote_picker_listeners!(session, p)

    up_btn     = Bonito.Button("↑"; style=nothing, class = "bt-btn bt-btn-secondary",
                               title = "Up one level")
    choose_btn = Bonito.Button("Choose"; style=nothing, class = "bt-btn")

    on(session, up_btn.value) do clicked
        clicked || return
        cur = p.cur[]
        isempty(cur) && return
        parent = js_path(dirname(rstrip(cur, '/')))
        !isempty(parent) && parent != cur && (p.cur[] = parent)
    end
    on(session, choose_btn.value) do clicked
        clicked || return
        p.selected[] = p.cur[]
    end

    # Picker is always visible — kick off the initial fetch on first render.
    p.expanded[] = true

    list = map(p.loading, p.entries, p.err, p.cur) do loading, entries, err, cur
        if loading
            return DOM.div(
                DOM.div(class = "bt-spinner"),
                DOM.span("Listing folder…");
                class = "bt-picker bt-picker-loading bt-slide-in")
        end
        if !isempty(err)
            return DOM.div("error: $err";
                           class = "bt-picker", style = Styles("color" => "#b91c1c"))
        end
        rows = isempty(entries) ?
            [DOM.div("(no subfolders)";
                class = "bt-picker-row", style = Styles("color" => "var(--bt-text-faint)"))] :
            [DOM.div("📁 $(e.name)";
                class   = "bt-picker-row",
                onclick = js"event => $(p.cur).notify($(js_path(joinpath(cur, e.name))));")
             for e in entries]
        DOM.div(rows...; class = "bt-picker bt-slide-in")
    end

    DOM.div(
        DOM.div(
            address_bar(p.cur, p.editing),
            up_btn, choose_btn;
            class = "bt-picker-cur"),
        list)
end

# Status indicator helpers
status_dot(s::Symbol) = DOM.span(""; class = "bt-dot bt-dot-$s",
    title = string(s))   # native tooltip

# Small inline "doing work" indicator: a spinner + label, used for the
# discover-panel "scanning…" state and other in-flight ops.
spinner_row(msg) = DOM.div(
    DOM.div(class = "bt-spinner"),
    DOM.span(msg),
    class = "bt-spinner-row")

# Pull a likely username out of $HOME (e.g. "/home/simon" → "simon"). Returns
# "" if we can't find one.
function _user_from_home(home::AbstractString)
    isempty(home) && return ""
    parts = split(home, '/'; keepempty=false)
    isempty(parts) && return ""
    return String(last(parts))
end

# Compose a human-readable worker subtitle. Skips "localhost" since
# gethostname() returns it on some setups and it's useless metadata.
# Order: user@host  ·  projects-root.
function worker_subtitle(w::WorkerInfo)
    parts = String[]
    user  = _user_from_home(w.home)
    host  = (w.hostname == "localhost" || isempty(w.hostname)) ? "" : w.hostname
    if !isempty(user) && !isempty(host)
        push!(parts, "$user@$host")
    elseif !isempty(host)
        push!(parts, host)
    elseif !isempty(user)
        push!(parts, user)
    end
    isempty(w.projects_root) || push!(parts, w.projects_root)
    return isempty(parts) ? "(no metadata)" : join(parts, " · ")
end

# worker_card replaced by the `WorkerCard` widget (see worker_widget.jl),
# which holds stable per-worker_id identity so KeyedList can diff the
# worker list without remounting every card on every state.workers notify.

# Render a small pill describing the project's backup status. Read at card-
# render time; the dashboard re-renders on `notify(state.projects)` whenever sync state
# changes.
function backup_pill(p::ProjectInfo)
    if p.backup_status === :syncing
        DOM.span(DOM.div(class = "bt-spinner bt-spinner-sm"),
                 DOM.span("Backing up…");
                 class = "bt-pill bt-pill-syncing bt-spinner-row",
                 style = Styles("margin-left" => "6px"),
                 title = "Project is syncing to server")
    elseif p.backup_status === :synced
        last = p.last_sync_at === nothing ? "" :
               " (last: $(Dates.format(p.last_sync_at, "yyyy-mm-dd HH:MM")) UTC)"
        DOM.span("backed up"; class = "bt-pill bt-pill-online",
                 style = Styles("margin-left" => "6px"),
                 title = "Server has a copy of this project's files$(last)")
    elseif p.backup_status === :stale
        DOM.span("stale backup"; class = "bt-pill bt-pill-warn",
                 style = Styles("margin-left" => "6px"),
                 title = "Server copy may be out of date — re-sync to refresh")
    else
        DOM.span("not backed up"; class = "bt-pill bt-pill-muted",
                 style = Styles("margin-left" => "6px"),
                 title = "Server has no copy — chat works directly against the worker")
    end
end

# project_card replaced by the `ProjectCard` widget (see project_widget.jl),
# which holds stable per-project_id identity so KeyedList can diff the
# project list without remounting every card on every state.projects notify.

"""
    dashboard_dom(session, state; current_view = nothing) → DOM

Build the dashboard's DOM block. When `current_view` is provided (the
unified app's view-selector observable), the project-creation flows
auto-navigate to the new project's chat by setting it; otherwise creation
just leaves the user on the dashboard.
"""
function dashboard_dom(session::Bonito.Session, state::ServerState;
                        current_view::Union{Observable{String},Nothing} = nothing)
    error_obs = Observable("")

    # Workers self-register over WS — no manual "Add worker" form.

    # `which_form` is the single source of truth for which slide-in panel is
    # open. `:none` (closed), `:new_project`, or `:github`. The two forms are
    # mutually exclusive; one enum is clearer than two booleans that always
    # have to be kept opposite.
    which_form = Observable(:none)
    # Single source of truth for the global progress card (sync, project
    # import, GitHub clone). `BUSY_IDLE` ⇒ card hidden; non-idle snapshot ⇒
    # card visible with title + progress + recent files. See progress.jl.
    busy = Observable(BUSY_IDLE)

    # Form fields
    np_name   = Observable("")
    np_picker = FolderPicker(state.working_dir)
    on(session, np_picker.selected) do sel
        isempty(strip(np_name[])) || return
        isempty(sel) && return
        np_name[] = basename(rstrip(sel, '/'))
    end
    np_worker = Observable("")
    gh_url    = Observable("")
    gh_worker = Observable("")

    # ── Sync-to-server click handler ─────────────────────────────────────────
    # Fired by the project card's "Sync to server" / "Re-sync" button. The
    # actual transfer runs in the background; we update `busy` + notify(state.projects)
    # so the global progress card and the project card both reflect the syncing state.
    sync_request = Observable("")
    on(session, sync_request) do pid
        isempty(pid) && return
        sync_request[] = ""           # reset so the same card can re-fire
        haskey(state.projects[], pid) || return
        p = state.projects[][pid]
        p.backup_status === :syncing && return    # already in flight
        @async begin
            try
                # busy_event!/busy_start! are best-effort (safe_set!): a JS
                # hiccup updating the card must not abort the in-flight transfer.
                busy_start!(busy, "Syncing $(p.name)")
                sync_project_to_server!(state, p;
                    on_progress = (stage, info) -> busy_event!(busy, stage, info))
                safe_set!(error_obs, "")
            catch e
                bt = catch_backtrace()
                @warn "sync_project_to_server! failed" project=p.name exception=(e, bt)
                safe_set!(error_obs,
                    "Failed to sync $(p.name): $(sprint(showerror, e))")
            finally
                busy_clear!(busy)
            end
        end
    end

    # ── "Open chat on <worker>" click handler ────────────────────────────────
    # JS sends a {project, worker} payload. Same worker → just swap the
    # main-panel view. Different worker → `start!` handles the whole
    # transparent-move sequence (pre-pull from source, push to target,
    # re-bind, start session). Long-running so it goes through the busy
    # card; the (stage, info) callback surfaces per-file progress.
    open_request = Observable(Dict{String,Any}())
    on(session, open_request) do payload
        isempty(payload) && return
        pid    = String(get(payload, "project", ""))
        target = String(get(payload, "worker",  ""))
        open_request[] = Dict{String,Any}()   # reset
        (isempty(pid) || isempty(target)) && return
        haskey(state.projects[], pid) || return
        p = state.projects[][pid]

        if target == p.worker_id
            current_view !== nothing && (current_view[] = p.id)
            return
        end

        haskey(state.workers[], target) || return
        is_busy_idle(busy[]) || return   # don't pile up moves
        target_w = state.workers[][target]
        # Set the busy guard SYNCHRONOUSLY, before spawning (T16). Doing it
        # inside the @async let a double-click pass the `is_busy_idle` check
        # twice (busy was still idle until the first task ran) and start two
        # concurrent project moves. The other long-ops set it synchronously too.
        busy_start!(busy, "Opening $(p.name) on $(target_w.name)")
        @async begin
            try
                cb = (stage, info) -> busy_event!(busy, stage, info)
                start!(state, p, target; progress = cb)
                safe_set!(error_obs, "")
                current_view !== nothing && (current_view[] = p.id)
            catch e
                bt = catch_backtrace()
                @warn "open-on-worker failed" project=p.name target=target exception=(e, bt)
                safe_set!(error_obs,
                    "Failed to open $(p.name) on $(target_w.name): $(sprint(showerror, e))")
            finally
                busy_clear!(busy)
            end
        end
    end

    np_submit = Bonito.Button("Create"; style=nothing, class = "bt-btn")
    np_cancel = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")

    on(session, np_submit.value) do clicked
        clicked || return
        is_busy_idle(busy[]) || return   # guard: ignore clicks while busy
        nm = String(strip(np_name[]))
        busy_start!(busy, "Creating $(nm)")
        @async begin
            try
                p = create_project!(state, nm,
                                 String(strip(np_picker.selected[])),
                                 String(strip(np_worker[]));
                                 progress = (stage, info) -> busy_event!(busy, stage, info))
                error_obs[] = ""
                which_form[] = :none
                np_name[] = ""; np_picker.selected[] = ""; np_worker[] = ""
                current_view !== nothing && (current_view[] = p.id)
            catch e
                error_obs[] = "Failed to create project: $e"
            finally
                busy_clear!(busy)
            end
        end
    end
    on(session, np_cancel.value) do clicked
        clicked || return
        is_busy_idle(busy[]) || return   # don't cancel mid-create
        which_form[] = :none
        error_obs[] = ""
    end

    new_proj_btn = Bonito.Button("+ New project"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(session, new_proj_btn.value) do clicked
        clicked || return
        if isempty(state.workers[])
            error_obs[] = "Register a worker before creating a project."
            return
        end
        np_worker[]  = first(keys(state.workers[]))
        which_form[] = :new_project
        error_obs[]  = ""
    end

    gh_submit = Bonito.Button("Open"; style=nothing, class = "bt-btn")
    gh_cancel = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")

    on(session, gh_submit.value) do clicked
        clicked || return
        is_busy_idle(busy[]) || return
        url = String(strip(gh_url[]))
        worker_name = String(strip(gh_worker[]))
        isempty(url) && (error_obs[] = "GitHub URL required."; return)
        isempty(worker_name) && (error_obs[] = "Pick a worker."; return)
        busy_start!(busy, "Opening from GitHub")
        @async begin
            try
                p = create_project_from_github!(state, url;
                    worker_name = worker_name,
                    progress    = (stage, info) -> busy_event!(busy, stage, info))
                error_obs[]  = ""
                which_form[] = :none
                gh_url[]     = ""
                current_view !== nothing && (current_view[] = p.id)
            catch e
                error_obs[] = "Failed to open from GitHub: $(sprint(showerror, e))"
            finally
                busy_clear!(busy)
            end
        end
    end
    on(session, gh_cancel.value) do clicked
        clicked || return
        is_busy_idle(busy[]) || return
        which_form[] = :none
        error_obs[]  = ""
    end

    gh_btn = Bonito.Button("+ From GitHub"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(session, gh_btn.value) do clicked
        clicked || return
        if isempty(state.workers[])
            error_obs[] = "Register a worker before opening a GitHub project."
            return
        end
        gh_worker[]  = first(keys(state.workers[]))
        which_form[] = :github
        error_obs[]  = ""
    end

    # `picker_state` holds the worker_id whose picker form is currently
    # visible (""  → none). The folder-picker instances themselves live on
    # each WorkerCard (stable across re-renders because the card is stable).
    picker_state = Observable("")

    # Discover panel — scan a worker for existing Claude Code sessions
    discover_state   = Observable("")                       # worker name whose panel is open
    discover_results = Observable(Dict{String,Any}[])
    discover_busy    = Observable(false)
    # NOTE: the session-pick sink used to live here as a shared `import_path`
    # Observable interpolated into the per-card discover panel — but the panel
    # renders in a different (sub-)session than this `dashboard_dom` scope, so
    # the client lookup failed ("Key N not found" → null.notify → silent Resume
    # failure). It now lives as a SESSION-LOCAL `pick` inside
    # `render_discover_panel`, bridged to `do_import`. See worker_widget.jl.

    function trigger_scan!(w_name::String)
        discover_busy[]    = true
        discover_results[] = Dict{String,Any}[]
        @async begin
            try
                discover_results[] = scan_worker_sessions(state, w_name)
            catch e
                discover_results[] = [Dict{String,Any}("error" => sprint(showerror, e))]
            finally
                discover_busy[] = false
            end
        end
    end

    on(session, discover_state) do w_name
        isempty(w_name) || trigger_scan!(w_name)
    end

    # Shared import path used by both the "discovered sessions" panel and
    # the remote-folder picker. Name collisions across workers are no
    # longer treated as a decision — each worker gets its own project with
    # its own server_path mirror. The "merge / move" decision only matters
    # at sync-time and is handled separately.
    function do_import(w_name::String, path::String;
                        name::Union{Nothing,String} = nothing,
                        resume_session_id::Union{Nothing,String} = nothing)
        # In-flight guard (T16): a double-click (or two import affordances firing
        # at once) had no guard here and would run two concurrent imports of the
        # same folder. Bail synchronously if a long-op is already running; the
        # synchronous `busy_start!` just below then latches this one.
        is_busy_idle(busy[]) || return nothing
        proj_name = name !== nothing ? name :
            let n = replace(basename(rstrip(path, '/')), r"[^a-zA-Z0-9_\-]" => "_")
                isempty(n) ? "project" : n
            end
        title = resume_session_id === nothing ?
            "Importing $(proj_name)" :
            "Resuming $(proj_name) (session $(resume_session_id[1:8])…)"
        busy_start!(busy, title)
        @async begin
            try
                @info "do_import: starting" worker=w_name path resume=resume_session_id
                # `start_session=false` so the registration finishes fast and we
                # can flip `current_view` early — the chat bring-up itself
                # (ensure_project_session!) is then driven by
                # `project_loading_view`, which shows a full-panel spinner while
                # it runs. Otherwise the user stares at the dashboard for ~10s
                # of ACP `session/load` with only a tiny pill at the top.
                p = create_project_from_worker!(state, w_name, path;
                    name = proj_name,
                    resume_session_id = resume_session_id,
                    start_session = false,
                    progress = (stage, info) -> busy_event!(busy, stage, info))
                @info "do_import: registered project, flipping view" id=p.id
                error_obs[]      = ""
                discover_state[] = ""
                picker_state[]   = ""
                current_view !== nothing && (current_view[] = p.id)
            catch e
                # Never swallow silently: surface to the UI AND the server log.
                @warn "do_import failed" worker=w_name path resume=resume_session_id exception=(e, catch_backtrace())
                error_obs[] = "Failed to import: $(sprint(showerror, e))"
            finally
                busy_clear!(busy)
            end
        end
    end

    # The session-pick handler (payload parse + busy-idle guard + do_import) now
    # lives next to its SESSION-LOCAL `pick` observable in `render_discover_panel`
    # (worker_widget.jl), bridged to this `do_import` — so the observable is
    # registered in the same session that renders the panel.

    # session_row + discover_panel are now rendered inside WorkerCard
    # (see worker_widget.jl) — each worker's card owns its discover panel
    # toggled by `discover_state`, and the rows reference `import_path`
    # directly from the card's captured fields.

    text_input(obs::Observable, ph::String) = DOM.input(
        type = "text", placeholder = ph,
        value = obs,    # Julia → JS: pushed back when obs changes (e.g. auto-fill)
        oninput = js"event => $(obs).notify(event.target.value)")

    new_proj_form() = DOM.div(
        DOM.label("Name"),   text_input(np_name, "e.g. my-project"),
        DOM.label("Source"), DOM.div(
            folder_picker_render(session, np_picker),
            map(np_picker.selected) do sel
                isempty(sel) ? DOM.div() :
                    DOM.div("✓ selected: $sel",
                            style = Styles("color" => "#065f46",
                                           "font-size" => "12px",
                                           "margin-top" => "4px"))
            end),
        DOM.label("Worker"),
        DOM.select(
            # Show w.name (mutable display label) but submit w.worker_id
            # (stable UUID, the dict key into state.workers).
            # The class is a stable hook: tests / tooling target THIS select —
            # "first visible <select>" broke once the dashboard grew the
            # session-config pills (also native selects).
            (DOM.option(w.name; value=w.worker_id) for w in values(state.workers[]))...;
            class = "bt-np-worker-select",
            onchange = js"event => $(np_worker).notify(event.target.value)"),
        # Form action row — the global progress card is the visual feedback
        # for the in-flight submit; click handlers guard against double-fire.
        DOM.div(np_cancel, np_submit, class = "bt-form-actions"),
        class = "bt-form")

    gh_form() = DOM.div(
        DOM.label("GitHub URL"),
        text_input(gh_url,
            "https://github.com/<owner>/<repo>  ·  /issues/<n>  ·  /pull/<n>"),
        DOM.div("Repo → just clone. Issue/PR → clone + auto-prompt 'fix this'.";
                style = Styles("font-size" => "11px",
                               "color" => "var(--bt-text-muted)",
                               "margin-top" => "-4px")),
        DOM.label("Worker"),
        DOM.select(
            (DOM.option(w.name; value=w.worker_id) for w in values(state.workers[]))...;
            class = "bt-gh-worker-select",
            onchange = js"event => $(gh_worker).notify(event.target.value)"),
        DOM.div(gh_cancel, gh_submit, class = "bt-form-actions"),
        class = "bt-form")

    # The per-worker picker form and discover panel are now rendered inside
    # WorkerCard (see worker_widget.jl) and toggled via class binding —
    # which means each card owns its own RemoteFolderPicker, persistent
    # across re-renders without any dashboard-level dict.

    # ── Stats strip ──────────────────────────────────────────────────────────
    # Stats touch both worker counts and project counts → listen to both.
    stats_strip = map(state.workers, state.projects) do workers, projects
        online   = count(isopen, values(workers))
        total    = length(workers)
        n_proj   = length(projects)
        n_active = count(p -> p.locked_by !== nothing, values(projects))
        sep()    = DOM.span("·"; class = "bt-stat-sep")
        DOM.div(
            DOM.div(
                status_dot(online > 0 ? :online : (total == 0 ? :unknown : :offline)),
                DOM.span("$online"; class = "bt-stat-value"),
                DOM.span("/$total workers online"; class = "bt-stat-label"),
                class = "bt-stat"),
            sep(),
            DOM.div(
                DOM.span("$n_proj"; class = "bt-stat-value"),
                DOM.span(n_proj == 1 ? "project" : "projects"; class = "bt-stat-label"),
                class = "bt-stat"),
            sep(),
            DOM.div(
                DOM.span("$n_active"; class = "bt-stat-value"),
                DOM.span("active"; class = "bt-stat-label"),
                class = "bt-stat"),
            class = "bt-stats")
    end

    # ── Worker list ──────────────────────────────────────────────────────────
    # Per-worker WorkerCard widgets, kept stable in `worker_cards` and fed to
    # a KeyedList keyed on `worker_id`. Adding/removing workers diffs
    # cleanly — only the affected cards mount/unmount. Worker info changes
    # (status, name, subtitle) flow through derived Observables inside each
    # card, so neighbours don't see any DOM churn.
    worker_cards = Dict{String,WorkerCard}()
    function get_worker_card(wid::AbstractString)
        get!(worker_cards, String(wid)) do
            WorkerCard(state, wid;
                error_obs        = error_obs,
                picker_state     = picker_state,
                discover_state   = discover_state,
                busy             = busy,
                discover_busy    = discover_busy,
                discover_results = discover_results,
                do_import        = do_import,
                trigger_scan     = trigger_scan!)
        end
    end
    # The "no workers" install-instructions block lives as a sibling that
    # toggles visibility based on workers-empty. Keeps the install snippet
    # out of every render's hot path.
    #
    # OS-explicit routes — we already know the platform per row, so we hit
    # /install.sh and /install.ps1 directly instead of relying on /install's
    # User-Agent sniff to guess. Both wrappers verify `julia` is on PATH and
    # then run the cross-platform install.jl. This snippet matches the
    # worker-install hint the server banner + install_server.sh print verbatim.
    base         = install_base_url(state)
    install_unix = "curl -fsSL $base/install.sh | sh"
    install_win  = "irm $base/install.ps1 | iex"
    # Copy MUST work on plain-http origins too: `navigator.clipboard` is
    # undefined outside secure contexts (https / localhost), which is exactly
    # how a LAN-hosted BonitoAgents is reached — that's why the button "did
    # nothing". Fall back to the hidden-textarea + execCommand path there.
    install_row(label, cmd) = DOM.div(
        DOM.div(label; class = "bt-install-os"),
        DOM.div(
            DOM.code(cmd),
            DOM.span("Copy";
                class   = "bt-install-copy",
                onclick = js"""event => {
                    const btn  = event.target;
                    const done = () => {
                        btn.textContent = 'Copied';
                        setTimeout(() => btn.textContent = 'Copy', 1200);
                    };
                    const fallback = () => {
                        const ta = document.createElement('textarea');
                        ta.value = $cmd;
                        ta.style.position = 'fixed';
                        ta.style.opacity = '0';
                        document.body.appendChild(ta);
                        ta.select();
                        try { document.execCommand('copy'); done(); }
                        finally { ta.remove(); }
                    };
                    if (navigator.clipboard && window.isSecureContext) {
                        navigator.clipboard.writeText($cmd).then(done, fallback);
                    } else {
                        fallback();
                    }
                }"""),
            class = "bt-install-cmd"))
    # Headline text reflects whether any workers have connected yet — but the
    # install snippet itself is always visible, so adding more workers later
    # doesn't require digging through docs.
    install_headline = map(state.workers) do workers
        isempty(workers) ? "No workers connected yet. Run on each agent machine:" :
                           "Add another worker — run on the agent machine:"
    end
    # The install snippets are secondary once a worker is connected, so they
    # live behind a disclosure (collapsed by default) and stop dominating the
    # Workers card. During onboarding (no workers yet) it starts open so the
    # commands are right there.
    install_body = DOM.div(
        DOM.div(install_headline;
                style = Styles("color" => "var(--bt-text-muted)",
                                "font-size" => "13px",
                                "margin-bottom" => "4px")),
        install_row("Linux / macOS", install_unix),
        install_row("Windows (PowerShell)", install_win);
        class = "bt-install-block")
    install_summary = DOM.summary(
        DOM.span("Add another worker"; class = "bt-discover-title");
        class = "bt-discover-header")
    install_block = isempty(state.workers[]) ?
        DOM.details(install_summary, install_body; class = "bt-card bt-install-details", open = true) :
        DOM.details(install_summary, install_body; class = "bt-card bt-install-details")
    # ── Global agent instructions (AGENTS.md) ────────────────────────────────
    # A server-wide system-prompt appendix every agent session gets, across
    # all workers (state_dir/AGENTS.md; see `system_prompt_meta`). Read at
    # session bring-up, so a save applies to the NEXT chat opened.
    agents_status = Observable("")
    agents_saved  = Observable{Union{Nothing,String}}(nothing)
    on(session, agents_saved) do txt
        txt === nothing && return
        try
            set_global_agents_md!(state, txt)
            safe_set!(agents_status,
                "saved · applies to chats opened from now on")
        catch e
            @warn "AGENTS.md save failed" exception = e
            safe_set!(agents_status, "save failed: $(sprint(showerror, e))")
        end
    end
    agents_block = DOM.details(
        DOM.summary(
            DOM.span("Global agent instructions (AGENTS.md)";
                     class = "bt-discover-title");
            class = "bt-discover-header"),
        DOM.div(
            DOM.div("Appended to the system prompt of every agent session " *
                    "on every worker — shared conventions, house rules, " *
                    "tool guidance. Saved to the server's state dir.";
                    class = "bt-agents-hint"),
            DOM.textarea(global_agents_md(state);
                class = "bt-agents-textarea", rows = 10,
                placeholder = "e.g. ## Conventions every agent must follow…"),
            DOM.div(
                DOM.span(agents_status; class = "bt-agents-status"),
                DOM.button("Save";
                    class = "bt-btn bt-btn-sm",
                    onclick = js"""event => {
                        const ta = event.target.closest('.bt-agents-body')
                                       .querySelector('textarea');
                        $(agents_saved).notify(ta.value);
                    }""");
                class = "bt-agents-actions");
            class = "bt-agents-body");
        class = "bt-card bt-agents-block")

    # Drive the KeyedList off a derived Observable that yields a stable
    # vector of WorkerCard instances (same widget objects across renders →
    # same hash → no spurious unmount/remount).
    worker_widgets_obs = map(state.workers) do workers
        WorkerCard[get_worker_card(w.worker_id) for w in values(workers)]
    end
    worker_keyed_list = KeyedList(worker_widgets_obs;
                                    key = c -> c.worker_id)
    # Connected workers first (the real content), then the "add another"
    # disclosure beneath them.
    worker_list = DOM.div(
        DOM.div(worker_keyed_list; class = "bt-cards"),
        DOM.div(install_block; class = "bt-install-wrap"))

    # ── Project list ────────────────────────────────────────────────────────
    # The standalone dashboard "Projects" card list was removed: it duplicated
    # the per-worker `▸ projects` tree (in each WorkerCard) and the left sidebar
    # ("running on workers"). The only card-only feature was move-to-worker,
    # which is being redesigned. Project creation stays on the dashboard via the
    # + New project / + From GitHub buttons; the projects themselves live in the
    # worker pills and the sidebar. (`ProjectCard`, `sync_request`,
    # `open_request` remain defined for the future move-to-worker redesign.)

    # Two slide-in forms, one source of truth: which one is open right now.
    form_block = map(which_form) do which
        if which === :new_project
            DOM.div(new_proj_form(); class = "bt-slide-in")
        elseif which === :github
            DOM.div(gh_form(); class = "bt-slide-in")
        else
            DOM.div()
        end
    end
    error_block = map(error_obs) do msg
        isempty(msg) ? DOM.div() : DOM.div(msg; class = "bt-error")
    end

    # Global busy progress pill — fixed top-centered, single text line.
    # Wrapper stays mounted; visibility flips via class toggle (instant
    # attribute update). The three text spans bind to derived
    # Observable{String}s so they hit Bonito's innerText fast-path — no
    # wrapper re-render and no DOM swap during the thousands of file
    # events that a librsync transfer fires.
    title_obs = map(s -> s.title, busy)
    pct_obs   = map(busy) do s
        s.total > 0 ? "$(round(Int, 100 * s.done / max(s.total, 1)))%" : ""
    end
    msg_obs   = map(s -> s.msg, busy)
    visibility_class = map(busy) do s
        is_busy_idle(s) ? "bt-busy-card bt-busy-hidden" : "bt-busy-card"
    end
    busy_card = DOM.div(
        DOM.span(title_obs; class = "bt-busy-title"),
        DOM.span(pct_obs;   class = "bt-busy-pct"),
        DOM.span(msg_obs;   class = "bt-busy-msg");
        class = visibility_class)

    # Layout — DOM only; the App() wrapper + global assets (DashboardStyles,
    # ConnectionIndicator) live in the caller (unified_app or dashboard_app).
    DOM.div(
        busy_card,
        DOM.div(
            DOM.h1(
                DOM.img(src = logo_svg(), alt = "", class = "bt-logo",
                        draggable = "false"),
                "BonitoAgents"),
            DOM.div("Multi-host orchestrator for agentic coding sessions";
                    class = "bt-tagline"),
            # Recent-chats overview — the header IS the landing overview: the
            # last 6 chats as clickable cards (title, count, last prompts,
            # last image), kept fresh via chat_signal/projects (overview.jl).
            recent_chats_dom(session, state, current_view);
            class = "bt-header"),
        stats_strip,
        error_block,

        DOM.div(DOM.h2("Workers"); class = "bt-section"),
        worker_list,

        DOM.div(DOM.h2("Agents"); class = "bt-section"),
        agents_block,

        DOM.div(
            DOM.h2("New project"),
            new_proj_btn,
            gh_btn;
            class = "bt-section"),
        form_block,

        DOM.div(
            DOM.h2("Defaults"),
            DOM.div("Applied to new & unconfigured chats; a chat's own picks override.";
                    class = "bt-defaults-hint"),
            session_defaults_bar(session, state);
            class = "bt-section");

        class = "bt-dash")
end

# ── Cross-worker sync modal ─────────────────────────────────────────────────
# Surfaced from the chat header when a project has a same-named sibling on
# another worker (see `same_name_siblings`). `sync_modal_state` is `nothing`
# (hidden) or `(current, other, comparison)` where comparison comes from
# `compare_projects`. The user picks a direction; `on_apply(src, dst)` runs the
# directional overwrite via `sync_across_workers!`. Reuses the `bt-collision-*`
# CSS that already ships in DashboardStyles.
# One opened-modal instance. Rendered via `jsrender` so its three button
# handlers register on the PER-RENDER sub-session (T22), not the long-lived
# parent — `map(session, sync_modal_state)` frees that sub-session when the
# modal closes / reopens, so handlers + the retained `comparison` don't pile up.
struct SyncModalContent
    state            :: ServerState
    sync_modal_state :: Observable
    on_apply         :: Function
    c                :: Any   # (current, other, comparison) NamedTuple
end

function render_sync_modal(session::Bonito.Session,
                            state::ServerState,
                            sync_modal_state::Observable,
                            on_apply::Function)
    # Always return a SyncModalContent (c === nothing renders the hidden
    # state inside jsrender): the map's output Observable takes the type of
    # the FIRST result, and the modal always starts hidden — returning a
    # DOM.div() here would pin the Observable to Node{HTMLSVG} and the
    # later open (a SyncModalContent) would throw a convert MethodError.
    map(session, sync_modal_state) do c
        # Return a renderable: its jsrender runs in this map iteration's
        # sub-session, so the button handlers it registers are freed when this
        # value is superseded (modal closed or reopened) — fixing the handler
        # accumulation (T22).
        SyncModalContent(state, sync_modal_state, on_apply, c)
    end
end

function Bonito.jsrender(session::Bonito.Session, m::SyncModalContent)
    # Hidden state — no comparison to show.
    m.c === nothing && return Bonito.jsrender(session, DOM.div())
    state            = m.state
    sync_modal_state = m.sync_modal_state
    on_apply         = m.on_apply
    c                = m.c
    worker_label(id) = haskey(state.workers[], id) ? state.workers[][id].name : id
    cur_label   = worker_label(c.current.worker_id)
    other_label = worker_label(c.other.worker_id)

    cur_side = sync_side_panel(
        "$(cur_label) (this chat)", c.current.worker_path,
        c.comparison.a,
        c.comparison.a_source === :worker ? "live" : "server mirror")
    other_side = sync_side_panel(
        other_label, c.other.worker_path,
        c.comparison.b,
        c.comparison.b_source === :worker ? "live" : "server mirror")

    # Highlight whichever side was edited more recently.
    cur_mt   = Float64(c.comparison.a["latest_mtime"])
    other_mt = Float64(c.comparison.b["latest_mtime"])
    newer = cur_mt > other_mt ? :current : (other_mt > cur_mt ? :other : :tie)
    if newer === :current
        cur_side = DOM.div(cur_side; class = "bt-collision-newer")
    elseif newer === :other
        other_side = DOM.div(other_side; class = "bt-collision-newer")
    end

    push_btn = Bonito.Button("Use $cur_label → overwrite $other_label";
        style = nothing, class = "bt-btn bt-btn-primary",
        title = "Copy $(cur_label)'s files onto $other_label, overwriting it")
    pull_btn = Bonito.Button("Use $other_label → overwrite $cur_label";
        style = nothing, class = "bt-btn bt-btn-secondary",
        title = "Copy $(other_label)'s files onto $cur_label, overwriting it")
    cancel_btn = Bonito.Button("Cancel"; style = nothing,
        class = "bt-btn bt-btn-ghost")
    # Register on THIS render's session (freed when the modal closes/reopens).
    on(session, push_btn.value) do clicked
        clicked || return
        on_apply(c.current, c.other)
    end
    on(session, pull_btn.value) do clicked
        clicked || return
        on_apply(c.other, c.current)
    end
    on(session, cancel_btn.value) do clicked
        clicked || return
        sync_modal_state[] = nothing
    end

    node = DOM.div(
        DOM.div(
            DOM.div(
                DOM.h3("Sync '$(c.current.name)' across workers"),
                DOM.div("This project exists on both $cur_label and $other_label. " *
                        "Pick which side's files to keep — the other side is overwritten.";
                        class = "bt-collision-sub")),
            DOM.div(cur_side, other_side; class = "bt-collision-sides"),
            DOM.div(cancel_btn, pull_btn, push_btn;
                    class = "bt-collision-actions");
            class = "bt-collision-card");
        class = "bt-collision-overlay")
    return Bonito.jsrender(session, node)
end

# One column of the side-by-side compare. Top line is the headline decision
# signal (last edit time), then file/byte counts, then a short recent-files
# list and a per-subrepo git breakdown.
function sync_side_panel(title::AbstractString,
                          path::AbstractString,
                          summary::AbstractDict,
                          source_label::AbstractString)
    age_str    = format_relative_age(Float64(summary["latest_mtime"]))
    n_files    = Int(summary["total_files"])
    total_kb   = round(Int(summary["total_bytes"]) / 1024; digits = 1)
    recent     = summary["recent_files"]
    subrepos   = summary["git_subrepos"]

    recent_rows = if isempty(recent)
        [DOM.div("(no files)"; class = "bt-collision-empty")]
    else
        [DOM.div(
            DOM.span(String(r["path"]); class = "bt-collision-file-path"),
            DOM.span(format_relative_age(Float64(r["mtime"]));
                     class = "bt-collision-file-age");
            class = "bt-collision-file-row") for r in recent]
    end

    git_rows = if isempty(subrepos)
        [DOM.div("no git sub-repos found"; class = "bt-collision-empty")]
    else
        [sync_git_row(g) for g in subrepos]
    end

    DOM.div(
        DOM.div(title; class = "bt-collision-side-title"),
        DOM.div(path; class = "bt-collision-side-path", title = String(path)),
        DOM.div(
            DOM.div(
                DOM.span("Last edit: "; class = "bt-collision-label"),
                DOM.span(age_str; class = "bt-collision-value")),
            DOM.div(
                DOM.span("Files: "; class = "bt-collision-label"),
                DOM.span("$n_files ($(total_kb) KB)"; class = "bt-collision-value")),
            DOM.div(
                DOM.span("Source: "; class = "bt-collision-label"),
                DOM.span(source_label; class = "bt-collision-value-faint"));
            class = "bt-collision-stats"),
        DOM.div(
            DOM.h5("Recent files"),
            recent_rows...;
            class = "bt-collision-recent"),
        DOM.div(
            DOM.h5("Git sub-repos"),
            git_rows...;
            class = "bt-collision-git");
        class = "bt-collision-side")
end

function sync_git_row(g::AbstractDict)
    head = String(get(g, "head_sha", ""))
    short_sha = isempty(head) ? "(no head)" : (length(head) >= 7 ? head[1:7] : head)
    dirty = Int(get(g, "dirty_count", 0))
    branch = String(get(g, "branch", ""))
    head_time = Float64(get(g, "head_time", 0.0))
    dirty_str = dirty == 0 ? "clean" : "$dirty dirty"
    DOM.div(
        DOM.div(String(g["path"]); class = "bt-collision-git-path"),
        DOM.div(
            DOM.span("$branch @ $short_sha"; class = "bt-collision-git-ref"),
            DOM.span(dirty_str; class = dirty == 0 ?
                "bt-collision-git-clean" : "bt-collision-git-dirty"),
            DOM.span(format_relative_age(head_time); class = "bt-collision-git-age"));
        class = "bt-collision-git-row")
end

# "5m ago" / "3h ago" / "2d ago" — short, glanceable.
function format_relative_age(t::Float64)
    t <= 0 && return "—"
    Δ = time() - t
    Δ < 0    && return "in the future"
    Δ < 60   && return "$(round(Int, Δ))s ago"
    Δ < 3600 && return "$(round(Int, Δ / 60))m ago"
    Δ < 86400 && return "$(round(Int, Δ / 3600))h ago"
    Δ < 86400 * 30 && return "$(round(Int, Δ / 86400))d ago"
    return "$(round(Int, Δ / (86400 * 30)))mo ago"
end

# Thin shim for callers that want a standalone dashboard App (tests, the
# pre-unified-app routes). The unified app instead embeds dashboard_dom
# directly into its main panel.
function dashboard_app(state::ServerState)
    App() do session
        # Per-session view (see ServerState's Base.copy). `dashboard_dom`
        # subscribes to `view.version`, so the per-session connected child
        # Observable is what drives re-renders for this tab — and tears
        # down via `session.deregister_callbacks` on close.
        view = copy(state, session)
        DOM.div(
            DashboardStyles,
            Bonito.ConnectionIndicator(),
            dashboard_dom(session, view))
    end
end

# The base URL shown in the dashboard's install one-liner. MUST match what
# the /install routes were templated with — so the snippet the user copies is
# the literal command that works, not a "<your-server>" placeholder. `serve()`
# records the resolved url on `state.base_url`; fallbacks cover states built
# outside `serve()` (tests, standalone dashboards).
function install_base_url(state::ServerState)
    isempty(state.base_url[]) || return state.base_url[]
    url = get(ENV, "BONITOAGENTS_PUBLIC_URL", "")
    isempty(url) || return rstrip(url, '/')
    state.srv === nothing || return rstrip(Bonito.online_url(state.srv, ""), '/')
    return "http://<your-server>:8038"
end
