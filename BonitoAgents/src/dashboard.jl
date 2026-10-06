# Project lock + chat / dashboard orchestration. State (workers, projects,
# pending RPCs, etc.) lives in `state.jl::ServerState`; every public function
# in this file takes a `state::ServerState` argument as its first parameter.
# Worker registration is handled in worker_client.jl when the worker dials
# the server's /w endpoint. Liveness comes from the worker's link; no
# periodic probing here.

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
    notify_projects!(state)
    return p
end

function release_project!(state::ServerState, p::ProjectInfo)
    lock(state.lock) do
        p.locked_by = nothing
        p.locked_at = nothing
        save_projects!(state)
    end
    notify_projects!(state)
    return p
end

# Release every project claim held by `worker_id` (called from
# `teardown_worker!` when the worker's link dies). Snapshot the
# matching projects under the lock so we don't iterate `state.projects[]`
# while a concurrent writer is mutating it; `release_project!` re-takes the
# lock per project (reentrant, harmless).
function release_projects_for_worker!(state::ServerState, worker_id::String)
    targets = lock(state.lock) do
        [p for p in values(state.projects[]) if p.locked_by == worker_id]
    end
    foreach(p -> release_project!(state, p), targets)
end

# ── Foreign (worker) path hygiene ───────────────────────────────────────────
# A worker can run a different OS than the server, so `ProjectInfo.worker_path`
# is a path string the server only ever STORES and echoes back — it must never
# be interpreted with the server's own separator.
#
# Windows paths are the hazard. A backslash is an escape character in JS string
# literals, so a `C:\Users\sdani\Programmieren\VulkanDev` that reaches JS
# unescaped comes back as `C:UserssdaniProgrammierenVulkanDev` — `\U`, `\s` and
# `\P` are invalid escapes and JS just drops the backslash. Reported from a real
# Windows worker: every `session/load` then ran with a cwd that doesn't exist.
#
# Windows accepts forward slashes everywhere, and forward slashes survive JS,
# JSON and HTML untouched, so we normalize ONCE on the way in and store only
# forward-slash paths. Linux paths are left alone — a backslash is a legal
# character in a Linux filename, so rewriting one would corrupt it.
windows_path(p::AbstractString) =
    occursin(r"^[A-Za-z]:[\\/]", p) || startswith(p, "\\\\")

normalize_worker_path(p::AbstractString) =
    windows_path(p) ? replace(String(p), '\\' => '/') : String(p)

# A drive letter followed by something that is NOT a separator (`C:Users…`) is a
# path whose backslashes were already eaten. It cannot be repaired — the
# separator positions are gone — so callers refuse it loudly rather than store a
# project whose every session bring-up fails with an inexplicable cwd.
mangled_windows_path(p::AbstractString) = occursin(r"^[A-Za-z]:[^\\/]", p)

# Join a project NAME onto a worker's `projects_root`. NOT `joinpath`: that uses
# the SERVER's separator, so a Windows worker's `C:\Users\x\projects` came out as
# `C:\Users\x\projects/Name`. The root is normalized to forward slashes first, so
# a plain join is both correct and consistent with every other path we store.
worker_join(root::AbstractString, name::AbstractString) =
    rstrip(normalize_worker_path(root), '/') * "/" * String(name)

# Creating a project is a WORKER-ONLY operation. There is deliberately no
# server-side counterpart of `create_project_from_worker!`: the server has no
# checkout to create a project from, only a mirror it may later be asked to sync.
# The removed `create_project!` validated a SERVER-local folder (`isdir`),
# rsync'd it into the working dir and pushed it to the worker — so every path in
# it was a server path, and pointing the (worker) folder picker at it failed with
# "Source path is not a directory" for a folder that exists on the worker. It had
# no callers left; both create forms go through `create_project_from_worker!`.

"""
    worker_dir_or_error(state, worker_id, path) -> String

Confirm `path` is an existing DIRECTORY **on the worker**, and return the
worker's own absolute form of it.

The server cannot answer this question. The folder lives on the worker, so an
`isdir` here would stat the wrong machine — returning false for a folder that
exists, or (worse) true for a same-named folder on the server box that has
nothing to do with it. So we ask, and we store what the worker's own `abspath`
says: no separator guessing, no server filesystem in the loop.

This is the guard for the address bar. The picker's folder rows can only ever
produce paths the worker just listed, but the bar is a free-text field — a typo
there registered a project whose every session bring-up then failed with an
inexplicable cwd. It also catches the folder that was deleted, renamed or
unmounted between listing it and pressing Create.
"""
function worker_dir_or_error(state::ServerState, worker_id::AbstractString,
                              path::AbstractString)
    wid = String(worker_id)
    w   = get(state.workers[], wid, nothing)
    who = w === nothing ? wid : w.name
    st  = stat_worker_path(state, wid, path)
    st.exists || error("No such folder on $who: $path")
    st.isdir  || error("Not a folder on $who (it's a file): $path")
    return normalize_worker_path(st.path)
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
                                      name::String = project_name_from_path(worker_path),
                                      sync::Bool = false,
                                      resume_session_id::Union{String,Nothing} = nothing,
                                      provider::Union{String,Nothing} = nothing,
                                      start_session::Bool = true,
                                      progress = nothing)
    # A worker may run a different OS than the server, so `worker_path` is a
    # FOREIGN path the server only stores and echoes back — normalize it once,
    # HERE, before it is stored or used to derive anything. See
    # `normalize_worker_path`. (`name`'s default above normalizes first too:
    # `basename` of a backslash path on a Linux server returns the WHOLE string,
    # which made the project name the entire path — see `project_name_from_path`.)
    mangled_windows_path(worker_path) && error(
        "Worker path '$worker_path' lost its separators (a Windows path whose " *
        "backslashes were eaten). It can't be repaired — re-pick the folder.")
    worker_path = normalize_worker_path(worker_path)
    # `start_session=false` skips the post-registration ACP session
    # bring-up. Used by tests that exercise the import logic without
    # needing a real worker subprocess; production callers always want
    # the chat ready, so the default stays `true`.
    maybe_start = p -> start_session && ensure_project_session!(state, p)
    haskey(state.workers[], worker_name) || error("Unknown worker: $worker_name")
    isempty(name) && error("Project name must not be empty (folder has no basename?)")
    valid_project_name(name) ||
        error("Project name can't contain / or \\ or start with a dot — got '$name'")
    isempty(worker_path) && error("Worker path is required (pick a folder).")

    # Threads: a folder can hold several conversations, identified by
    # (worker, path, chat_id) where chat_id is the agent's session id. Importing
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
    # The session id and the agent that minted it travel together — the discover
    # scan reports the provider per row, so a resumed kimi thread comes back up
    # under kimi instead of the default.
    p.provider = provider
    track_project!(state, p)

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
    notify_projects!(state)

    notify_progress(progress, :phase, (msg = "Starting chat session…",))
    maybe_start(p)
    return p
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
    notify_projects!(state)
    try
        sync_dir_from_worker!(state, p.worker_id, p.worker_path, p.server_path;
                              on_progress = on_progress)
        p.backup_status = :synced
        p.last_sync_at  = now(UTC)
        save_projects!(state)
        notify_projects!(state)
    catch e
        p.backup_status = :stale
        notify_projects!(state)
        rethrow(e)
    end
    return p
end

"""
    ensure_project_session!(state, p; progress=nothing) → ChatModel

Build (or return) the chat ChatModel for `p` on the worker it belongs to:
the cached model, or a new one claimed on that worker. Idempotent. A chat never
changes workers; "Continue on <worker>" makes a new one (`continue_on!`).

Called from project creation flows and worker reconnect. The unified app's main
panel pulls the cached model out of state.chat_models when the user selects this
project in the sidebar.
"""
function ensure_project_session!(state::ServerState, p::ProjectInfo; progress = nothing)
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
        notify_projects!(state)
    end

    claim_project!(state, p, w.worker_id)

    # The worker reports its BonitoMCP launch as a `julia` binary (`mcp_path`)
    # plus an argv array (`mcp_args`) — no shell wrapper, so it's identical on
    # Windows. claude-agent-acp spawns `command + args` directly.
    # `env` carries the chat's identity; the worker adds its relay grant
    # (BonitoWorker's `inject_mcp_grant`), the MCP's only way to the server.
    #
    # The server name must NOT collide with any MCP server the user has in their
    # global/project config: claude-agent-acp runs the agent with
    # settingSources ["user","project","local"], so it ALSO loads the user's
    # `~/.claude.json` mcpServers. A same-named (e.g. stale/broken) entry there
    # shadows the one we inject here, and the tools silently vanish. `btworker`
    # is deliberately specific to avoid that — see `mcp__btworker__*` tool names.
    mcp = isempty(w.mcp_path) ? AgentClientProtocol.MCPServer[] :
        [AgentClientProtocol.MCPServer(INJECTED_MCP_NAME, w.mcp_path;
                                       args = w.mcp_args,
                                       env  = mcp_env(state, p.id))]

    # The agent carries everything start! needs — the `resume_session_id` (so
    # bring-up uses session/load) and the agent this thread was last used with.
    # The two are paired: that id only means anything to the agent that issued it.
    prov = project_provider(p)
    # Substituting the agent is worth saying HERE and only here — the chat is
    # about to run on a different backend than the thread belongs to, and its
    # resume id belongs to the one we couldn't find.
    p.provider === nothing || provider_name(prov) == p.provider ||
        @warn "project's agent is not available here; opening with the default" project =
            p.name wanted = p.provider opening_with = provider_name(prov)

    agent = WorkerAgent(state, w.worker_id, p.worker_path;
                        project_id        = p.id,
                        mcp               = mcp,
                        resume_session_id = p.resume_session_id,
                        provider          = prov)

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
    # A fresh chat binds eagerly too: its config pills (model, permission mode)
    # ride the `session/new` result, so lazy binding left "+ new thread" showing
    # neither until the user had already sent something.
    eager_bind = if p.resume_session_id !== nothing
        isempty(shared(model).msgs_store) || session_advanced_since_sync(state, p)
    else
        isempty(shared(model).msgs_store)      # brand-new thread, nothing to show yet
    end
    if eager_bind
        Base.errormonitor(@async try
            restart_chat_session!(model)
        catch e
            @warn "eager bind on open failed" project_id = p.id exception = (e, catch_backtrace())
        end)
    else
        maybe_resync_on_open!(state, p, model)
    end

    fire_auto_prompt!(model)
    return model
end

# How stale a worker's scan may be before opening a chat refreshes it: long
# enough that clicking between chats doesn't scan on every click.
const RESCAN_ON_OPEN_AFTER = 30.0

"""
    maybe_resync_on_open!(state, p, model)

Refresh `p`'s worker scan when it's stale, then bind if the session moved on.

`session_advanced_since_sync` reads `state.discovered`, which was only ever
refreshed on a worker's FIRST connect or by the Rescan button — so continuing a
session in the Claude CLI left the freshness signal itself stale, and re-opening
the chat showed a frozen snapshot. Async: the view mounts immediately and the
replayed history fills in.
"""
function maybe_resync_on_open!(state::ServerState, p::ProjectInfo, model)
    p.resume_session_id === nothing && return nothing
    last = lock(() -> get(state.last_scan, p.worker_id, 0.0), state.lock)
    time() - last < RESCAN_ON_OPEN_AFTER && return nothing
    Base.errormonitor(@async try
        scan_and_store!(state, p.worker_id)
        # Re-ask now that the scan is current; bind only if it actually moved.
        session_advanced_since_sync(state, p) && restart_chat_session!(model)
    catch e
        @warn "resync on open failed" project_id = p.id exception = (e, catch_backtrace())
    end)
    return nothing
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
    # A closed chat is not continued after a worker crash.
    forget_interrupted_turn!(state, p.id)
    # The reaped claude subprocess takes its MCP server + eval worker with it, so
    # the eval bridge's worker session is gone — tear the bridge down explicitly
    # (a WS drop alone no longer does; its lifetime is the worker session).
    teardown_eval_bridge!(state, p.id)
    # Its evals on OTHER workers end with it: those hosts serve this session only.
    close_eval_hosts!(state, p.id)
    return nothing
end

"""
    continue_on!(state, p, target_worker_id; progress = nothing) -> ProjectInfo

"Continue on <worker>": a NEW chat on `target_worker_id` that picks up where `p`
is, with the agent's own record of the conversation (so it resumes with its
memory) and the project's files as they are now. `p` is left alone: its session
keeps running, and whatever it is doing finishes where it started.

This used to MOVE the chat: stop its session, re-bind it to the target, start it
there. A move that took a while left the user chatting in a chat that was about
to change machines under them, and afterwards it ran on the target while tools
and background tasks it had started kept running on the source.

The conversation is carried first, at a turn boundary (the caller refuses while
a turn runs), and the files after, so chatting on in `p` meanwhile changes
neither what the new chat remembers nor where `p` runs.
"""
function continue_on!(state::ServerState, p::ProjectInfo, target_worker_id::AbstractString;
                      progress = nothing)
    target_id = String(target_worker_id)
    target_w = get(state.workers[], target_id, nothing)
    target_w === nothing && error("Unknown worker: $(target_id)")
    isopen(target_w) || error("Worker '$(target_w.name)' is offline")
    target_id == p.worker_id && error("$(p.name) already runs on $(target_w.name)")
    source_online = haskey(state.workers[], p.worker_id) && isopen(state.workers[][p.worker_id])
    # With the source offline only the server's mirror can be pushed. A project
    # registered without a sync has an EMPTY mirror; pushing that once emptied a
    # live folder at the target (2026-09-15). Refuse before anything moves.
    source_online || p.last_sync_at !== nothing ||
        error("Cannot continue $(p.name) on $(target_w.name): its worker is offline and the server " *
              "holds no copy of it (never synced). Bring the worker online, or sync the project first.")
    target_path = worker_join(target_w.projects_root, p.name)

    carried = carry_session!(state, p, target_w, target_path; progress)

    if source_online
        source_name = state.workers[][p.worker_id].name
        notify_progress(progress, :phase, (msg = "Pulling the files from $(source_name)…",))
        try
            sync_project_to_server!(state, p; on_progress = progress)
        catch e
            e isa InterruptException && rethrow()
            # A mirror synced before is still worth pushing; none at all is not.
            p.last_sync_at === nothing && rethrow()
            @warn "pulling from the source worker failed; continuing from the server's copy" project = p.name source = p.worker_id exception = e
        end
    end
    notify_progress(progress, :phase, (msg = "Pushing the files to $(target_w.name)…",))
    # Additive: whatever already sits at the target path stays.
    sync_dir_to_worker!(state, target_id, p.server_path, target_path; on_progress = progress)

    # The new chat. A folder the target already has a chat in shares that
    # chat's server mirror; otherwise it gets its own, empty until it is synced,
    # like a chat opened on a worker's folder (never a second full copy).
    sibling = find_project_by_location(state, target_id, target_path)
    new_id = string(uuid4())[1:8]
    server_path = sibling !== nothing ? sibling.server_path :
        (base = joinpath(state.working_dir, p.name); ispath(base) ? "$(base)-$(new_id)" : base)
    new_p = ProjectInfo(new_id, p.name, target_id, server_path, target_path, now(UTC))
    new_p.resume_session_id = carried ? p.resume_session_id : nothing
    new_p.provider = p.provider
    new_p.desired_config = copy(p.desired_config)
    new_p.title[] = p.title[]
    add_project!(state, new_p)
    @info "chat continued on another worker" source = p.id new = new_id target = target_w.name carried
    return new_p
end

"""
    carry_session!(state, p, target_w, target_path; progress = nothing) -> Bool

Move the agent's on-disk record of `p`'s conversation (for Claude Code: the
transcript, subagent transcripts and project memory) from its current worker to
`target_w`, so `session/load` on the target resumes with the agent's memory
intact. Server-mediated like the project files: the source worker stages the
session under its projects root, the server pulls it, pushes it under the
target's projects root, and the target installs it into its transcript
directory for `target_path` (rewriting the recorded working directory).

Returns `true` when the record now sits on the target and `p.resume_session_id`
can be kept. `false` means the move goes on with a fresh session: no session yet,
a provider whose record we don't know how to move, the source worker offline,
or a transport that failed — the failure is logged with its reason, since none
of them should stop the user from continuing their chat elsewhere.
"""
function carry_session!(state::ServerState, p::ProjectInfo, target_w::WorkerInfo,
                        target_path::AbstractString; progress = nothing)
    sid = p.resume_session_id
    sid === nothing && return false
    provider = project_provider(p)
    session_state_format(provider) === nothing && return false
    src_w = get(state.workers[], p.worker_id, nothing)
    (src_w === nothing || !isopen(src_w)) && return false
    staging_src = worker_join(src_w.projects_root, AgentProviders.TRANSFER_DIRNAME * "/" * p.id)
    staging_dst = worker_join(target_w.projects_root, AgentProviders.TRANSFER_DIRNAME * "/" * p.id)
    server_dir  = joinpath(state.state_dir, "transfers", p.id)
    pname = provider_name(provider)
    carried = try
        notify_progress(progress, :phase,
            (msg = "Packing the conversation on $(src_w.name)…",))
        staged = stage_session_on_worker(state, src_w.worker_id; provider = pname,
                                         cwd = p.worker_path, session_id = sid,
                                         staging = staging_src)
        isdir(server_dir) && rm(server_dir; recursive = true)
        notify_progress(progress, :phase,
            (msg = "Pulling the conversation from $(src_w.name)…",))
        sync_dir_from_worker!(state, src_w.worker_id, staging_src, server_dir;
                              on_progress = progress)
        notify_progress(progress, :phase,
            (msg = "Pushing the conversation to $(target_w.name)…",))
        sync_dir_to_worker!(state, target_w.worker_id, server_dir, staging_dst;
                            on_progress = progress)
        installed = install_session_on_worker(state, target_w.worker_id; provider = pname,
                                              cwd = target_path, old_cwd = p.worker_path,
                                              session_id = sid, staging = staging_dst)
        @info "conversation carried to worker" project = p.name target = target_w.name session = sid entries = staged.entries bytes = staged.bytes installed
        true
    catch e
        e isa InterruptException && rethrow()
        @warn "could not carry the conversation to the new worker; the agent starts fresh there" project = p.name source = src_w.name target = target_w.name exception = (e, catch_backtrace())
        false
    end
    # Leave nothing behind either way: the server's copy, and the source's
    # staging directory (the target's is consumed by the install).
    isdir(server_dir) && rm(server_dir; recursive = true, force = true)
    try
        discard_staging_on_worker(state, src_w.worker_id; staging = staging_src)
    catch e
        e isa InterruptException && rethrow()
        @warn "could not remove the staged conversation on the source worker" source = src_w.name staging = staging_src exception = e
    end
    return carried
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
    # ONE name rule app-wide (`valid_project_name`), not a second, stricter one
    # here: this used to demand `^[a-zA-Z0-9_\-]+$` while REPORTING the
    # valid_project_name rule, so copying a project the create flow had happily
    # named "Mantle DNN" failed with a message that described a different rule.
    # Everything past "it must stay one path component" is the target
    # filesystem's call, and it makes it below when the copy lands.
    valid_project_name(String(name)) ||
        error("Project name can't contain / or \\ or start with a dot — got '$name'")

    target_path = worker_join(target_w.projects_root, name)
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
    return add_project!(state, new_p)
end

# Dashboard styles — modern surface + spacing system, status dots, smooth transitions
const DashboardStyles = Bonito.Styles(
    # Tokens, reset, buttons and menus come from the shared base (styles.jl):
    # the dashboard can be mounted without ChatStyles, and must still agree
    # with it on every one of them.
    BASE_CSS...,

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
    # The wordmark, and the Settings button at the far end of its line.
    CSS(".bt-header-top",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "12px",
        "align-self" => "stretch", "flex-basis" => "100%"),
    CSS(".bt-copy-project",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "flex-wrap" => "wrap"),

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
    # Action buttons of a section, grouped as one unit on the right instead of
    # space-between scattering each button across the full row.
    CSS(".bt-section-actions",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "flex-wrap" => "wrap"),
    # Sections whose content reads as body text: stack heading above content.
    # In the space-between row the long hint text collided with the h2 at
    # medium widths ("DEFAULTSApplied to new ...").
    CSS(".bt-section-stack",
        "flex-direction" => "column", "align-items" => "flex-start",
        "gap" => "4px"),

    # ── Settings card ────────────────────────────────────────────────────────
    # One card, uniform rows (`settings_row`): title + hint left, control right,
    # hairline between rows. Overrides the card's own padding/gap so the rows
    # own the spacing.
    CSS(".bt-settings", "padding" => "0", "gap" => "0"),
    CSS(".bt-settings-row",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "flex-wrap" => "wrap",
        "gap" => "var(--bt-space-3) var(--bt-space-4)",
        "padding" => "14px 16px"),
    CSS(".bt-settings-row + .bt-settings-row",
        "border-top" => "1px solid var(--bt-border)"),
    CSS(".bt-settings-text", "flex" => "0 1 auto", "min-width" => "0"),
    # Dotted underline: the standing "there is a tooltip here" affordance, the
    # same one `.bt-path-link` uses for a clickable path.
    CSS(".bt-settings-title",
        "font-weight" => "600", "font-size" => "13px",
        "text-decoration" => "underline dotted",
        "text-decoration-color" => "var(--bt-text-faint)",
        "text-underline-offset" => "3px",
        "cursor" => "help"),
    CSS(".bt-settings-control",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "flex" => "0 1 auto", "flex-wrap" => "wrap", "justify-content" => "flex-end",
        "min-width" => "0"),
    # The defaults bar names itself ("Session defaults"); in a row that already
    # carries the title, that label is noise.
    CSS(".bt-settings .bt-defaults-label", "display" => "none"),

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
    # Remove-worker affordance: a faint ✕ at the far right of the card's top
    # row, after the action buttons, turning red on hover so it reads as
    # destructive.
    CSS(".bt-card-remove",
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
        # Fill the title row: a plain input defaults to ~170px and hard-truncates
        # long worker names ("simon-dev-") with room to spare.
        "flex" => "1 1 auto",
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
    # Machine identity is shared with every chat badge and border.
    CSS(".bt-worker-card", "border-left" => "4px solid var(--bt-worker)"),
    CSS(".bt-worker-card input.bt-card-initials, .bt-worker-card span.bt-card-initials",
        "background" => "var(--bt-worker)", "color" => "white",
        "border" => "1px solid var(--bt-worker)",
        "padding" => "4px 6px", "border-radius" => "var(--bt-radius-sm)"),
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

    # (Buttons: `.bt-btn` and its variants live in BASE_CSS, styles.jl.)

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
    # A note that belongs to the field ABOVE it, not to a label: it sits in the
    # value column, where the input it explains is. Dropped into the grid as a
    # plain child it landed in the 120px label column instead and wrapped to
    # four lines.
    CSS(".bt-form-note",
        "grid-column" => "2",
        "font-size" => "11px", "color" => "var(--bt-text-muted)",
        "margin-top" => "-6px"),
    # An input that paints its own `background` must paint its own `color` too —
    # otherwise the text is the UA's `fieldtext` and follows the OS color scheme
    # while the background stays our light token. `html:root { color-scheme: light }`
    # already pins that, this is the belt to its braces.
    CSS(".bt-form input, .bt-form select",
        "padding" => "8px 10px",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "14px",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
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
    # The single-path field row: the editable path IS the selection. The
    # existence note underneath (missing/file) is purely cosmetic.
    CSS(".bt-picker-field",
        "flex" => "1 1 0", "min-width" => "0",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "4px"),
    CSS(".bt-picker-path-hold",
        "min-width" => "0"),
    CSS(".bt-picker-path",
        "width" => "100%",
        "box-sizing" => "border-box",
        "min-width" => "0",
        "padding" => "6px 8px",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",   # see `.bt-form input` — never inherit fieldtext
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "12px"),
    CSS(".bt-picker-exist",
        "font-size" => "11px",
        "min-height" => "14px"),
    CSS(".bt-picker-exist-missing",
        "color" => "var(--bt-warning)"),
    CSS(".bt-picker-exist-file",
        "color" => "#b91c1c"),
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
    # One click selects the whole command, for copying it by hand.
    CSS(".bt-install-cmd code",
        "white-space" => "pre", "overflow-x" => "auto", "user-select" => "all"),
    CSS(".bt-install-copy",
        "user-select" => "none",
        "background" => "rgba(255,255,255,0.06)",
        "color" => "#e2e8f0",
        "border" => "1px solid rgba(255,255,255,0.12)",
        "padding" => "4px 10px", "border-radius" => "4px",
        "font-size" => "12px", "cursor" => "pointer",
        "transition" => "background 120ms"),
    CSS(".bt-install-copy:hover",
        "background" => "rgba(255,255,255,0.12)"),

    # ── Global agent instructions (AGENTS.md) editor ─────────────────────────
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
        # One column here, so the note can't sit in a second one.
        CSS(".bt-form-note", "grid-column" => "1"),
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

)

# Normalize a path for use inside the picker / for JS string interpolation.
# Julia accepts forward slashes on Windows for all FS operations, while raw
# backslashes are invalid escape sequences in JS string literals (`\U`, `\s`,
# …) — embedding them produces either silent corruption or SyntaxErrors. By
# routing every picker path through forward slashes we sidestep both issues
# without losing Windows-correctness.
js_path(p::AbstractString) = replace(String(p), '\\' => '/')

"""
    valid_project_name(name) -> Bool

Whether `name` is usable as a project name.

It has to be a safe single PATH COMPONENT, because moving a project to another
worker lands it at `worker_join(w.projects_root, p.name)`. That rules out path
separators and `..`, and leading dots (a hidden directory, and `.`/`..`
themselves). It does NOT rule out spaces: the old rule was an
alphanumeric-plus-underscore-and-hyphen regex, which rejected "Mantle DNN" for
no reason a filesystem cares about.
"""
function valid_project_name(name::AbstractString)
    isempty(name)                 && return false
    occursin(r"[/\\]", name)      && return false
    startswith(name, ".")         && return false
    return true
end

"""
    project_name_from_path(worker_path) -> String

Default project name for a folder picked on a worker: **the folder's own name**.

ONE derivation for every create path — the worker card's "+ Project", the
dashboard's "New project" (whose Name field is optional) and
`create_project_from_worker!`'s `name` default. They used to disagree, and the
dashboard form had no derivation at all: leaving Name blank produced
"Project name must not be empty (folder has no basename?)" for a folder that
was right there in the breadcrumb.

The name is NOT scrubbed to an alphanumeric whitelist. It only has to satisfy
`valid_project_name` — the containment invariant that keeps it ONE path
component — because that is the only thing the server can know without a
filesystem. Whether "Mantle DNN" or "π-solver" is a usable directory is the
FILESYSTEM's call, and it gets to make it when `ensure_project_session!` runs
`mkpath` on the mirror: a real errno beats a guess, and a name the disk accepts
is one we had no business rewriting.

The path is a FOREIGN path (the worker may run another OS), so the last
forward-slash segment is taken directly rather than trusting the server's
`basename`. A bare drive root (`C:/`) has no folder name to take.
"""
function project_name_from_path(worker_path::AbstractString)
    trimmed = rstrip(normalize_worker_path(worker_path), '/')
    segs    = split(trimmed, '/'; keepempty = false)
    name    = isempty(segs) ? "" : String(last(segs))
    # "C:" left alone by the rstrip above is a drive root, not a folder.
    length(segs) == 1 && occursin(r"^[A-Za-z]:$", name) && (name = "")
    # A leading dot would make the mirror a hidden directory, and covers "."/"..".
    # `String` because `lstrip` hands back a SubString and the `name::String`
    # kwarg of `create_project_from_worker!` refuses one (a TypeError the user
    # sees as "Failed to import: expected String, got SubString").
    name = String(lstrip(name, '.'))
    return valid_project_name(name) ? name : "project"
end

# Folder picker component
#
# There is only ONE picker, and it browses the WORKER. The server-side
# `FolderPicker` that used to live here (`readdir`/`isdir` on the server's own
# filesystem) is gone: it made the create form offer folders that exist on the
# server box and nowhere else, which is how server paths leaked into a
# worker-only flow. Every folder shown below comes from a `list_dir` RPC.
#
# Remote folder picker — reads the worker's filesystem over its control WS via
# `list_worker_dir`. Async: the WS round-trip would otherwise block Bonito's map
# during render and freeze the UI for hundreds of ms per browse click.
const PickerEntry = NamedTuple{(:name, :dir), Tuple{String, Bool}}

mutable struct RemoteFolderPicker
    state::ServerState
    worker_name::String
    # The picked path — the ONE source of truth. A plain editable text field
    # always shows this; every browse action (up, breadcrumb, tree row) just
    # writes a new value into it, and Create/submit reads it directly. There is
    # no second "committed vs typed" path to reconcile, because the field IS the
    # selection. A path that ends in a not-yet-existing segment means "create it
    # on submit" (see `existence`).
    path::Observable{String}
    # Book-kept result of a lazy, debounced `stat_path` on `path`, driving the
    # cosmetic "this folder doesn't exist yet — will be created" affordance.
    # It never influences what Create does (Create always asks the WORKER).
    #   :checking — stat in flight (never shown)
    #   :dir      — exists and is a directory (the normal case)
    #   :missing  — doesn't exist; submitting will create it
    #   :file     — exists as a plain file; a project can't start here
    #   :error    — the stat RPC failed; fall back to neutral styling
    existence::Observable{Symbol}
    entries::Observable{Vector{PickerEntry}}
    loading::Observable{Bool}
    err::Observable{String}
    fetch_id::Ref{Int}                 # increments per task; older replies bail
    workers_dir::Observable{String}    # real abspath of the dir being listed
    listeners_set_up::Ref{Bool}        # idempotency for setup_listeners!
end

RemoteFolderPicker(state::ServerState, worker_name::String, start::String = "") =
    RemoteFolderPicker(
        state, worker_name, Observable(start),
        Observable(:checking),
        Observable(PickerEntry[]), Observable(false), Observable(""),
        Ref(0), Observable(""), Ref(false))

"""
    picker_path(p::RemoteFolderPicker) -> String

The path the picker is pointing at — simply the text field's current value.
Create/submit reads this and asks the WORKER to resolve it (existing folder, or
created via mkpath).
"""
function picker_path(p::RemoteFolderPicker)
    return String(strip(p.path[]))
end

# Reset the picker to a new worker / starting dir. `worker_name` is the worker
# whose control WS answers the list/stat/ensure RPCs (the per-worker card fixes
# it once; the old dashboard form that switched workers is gone).
function reset_to_worker!(p::RemoteFolderPicker, worker_name::String, new_root::String)
    p.worker_name  = worker_name
    p.entries[]    = PickerEntry[]
    p.loading[]    = false
    p.err[]        = ""
    p.existence[]  = :checking
    p.path[]       = new_root   # triggers the debounced fetch/existence task
end

# One lazy, debounced task that refreshes BOTH the existence stamp and the
# listing for the current `path`. A stat + list are each a WS round-trip, so
# they only fire once the path has stopped changing for `debounce_ms`. The
# listed directory is:
#   - `path` itself when it resolves to an existing directory, or
#   - the nearest existing PARENT (dirname) otherwise — so typing a new child
#     (`/a/b/newfolder`) still shows the siblings it will live beside.
# `check_id` is a ticket: a newer path-change supersedes the in-flight stat/list,
# so we never apply a stale answer to a field that has moved on.
function refresh_picker!(p::RemoteFolderPicker; debounce_ms::Int = 300)
    p.fetch_id[] += 1
    my_id  = p.fetch_id[]
    path   = String(strip(p.path[]))
    (isempty(path) || isempty(p.worker_name)) && return
    Timer(debounce_ms / 1000) do _
        my_id == p.fetch_id[] || return
        path = String(strip(p.path[]))
        (isempty(path) || isempty(p.worker_name)) && return
        # ---- existence (drives cosmetic styling only) ----
        local ex::Symbol = :checking
        try
            st = stat_worker_path(p.state, p.worker_name, path)
            ex = st.exists ? (st.isdir ? :dir : :file) : :missing
        catch
            ex = :error
        end
        my_id == p.fetch_id[] || return
        p.existence[] = ex
        # ---- listing (the folder whose children to show) ----
        list_dir = isempty(path) ? "" : (ex === :dir ? path : dirname(rstrip(path, '/')))
        p.loading[] = true
        p.err[]     = ""
        try
            resp = list_worker_dir(p.state, p.worker_name, list_dir)
            my_id == p.fetch_id[] || return
            # The worker resolves "" to $HOME; reflect the real dir we listed.
            p.workers_dir[] = resp.path
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
    on(session, p.path) do _
        refresh_picker!(p)
    end
    return
end

function remote_folder_picker_render(session::Bonito.Session, p::RemoteFolderPicker)
    setup_remote_picker_listeners!(session, p)

    up_btn     = Bonito.Button("↑"; style=nothing, class = "bt-btn bt-btn-secondary",
                               title = "Up one level")
    on(session, up_btn.value) do clicked
        clicked || return
        cur = picker_path(p)
        isempty(cur) && return
        parent = js_path(dirname(rstrip(cur, '/')))
        !isempty(parent) && parent != cur && (p.path[] = parent)
    end

    # The path IS the selection. One editable text field; its value is what
    # Create/submit reads. Browsing (the tree below, the ↑ button) only ever
    # writes new values into it.
    path_field = DOM.input(
        type = "text",
        value = p.path,
        class = "bt-picker-path",
        placeholder = "path/to/your-project  ·  type a name that doesn't exist to create it",
        oninput = js"event => $(p.path).notify(event.target.value)",
        onkeydown = js"""event => { if (event.key === 'Enter') event.target.blur(); }""")

    # Cosmetic only: tells the user whether the current path exists (and will be
    # opened) or doesn't (and will be created). Driven by the debounced stat in
    # `refresh_picker!`; never trusted by Create, which always asks the worker.
    existence_note = map(p.existence) do ex
        if ex === :missing
            DOM.span("doesn't exist yet — will be created";
                     class = "bt-picker-exist bt-picker-exist-missing")
        elseif ex === :file
            DOM.span("that's a file, not a folder";
                     class = "bt-picker-exist bt-picker-exist-file")
        elseif ex === :checking || ex === :error
            DOM.span(""; class = "bt-picker-exist")
        else
            DOM.span(""; class = "bt-picker-exist")
        end
    end

    path_row = DOM.div(
        DOM.div(
            DOM.div(path_field; class = "bt-picker-path-hold"),
            existence_note;
            class = "bt-picker-field"),
        up_btn;
        class = "bt-picker-cur")

    list = map(p.loading, p.entries, p.err, p.workers_dir) do loading, entries, err, wdir
        if loading && isempty(entries)
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
            [DOM.div("(empty folder)";
                class = "bt-picker-row", style = Styles("color" => "var(--bt-text-faint)"))] :
            [DOM.div("📁 $(e.name)";
                class   = "bt-picker-row",
                onclick = js"event => $(p.path).notify($(js_path(joinpath(wdir, e.name))));")
             for e in entries]
        DOM.div(rows...; class = "bt-picker bt-slide-in")
    end

    DOM.div(path_row, list)
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

# There is no per-project dashboard card any more: projects live in the worker
# pills and the sidebar, and a chat's title is edited in its header
# (`chat_title_input`, chat_title.jl) over the one `ProjectInfo.title`.

"""
    dashboard_dom(session, state; current_view = nothing) → DOM

Build the dashboard's DOM block. When `current_view` is provided (the
unified app's view-selector observable), the project-creation flows
auto-navigate to the new project's chat by setting it; otherwise creation
just leaves the user on the dashboard.
"""
function dashboard_dom(session::Bonito.Session, state::ServerState;
                        current_view::Union{Observable{String},Nothing} = nothing,
                        progress::Union{Observable,Nothing} = nothing)
    error_obs = Observable("")

    # Workers self-register over WS — no manual "Add worker" form.

    # Where this dashboard's long-running work (sync, project import, GitHub
    # clone) reports. In the app this is the WINDOW's one progress card
    # (`pane.progress`, passed in by `unified_main`), so a sync started from the
    # dashboard stays readable after the user switches to a chat. A standalone
    # `dashboard_app` has no window, so it owns the observable and mounts its
    # own `progress_overlay`. Either way there is exactly one card. See
    # progress.jl.
    busy = progress === nothing ? Observable{Any}(BUSY_IDLE) : progress

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
                busy_done!(busy, "Synced $(p.name)")
            catch e
                # The failure REPLACES the progress card rather than clearing it
                # and writing somewhere else: what failed belongs where the user
                # was already watching, and it stays there (with its full text,
                # selectable and copyable) until they dismiss it.
                bt = catch_backtrace()
                @warn "sync_project_to_server! failed" project=p.name exception=(e, bt)
                busy_fail!(busy, "Failed to sync $(p.name)", error_detail(e, bt))
            end
        end
    end

    # `picker_state` holds the worker_id whose picker form is currently
    # visible (""  → none). The folder-picker instances themselves live on
    # each WorkerCard (stable across re-renders because the card is stable).
    picker_state = Observable("")
    # Same pattern for the per-worker "From GitHub" form.
    gh_state = Observable("")

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
                        resume_session_id::Union{Nothing,String} = nothing,
                        provider::Union{Nothing,String} = nothing)
        # In-flight guard (T16): a double-click (or two import affordances firing
        # at once) had no guard here and would run two concurrent imports of the
        # same folder. Bail synchronously if a long-op is already running; the
        # synchronous `busy_start!` just below then latches this one.
        refuse_if_busy(busy, error_obs, "Can't create a chat right now") && return nothing
        # Label for the busy card only — `busy_start!` has to run SYNCHRONOUSLY
        # (it is the double-click latch), and the authoritative name can't be
        # derived until the worker has confirmed the path below.
        proj_name = name !== nothing ? name : project_name_from_path(path)
        title = resume_session_id === nothing ?
            "Importing $(proj_name)" :
            "Resuming $(proj_name) (session $(resume_session_id[1:8])…)"
        busy_start!(busy, title)
        @async begin
            try
                @info "do_import: starting" worker=w_name path resume=resume_session_id
                # Ask the WORKER's filesystem whether this folder is really there
                # and take ITS abspath. The picker's rows come from a `list_dir`
                # the worker answered, but the address bar is free text and a
                # discovered session's cwd can have been renamed since the scan.
                real  = worker_dir_or_error(state, w_name, path)
                pname = name !== nothing ? name : project_name_from_path(real)
                # `start_session=false` so the registration finishes fast and we
                # can flip `current_view` early — the chat bring-up itself
                # (ensure_project_session!) is then driven by
                # `project_loading_view`, which shows a full-panel spinner while
                # it runs. Otherwise the user stares at the dashboard for ~10s
                # of ACP `session/load` with only a tiny pill at the top.
                p = create_project_from_worker!(state, w_name, real;
                    name = pname,
                    resume_session_id = resume_session_id,
                    provider = provider,
                    start_session = false,
                    progress = (stage, info) -> busy_event!(busy, stage, info))
                @info "do_import: registered project, flipping view" id=p.id
                error_obs[]      = ""
                discover_state[] = ""
                picker_state[]   = ""
                busy_done!(busy, "Imported $(p.name)")
                current_view !== nothing && (current_view[] = p.id)
            catch e
                # Never swallow silently: surface to the UI AND the server log.
                bt = catch_backtrace()
                @warn "do_import failed" worker=w_name path resume=resume_session_id exception=(e, bt)
                busy_fail!(busy, "Failed to import", error_detail(e, bt))
            end
        end
    end

    # The session-pick handler (payload parse + busy-idle guard + do_import) now
    # lives next to its SESSION-LOCAL `pick` observable in `render_discover_panel`
    # (worker_widget.jl), bridged to this `do_import` — so the observable is
    # registered in the same session that renders the panel.

    # Per-worker "From GitHub" clone, bridged to the worker card's GitHub form.
    # Only reachable from a worker card so `worker_name` is always concrete.
    function do_github(w_name::String, url::String)
        refuse_if_busy(busy, error_obs, "Can't clone right now") && return nothing
        busy_start!(busy, "Opening from GitHub")
        @async begin
            try
                p = create_project_from_github!(state, url;
                    worker_name = w_name,
                    progress    = (stage, info) -> busy_event!(busy, stage, info))
                error_obs[] = ""
                gh_state[]  = ""
                busy_done!(busy, "Opened $(p.name) from GitHub")
                current_view !== nothing && (current_view[] = p.id)
            catch e
                bt = catch_backtrace()
                @warn "do_github failed" worker=w_name url exception=(e, bt)
                busy_fail!(busy, "Failed to open from GitHub", error_detail(e, bt))
            end
        end
        return nothing
    end

    # The per-worker picker form and discover panel are now rendered inside
    # WorkerCard (see worker_widget.jl) and toggled via class binding —
    # which means each card owns its own RemoteFolderPicker, persistent
    # across re-renders without any dashboard-level dict.

    # ── Stats strip ──────────────────────────────────────────────────────────
    # Stats touch both worker counts and project counts → listen to both.
    stats_strip = map(state.workers, state.projects) do workers, projects
        mine     = [w for w in values(workers) if visible(state, w)]
        online   = count(isopen, mine)
        total    = length(mine)
        n_proj   = count(p -> visible(state, p), values(projects))
        n_active = count(p -> p.locked_by !== nothing && visible(state, p), values(projects))
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
                gh_state         = gh_state,
                discover_state   = discover_state,
                busy             = busy,
                discover_busy    = discover_busy,
                discover_results = discover_results,
                do_import        = do_import,
                do_github        = do_github,
                trigger_scan     = trigger_scan!)
        end
    end
    install_block = worker_install_block(state.auth, session, state)
    # Drive the KeyedList off a derived Observable that yields a stable
    # vector of WorkerCard instances (same widget objects across renders →
    # same hash → no spurious unmount/remount).
    worker_widgets_obs = map(state.workers) do workers
        WorkerCard[get_worker_card(w.worker_id) for w in values(workers) if visible(state, w)]
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
    # worker pills and the sidebar. (`sync_request` above
    # remains defined for a future per-project sync control.)

    # Top-of-page errors, for failures with no form on screen ("Register a
    # worker before creating a project").
    error_block = map(error_obs) do msg
        isempty(msg) ? DOM.div() : DOM.div(msg; class = "bt-error")
    end

    # Everything that configures rather than runs (defaults, agent
    # instructions, accounts) is on the Settings page; this is its door.
    settings_link = current_view === nothing ? nothing :
        DOM.button("Settings";
            class = "bt-btn bt-btn-secondary bt-btn-sm bt-open-settings",
            title = "Defaults, agent instructions, accounts",
            onclick = js"event => $(current_view).notify($(SETTINGS_VIEW))")

    # Layout — DOM only; the App() wrapper + global assets (DashboardStyles,
    # ConnectionIndicator) live in the caller (unified_app or dashboard_app).
    DOM.div(
        DOM.div(
            DOM.div(
                DOM.h1(
                    DOM.img(src = logo_svg(), alt = "", class = "bt-logo",
                            draggable = "false"),
                    "BonitoAgents"),
                settings_link;
                class = "bt-header-top"),
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
        worker_list;

        class = "bt-dash")
end

"""
    settings_dom(session, state; current_view = nothing, progress = nothing) → DOM

The Settings page: chat defaults, copying a project to another worker, Debug
BonitoAgents, the global agent instructions, and the account sections.
`progress` is the window's progress card, as for `dashboard_dom`.
"""
function settings_dom(session::Bonito.Session, state::ServerState;
                      current_view::Union{Observable{String},Nothing} = nothing,
                      progress::Union{Observable,Nothing} = nothing)
    busy = progress === nothing ? Observable{Any}(BUSY_IDLE) : progress
    copy_ui = copy_project_controls(session, state, busy, current_view)
    DOM.div(
        DOM.div(DOM.h1("Settings"); class = "bt-header"),
        # Loose controls, one card of uniform rows.
        DOM.div(DOM.h2("General"); class = "bt-section"),
        DOM.div(
            settings_row("Defaults",
                "Applied to new and unconfigured chats; a chat's own picks override.",
                session_defaults_bar(session, state)),
            # New project & GitHub clone live on the per-worker cards; Copy is
            # here because it crosses workers.
            settings_row("Copy project",
                "Snapshot a project's files onto another worker as a new project. " *
                "To carry on a chat elsewhere, use that chat's ⋯ menu → Continue on.",
                copy_ui.button),
            debug_section(session, state, current_view);
            class = "bt-card bt-settings"),
        agents_md_section(session, state),
        shares_section(session, state),
        # Your account behind the proxy; accounts, invites and agent adapter
        # versions for admins.
        account_sections(session, state),
        copy_ui.modal;
        class = "bt-dash bt-settings-page")
end

"""
    copy_project_controls(session, state, busy, current_view) -> (; button, modal)

"Copy project…" and the form it opens: a snapshot of a project's files onto
another worker as a new project. The copy reports into `busy`, and navigates to
the new project when `current_view` is given.
"""
function copy_project_controls(session::Bonito.Session, state::ServerState, busy::Observable,
                               current_view::Union{Observable{String},Nothing})
    error_obs  = Observable("")
    is_open    = Observable(false)
    src_worker = Observable("")
    src_project = Observable("")
    tgt_worker = Observable("")
    new_name   = Observable("")

    # When source worker changes, auto-select the first project on that worker.
    on(session, src_worker) do wid
        isempty(wid) && return
        wid_projs = sort([p for p in values(state.projects[]) if p.worker_id == wid && visible(state, p)];
                         by = p -> p.name)
        src_project[] = isempty(wid_projs) ? "" : first(wid_projs).id
    end
    # Seed the copy name from the source's OWN name. No scrub: `copy_to!`
    # applies `valid_project_name` like every other create path, so a project
    # called "Mantle DNN" seeds "Mantle DNN-copy".
    on(session, src_project) do pid
        isempty(pid) && return
        p = get(state.projects[], pid, nothing)
        p === nothing && return
        new_name[] = p.name * "-copy"
    end
    # Closing the form (✕, backdrop, Escape, Cancel, a finished copy) drops
    # its error with it.
    on(session, is_open) do open
        open || (error_obs[] = "")
    end

    submit = Bonito.Button("Copy"; style = nothing, class = "bt-btn")
    cancel = Bonito.Button("Cancel"; style = nothing, class = "bt-btn bt-btn-secondary")
    on(session, submit.value) do clicked
        clicked || return
        refuse_if_busy(busy, error_obs, "Can't copy right now") && return
        pid = String(src_project[])
        tgt = String(tgt_worker[])
        nm  = String(strip(new_name[]))
        isempty(pid) && (error_obs[] = "Select a source project."; return)
        isempty(tgt) && (error_obs[] = "Select a target worker."; return)
        isempty(nm)  && (error_obs[] = "Enter a name for the copy."; return)
        haskey(state.projects[], pid) ||
            (error_obs[] = "Source project not found."; return)
        haskey(state.workers[], tgt) ||
            (error_obs[] = "Target worker not found."; return)
        p     = state.projects[][pid]
        tgt_w = state.workers[][tgt]
        busy_start!(busy, "Copying $(p.name) → $(tgt_w.name)")
        @async begin
            try
                new_p = copy_to!(state, p, tgt; name = nm,
                    progress = (stage, info) -> busy_event!(busy, stage, info))
                is_open[] = false
                busy_done!(busy, "Copied $(p.name) → $(tgt_w.name)")
                current_view !== nothing && (current_view[] = new_p.id)
            catch e
                bt = catch_backtrace()
                @warn "copy_to! failed" project=p.name target=tgt exception=(e, bt)
                busy_fail!(busy, "Copy failed", error_detail(e, bt))
            end
        end
    end
    on(session, cancel.value) do clicked
        clicked || return
        is_busy_running(busy[]) && return
        is_open[] = false
    end

    button = Bonito.Button("Copy project…"; style = nothing, class = "bt-btn bt-btn-secondary")
    on(session, button.value) do clicked
        clicked || return
        mine = [w.worker_id for w in values(state.workers[]) if visible(state, w)]
        workers_with_projs = unique(p.worker_id for p in values(state.projects[]) if visible(state, p))
        if isempty(mine) || isempty(workers_with_projs)
            error_obs[] = isempty(mine) ?
                "Register a worker before copying projects." :
                "No projects to copy yet."
            return
        end
        # Prefer a source worker that actually has projects.
        src_wid = first(workers_with_projs)
        # Default target to a DIFFERENT worker than source when one exists.
        other_wids = [w for w in mine if w != src_wid]
        tgt_wid = isempty(other_wids) ? src_wid : first(other_wids)
        src_worker[] = ""          # force on(src_worker) to fire even if same value
        src_worker[] = src_wid
        tgt_worker[] = tgt_wid
        error_obs[]  = ""
        is_open[]    = true
    end

    # `class` is the stable hook the e2e suite queries by, not the placeholder.
    worker_select(id_obs::Observable, cls::String) = DOM.select(
        (DOM.option(w.name; value = w.worker_id,
                    selected = w.worker_id == id_obs[]) for w in values(state.workers[]) if visible(state, w))...;
        class = cls,
        value = id_obs,
        onchange = js"event => $(id_obs).notify(event.target.value)")
    # A refusal shows where it was asked for: next to the button while the
    # form is closed, in the form once it is open. Each call builds its own
    # node — the same mapped node can't be mounted in two places.
    shown_error(when_open::Bool) = map(error_obs, is_open) do msg, open
        (isempty(msg) || open != when_open) ? DOM.div() : DOM.div(msg; class = "bt-error")
    end

    form = modal(session, is_open, "Copy project") do
        DOM.div(
            DOM.label("Source worker"),
            worker_select(src_worker, "bt-cp-src-worker"),
            DOM.label("Source project"),
            map(session, state.projects, src_worker) do projects, wid
                wid_projs = sort([p for p in values(projects) if p.worker_id == wid && visible(state, p)];
                                 by = p -> lowercase(p.title[]))
                isempty(wid_projs) ?
                    DOM.div("No projects on this worker"; class = "bt-form-note") :
                    DOM.select(
                        # Listed by the name the user knows the chat by (its title,
                        # or the folder when it has none), with the folder alongside
                        # when the two differ.
                        (DOM.option(titled(p) ? "$(p.title[]) ($(p.name))" : p.name;
                                    value = p.id,
                                    selected = p.id == src_project[]) for p in wid_projs)...;
                        class = "bt-cp-src-project",
                        value = src_project,
                        onchange = js"event => $(src_project).notify(event.target.value)")
            end,
            DOM.label("Target worker"),
            worker_select(tgt_worker, "bt-cp-tgt-worker"),
            DOM.label("Name on target"),
            DOM.input(type = "text", placeholder = "e.g. my-project-copy", value = new_name,
                      oninput = js"event => $(new_name).notify(event.target.value)"),
            DOM.div("It becomes a folder on the target worker: no / or \\, no leading dot.";
                    class = "bt-form-note"),
            shown_error(true),
            DOM.div(cancel, submit; class = "bt-form-actions"),
            class = "bt-form")
    end
    return (; button = DOM.div(button, shown_error(false); class = "bt-copy-project"), modal = form)
end

"""
    agents_md_section(session, state)

The global agent instructions (AGENTS.md): a system-prompt appendix every agent
session gets, on every worker (state_dir/AGENTS.md; see `system_prompt_meta`).
Read at session bring-up, so a save applies to the NEXT chat opened.
"""
function agents_md_section(session::Bonito.Session, state::ServerState)
    status = Observable("")
    saved  = Observable{Union{Nothing,String}}(nothing)
    on(session, saved) do txt
        txt === nothing && return
        try
            set_global_agents_md!(state, txt)
            safe_set!(status, "saved · applies to chats opened from now on")
        catch e
            @warn "AGENTS.md save failed" exception = e
            safe_set!(status, "save failed: $(sprint(showerror, e))")
        end
    end
    return DOM.div(
        DOM.div(DOM.h2("Agent instructions"); class = "bt-section"),
        DOM.div(
            DOM.div("AGENTS.md, appended to the system prompt of every agent session " *
                    "on every worker: shared conventions, house rules, tool guidance.";
                    class = "bt-agents-hint"),
            DOM.textarea(global_agents_md(state);
                class = "bt-agents-textarea", rows = 6,
                placeholder = "e.g. ## Conventions every agent must follow…"),
            DOM.div(
                DOM.span(status; class = "bt-agents-status"),
                DOM.button("Save";
                    class = "bt-btn bt-btn-sm",
                    onclick = js"""event => {
                        const ta = event.target.closest('.bt-agents-block')
                                       .querySelector('textarea');
                        $(saved).notify(ta.value);
                    }""");
                class = "bt-agents-actions");
            class = "bt-card bt-agents-block"))
end

# One install command with its Copy button. The command is copied from its own
# element, never interpolated into the script: a credential command carries
# quotes, which a JS string literal would break on.
install_command_row(label::AbstractString, cmd::AbstractString) = DOM.div(
    DOM.div(label; class = "bt-install-os"),
    DOM.div(
        DOM.code(cmd),
        DOM.span("Copy";
            class   = "bt-install-copy",
            onclick = js"""event => {
                const btn = event.target;
                const say = t => { btn.textContent = t; setTimeout(() => btn.textContent = 'Copy', 1200); };
                ($(COPY_TEXT_JS))(btn.parentNode.querySelector('code').textContent)
                    .then(() => say('Copied'), () => say('Copy failed'));
            }"""),
        class = "bt-install-cmd"))

# The "add a worker" block of the Workers section. On one machine's server only
# this machine reaches it, so the plain install one-liner is the whole story; on
# a network or behind the proxy each worker needs a credential first
# (`worker_install_block(::Union{ProxyAuth,NetworkAuth}, …)` in accounts.jl).
function worker_install_block(::LocalAuth, session::Bonito.Session, state::ServerState)
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
        install_command_row("Linux / macOS", install_unix),
        install_command_row("Windows (PowerShell)", install_win);
        class = "bt-install-block")
    install_summary = DOM.summary(
        DOM.span("Add another worker"; class = "bt-discover-title");
        class = "bt-discover-header")
    return isempty(state.workers[]) ?
        DOM.details(install_summary, install_body; class = "bt-card bt-install-details", open = true) :
        DOM.details(install_summary, install_body; class = "bt-card bt-install-details")
end

# One row of the Settings card: what it is (and why) on the left, the control
# on the right. Rows wrap onto two lines when the pane is narrow.
function settings_row(title::AbstractString, hint::AbstractString, control)
    # The explanation rides on the row's tooltip rather than under the title:
    # these are three or four lines each, and printed in full they turned a card
    # of three controls into a wall of prose. The dotted title says there is
    # more to read; hovering the row shows it.
    DOM.div(
        DOM.div(DOM.span(title; class = "bt-settings-title"); class = "bt-settings-text"),
        DOM.div(control; class = "bt-settings-control");
        class = "bt-settings-row", title = hint)
end

# ── "Debug BonitoAgents" ────────────────────────────────────────────────────
# Opens a chat on a BonitoAgents source checkout on a worker the user picks, with
# the `bt_dev_*` introspection tools attached (dev_api.jl). The last row of the
# dashboard's Settings card: it's a power tool, not part of the normal flow, but
# it should be ONE click away when something is wrong.
#
# The WORKER provides the checkout — the one it runs from, or a `dev --local`
# clone into its environment (see `ensure_debug_project!`) — so nothing on the
# server has to be a checkout, and the section is offered whenever a worker is
# connected. Which worker matters: it is where the agent runs, edits, and what a
# restart afterwards loads.
function debug_section(session::Bonito.Session, state::ServerState,
                       current_view::Union{Observable{String},Nothing})
    # Its tools read and drive the whole server: admins only.
    (current_view === nothing || !is_admin(state)) && return nothing
    chosen = Observable("")
    status = Observable("")
    # The picker follows the worker list: a worker that goes away is dropped and
    # the choice falls back to the first connected one, so the button never
    # targets a machine that isn't there.
    picker = map(session, state.workers) do workers
        online = sort([w for w in values(workers) if isopen(w)]; by = w -> w.name)
        ids = [w.worker_id for w in online]
        chosen[] in ids || (chosen[] = isempty(ids) ? "" : first(ids))
        isempty(online) &&
            return DOM.span("no worker connected"; class = "bt-debug-noworker")
        return DOM.select(
            (DOM.option(w.name; value = w.worker_id, selected = w.worker_id == chosen[])
             for w in online)...;
            class = "bt-debug-worker",
            title = "The worker the debug chat runs on; its checkout is what the agent edits",
            onchange = js"event => $(chosen).notify(event.target.value)")
    end
    btn = DOM.button(map(s -> isempty(s) ? "Debug BonitoAgents" : s, status);
        class = "bt-btn bt-btn-secondary bt-debug-btn",
        title = "Open a chat on the BonitoAgents source, checked out on the chosen " *
                "worker, with live introspection into this server",
        onclick = js"event => $(status).notify('__click__')")
    on(session, status) do s
        s == "__click__" || return
        wid = chosen[]
        status[] = "Preparing the checkout… (a first run clones and precompiles)"
        Base.errormonitor(@async try
            open_debug_chat!(state, current_view; worker_id = wid)
            safe_set!(status, "")
        catch e
            @warn "opening the debug chat failed" worker_id = wid exception = (e, catch_backtrace())
            safe_set!(status, first(split(sprint(showerror, e), '\n')))
        end)
    end
    return settings_row("Debug BonitoAgents",
        "Opens a chat on the BonitoAgents source, checked out on the worker you pick " *
        "(dev --local into its environment, at this server's revision), with tools that " *
        "read this server's live state: workers, chats, eval bridges, logs and memory. " *
        "Restart that worker to run what was edited there.",
        DOM.div(picker, btn; class = "bt-debug-row"))
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
        # No window shell here, so this mount owns the one progress card.
        progress = Observable{Any}(BUSY_IDLE)
        DOM.div(
            DashboardStyles,
            connection_guard(session),
            progress_overlay(session, progress),
            dashboard_dom(session, view; progress = progress))
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
