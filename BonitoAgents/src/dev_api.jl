# ── Inspection API: what the running server can tell you about itself ───────
# Backs the "Debug BonitoAgents" chat. That chat's cwd is the BonitoAgents
# CHECKOUT, so its agent can already read the source, edit it and run git —
# everything a normal coding session does. What it can't get from the filesystem
# is the state of the LIVE process: which chats are bound, what the eval bridges
# are holding, whether a registry has been growing for the last hour. That's what
# this file exposes.
#
# The path in is the MCP control channel the chat's BonitoMCP already holds: its
# `bt_dev_*` tools send `{type:"dev_request", dev_id, op, args}` and we answer
# with `{op:"dev_reply", dev_id, ok, result|error}`. Everything returned must be
# JSON-encodable, so each reporter hand-builds plain Dicts/Vectors rather than
# handing back live objects.
#
# Ops dispatch on `Val{:name}` — adding one is a method, not another `elseif`.

# The logging interface lives in Base (`Base.CoreLogging`); the `Logging` stdlib
# is just a re-export plus ConsoleLogger. Using Base directly keeps this from
# adding a dependency for four method definitions.
const CoreLogging = Base.CoreLogging

# ── log ring ────────────────────────────────────────────────────────────────
# The server's own `@info`/`@warn`/`@error` records, kept in memory so a debug
# chat can read them without an on-disk log file or a systemd journal.
#
# This is genuinely PROCESS-global state — `global_logger()` is — so it lives in
# one const rather than on `ServerState`: two servers in one process (the test
# suite does exactly that) share a logger, and pretending otherwise would give
# each of them a ring that only ever sees half the records.

struct LogRecord
    time  :: Float64            # unix seconds
    level :: String
    msg   :: String
    mod   :: String
    file  :: String
    line  :: Int
    kv    :: Dict{String,String}
end

mutable struct LogRing
    lock      :: ReentrantLock
    records   :: Vector{LogRecord}
    capacity  :: Int
    dropped   :: Int            # records evicted since boot (the ring is bounded)
    installed :: Bool
end

const LOG_RING = LogRing(ReentrantLock(), LogRecord[], 4000, 0, false)

# A logged key's value as text. `show` on a user value can itself throw (a bad
# `show` method, a broken iterator); if it does we keep the record and say so in
# the field, rather than losing the whole log line — a logger that throws inside
# logging takes the process down with it.
function log_value_string(v)
    try
        s = sprint(show, v; context = :limit => true)
        return length(s) > 400 ? first(s, 400) * "…" : s
    catch e
        e isa InterruptException && rethrow()
        return "<unprintable: $(typeof(e))>"
    end
end

# Strings are already their own text. Going through `show` would wrap every log
# message and every string-valued key in escaped quotes, which is noise in a
# reader whose whole job is being read.
log_value_string(v::AbstractString) =
    length(v) > 400 ? first(String(v), 400) * "…" : String(v)

function push_log_record!(ring::LogRing, level, message, _module, file, line, kwargs)
    rec = LogRecord(time(), string(level), log_value_string(message),
                    string(_module), string(something(file, "")),
                    line isa Integer ? Int(line) : 0,
                    Dict{String,String}(string(k) => log_value_string(v) for (k, v) in kwargs))
    lock(ring.lock) do
        push!(ring.records, rec)
        while length(ring.records) > ring.capacity
            popfirst!(ring.records)
            ring.dropped += 1
        end
    end
    return nothing
end

"""
    RingLogger(ring, inner)

Tees `Info`-and-above log records into `ring` and forwards EVERYTHING to `inner`
unchanged. Wrapping rather than replacing matters: the test harness, the systemd
journal and the dev console all read the inner logger, and a logger that quietly
swallowed records would make the debug chat the only place errors show up.
"""
struct RingLogger <: CoreLogging.AbstractLogger
    ring  :: LogRing
    inner :: CoreLogging.AbstractLogger
end

# Take whatever the inner logger takes, plus Info+ for the ring — so a server
# configured to only print warnings still records its info lines here.
CoreLogging.min_enabled_level(l::RingLogger) =
    min(CoreLogging.min_enabled_level(l.inner), CoreLogging.Info)
CoreLogging.shouldlog(l::RingLogger, level, _module, group, id) =
    level >= CoreLogging.Info || CoreLogging.shouldlog(l.inner, level, _module, group, id)
CoreLogging.catch_exceptions(l::RingLogger) = CoreLogging.catch_exceptions(l.inner)

function CoreLogging.handle_message(l::RingLogger, level, message, _module, group, id,
                                file, line; kwargs...)
    level >= CoreLogging.Info && push_log_record!(l.ring, level, message, _module, file, line, kwargs)
    # Forward under the inner logger's OWN filters, so wrapping can't turn a
    # quiet logger loud.
    if CoreLogging.min_enabled_level(l.inner) <= level &&
       CoreLogging.shouldlog(l.inner, level, _module, group, id)
        CoreLogging.handle_message(l.inner, level, message, _module, group, id, file, line; kwargs...)
    end
    return nothing
end

"""
    install_log_ring!()

Start recording the process's log output into [`LOG_RING`](@ref). Idempotent and
safe to call from every `serve()`: the second call is a no-op, so N servers in
one process wrap the logger once between them.
"""
function install_log_ring!()
    lock(LOG_RING.lock) do
        LOG_RING.installed && return nothing
        LOG_RING.installed = true
        CoreLogging.global_logger(RingLogger(LOG_RING, CoreLogging.global_logger()))
        return nothing
    end
end

# ── shared shaping helpers ──────────────────────────────────────────────────

# Julia values that JSON can't render (DateTime, Symbol, ReentrantLock, …) become
# strings here, once, so no reporter has to remember.
jsonable(x::Union{Nothing,Bool,Integer,AbstractFloat,AbstractString}) = x
jsonable(x::Symbol)   = String(x)
jsonable(x::DateTime) = string(x)
jsonable(x::AbstractVector) = [jsonable(v) for v in x]
jsonable(x::AbstractDict) = Dict{String,Any}(string(k) => jsonable(v) for (k, v) in x)
jsonable(x) = string(x)

# ── the ops ─────────────────────────────────────────────────────────────────

# The op / section / control names that exist. Checked BEFORE the name becomes a
# `Val`, for two reasons: an unknown op gets an error that lists the real ones
# instead of a bare "no method", and an arbitrary string from the wire can't mint
# an unbounded number of `Val{Symbol}` types in this process.
const DEV_OPS          = (:inspect, :logs, :memory, :control)
const DEV_SECTIONS     = (:overview, :workers, :worker, :projects, :chats, :evals, :settings)
const DEV_CONTROL_OPS  = (:open_chat, :send_message, :restart_chat, :close_chat,
                          :rescan_worker, :move_project, :set_title)

known_or_throw(name::Symbol, known, what) =
    name in known ? name :
    error("unknown $what '$(name)' — expected one of " * join(known, ", "))

"""
    dev_request(state, op, args) -> Any

Run one dev-tool operation and return a JSON-encodable result. Unknown ops throw
(the MCP side turns that into a tool error naming the op), so a typo can't come
back as an empty success.
"""
dev_request(state::ServerState, op::AbstractString, args::AbstractDict) =
    dev_op(state, Val(known_or_throw(Symbol(op), DEV_OPS, "dev op")), args)

# ── inspect ─────────────────────────────────────────────────────────────────

function dev_op(state::ServerState, ::Val{:inspect}, args::AbstractDict)
    section = known_or_throw(Symbol(String(get(args, "section", "overview"))),
                             DEV_SECTIONS, "section")
    # One narrowing argument, whose meaning is the section's: a project id for
    # the per-chat sections, a worker id for `:worker`.
    target = section === :worker ? String(get(args, "worker_id", "")) :
                                   String(get(args, "project_id", ""))
    return dev_section(state, Val(section), target)
end

# `time()` at the first `serve()`. A Ref, not a const computed at load: the const
# would be baked into the precompile image and report the build machine's clock.
const SERVER_STARTED = Ref(0.0)
server_uptime() = SERVER_STARTED[] == 0.0 ? 0.0 : round(time() - SERVER_STARTED[]; digits = 1)

function dev_section(state::ServerState, ::Val{:overview}, ::String)
    workers, projects = state.workers[], state.projects[]
    chat_ids, bound = lock(state.lock) do
        (collect(keys(state.chat_models)), copy(state.bound_lru))
    end
    return Dict{String,Any}(
        "pid"          => getpid(),
        "julia"        => string(VERSION),
        "threads"      => Threads.nthreads(),
        "uptime_s"     => server_uptime(),
        "boot_id"      => server_boot_id(),
        "base_url"     => state.base_url[],
        "state_dir"    => state.state_dir,
        "working_dir"  => state.working_dir,
        "counts"       => Dict{String,Any}(
            "workers"         => length(workers),
            "workers_online"  => count(isopen, values(workers)),
            "projects"        => length(projects),
            "open_chats"      => count(p -> !p.dismissed, values(projects)),
            "chat_models"     => length(chat_ids),
            "bound_sessions"  => length(bound),
            "eval_bridges"    => lock(() -> length(state.eval_workers), state.lock),
            "mcp_channels"    => lock(() -> length(state.mcp_ctrl), state.lock),
            "pending_rpcs"    => lock(() -> length(state.pending_rpcs), state.lock),
            "pending_chunks"  => lock(() -> length(state.pending_chunks), state.lock),
        ),
        "bound_lru"    => bound,
        "chat_models"  => chat_ids,
    )
end

function dev_section(state::ServerState, ::Val{:workers}, ::String)
    connected = lock(() -> Set(keys(state.worker_control_ws)), state.lock)
    last_scan = lock(() -> copy(state.last_scan), state.lock)
    return [Dict{String,Any}(
        "worker_id"     => w.worker_id,
        "name"          => w.name,
        "initials"      => jsonable(w.initials),
        "online"        => isopen(w),
        "control_ws"    => w.worker_id in connected,
        "hostname"      => w.hostname,
        "home"          => w.home,
        "projects_root" => w.projects_root,
        "url"           => w.url,
        "ssh_target"    => jsonable(w.ssh_target),
        "last_check"    => string(w.last_check),
        "last_scan_age_s" => haskey(last_scan, w.worker_id) ?
            round(time() - last_scan[w.worker_id]; digits = 1) : nothing,
    ) for w in values(state.workers[])]
end

function project_report(p::ProjectInfo)
    idx = p.file_index
    nfiles, loaded = lock(idx.lock) do
        (length(idx.files), idx.loaded_at)
    end
    return Dict{String,Any}(
        "id"                => p.id,
        "name"              => p.name,
        "title"             => jsonable(p.title),
        "worker_id"         => p.worker_id,
        "worker_path"       => p.worker_path,
        "server_path"       => p.server_path,
        "created"           => string(p.created),
        "backup_status"     => String(p.backup_status),
        "last_sync_at"      => jsonable(p.last_sync_at),
        "resume_session_id" => jsonable(p.resume_session_id),
        # Reported next to the resume id because the pair is what you check when
        # a reopened chat comes up on the wrong backend: the id belongs to this
        # agent and to no other.
        "provider"          => jsonable(p.provider),
        "auto_prompt"       => p.auto_prompt === nothing ? nothing : first(p.auto_prompt, 200),
        "dismissed"         => p.dismissed,
        "locked_by"         => jsonable(p.locked_by),
        "desired_config"    => jsonable(p.desired_config),
        "file_index"        => Dict{String,Any}("files" => nfiles,
                                                "loaded_at" => jsonable(loaded)),
    )
end

function dev_section(state::ServerState, ::Val{:projects}, project_id::String)
    projects = state.projects[]
    isempty(project_id) && return [project_report(p) for p in values(projects)]
    p = get(projects, project_id, nothing)
    p === nothing && error("no project '$project_id'")
    return project_report(p)
end

function chat_report(state::ServerState, project_id::AbstractString, m)
    sh = shared(m)
    nmsgs = lock(() -> length(sh.msgs_store), sh.lock)
    return Dict{String,Any}(
        "project_id"     => String(project_id),
        "cwd"            => m.cwd,
        "chat_dir"       => m.chat_dir,
        "messages"       => nmsgs,
        "busy"           => sh.busy_active[],
        "session_alive"  => sh.session_alive[],
        "last_error"     => sh.last_error[],
        "yolo"           => sh.yolo[],
        "provider"       => string(sh.provider[]),
        "turn_in_flight" => sh.turn_in_flight[],
        "turn_seq"       => sh.turn_seq[],
        "taskbar_items"  => length(sh.taskbar.items[]),
        "pending_sends"  => lock(() -> length(sh.pending_sends), sh.lock),
        "pending_asks"   => length(sh.pending_asks),
        "tool_cache"     => length(sh.tool_content_cache),
        "consumer_alive" => sh.consumer_task[] !== nothing && !istaskdone(sh.consumer_task[]),
        "poller_alive"   => sh.poller_task[] !== nothing && !istaskdone(sh.poller_task[]),
        "restart_gen"    => sh.restart_gen[],
    )
end

function dev_section(state::ServerState, ::Val{:chats}, project_id::String)
    models = lock(() -> copy(state.chat_models), state.lock)
    if !isempty(project_id)
        m = get(models, project_id, nothing)
        m === nothing && error("no live chat for project '$project_id'")
        return chat_report(state, project_id, m)
    end
    return [chat_report(state, k, m) for (k, m) in models]
end

function eval_bridge_report(project_id::AbstractString, eb)
    parked_queues, parked_bytes = lock(eb.parked_lock) do
        (Dict{String,Int}(k => length(v) for (k, v) in eb.parked), eb.parked_bytes)
    end
    pages, tabs = lock(eb.pc_lock) do
        (collect(keys(eb.page_conns)), length(eb.tab_prefix))
    end
    return Dict{String,Any}(
        "project_id"     => String(project_id),
        "prefix"         => eb.prefix,
        "connected"      => eb.ws !== nothing,
        "parked_frames"  => parked_queues,
        "parked_bytes"   => parked_bytes,
        "page_roots"     => pages,
        "browser_tabs"   => tabs,
        "pending_ctrl"   => lock(() -> length(eb.pending), eb.pending_lock),
    )
end

function dev_section(state::ServerState, ::Val{:evals}, project_id::String)
    bridges = lock(() -> copy(state.eval_workers), state.lock)
    sinks = lock(() -> collect(keys(state.eval_stream_sinks)), state.lock)
    reports = [eval_bridge_report(k, eb) for (k, eb) in bridges
               if isempty(project_id) || k == project_id]
    return Dict{String,Any}("bridges" => reports, "live_stdout_sinks" => sinks)
end

# The worker's own account of itself, asked live. Separate from `:workers`
# (which is what the SERVER believes about each worker) on purpose: when those
# two disagree — the server thinks a session is bound, the worker's agent process
# has exited — the disagreement IS the bug, and you can only see it if both are
# reported.
function dev_section(state::ServerState, ::Val{:worker}, worker_id::String)
    ids = isempty(worker_id) ? collect(keys(state.workers[])) : [worker_id]
    out = Dict{String,Any}[]
    for wid in ids
        haskey(state.workers[], wid) || error("no worker '$wid'")
        entry = try
            d = worker_state(state, wid)
            d["worker_id"] = wid
            d
        catch e
            e isa InterruptException && rethrow()
            # A worker that can't answer is itself the finding — report it in
            # place instead of failing the whole section.
            Dict{String,Any}("worker_id" => wid, "reachable" => false,
                             "error" => first(split(sprint(showerror, e), '\n')))
        end
        push!(out, entry)
    end
    return isempty(worker_id) ? out : only(out)
end

function dev_section(state::ServerState, ::Val{:settings}, ::String)
    return Dict{String,Any}(
        "default_session_config" => jsonable(state.default_session_config[]),
        "config_options_known"   => length(state.last_config_options[]),
        "heartbeat_interval"     => state.heartbeat_interval,
        "heartbeat_deadline"     => state.heartbeat_deadline,
        "agents_md"              => isfile(agents_md_file(state)) ?
            filesize(agents_md_file(state)) : nothing,
    )
end

# ── logs ────────────────────────────────────────────────────────────────────

const LOG_LEVEL_ORDER = Dict("debug" => 0, "info" => 1, "warn" => 2, "error" => 3)

# Julia prints levels as "Debug"/"Info"/"Warn"/"Error"; anything else (a custom
# LogLevel) sorts as Info so it isn't silently filtered out.
log_level_rank(s::AbstractString) = get(LOG_LEVEL_ORDER, lowercase(s), 1)

function dev_op(state::ServerState, ::Val{:logs}, args::AbstractDict)
    raw_limit = get(args, "limit", 100)
    limit = raw_limit isa Integer ? Int(raw_limit) : 100
    limit = clamp(limit, 1, LOG_RING.capacity)
    minrank = log_level_rank(String(get(args, "level", "info")))
    needle = lowercase(String(get(args, "contains", "")))
    recs, dropped, total = lock(LOG_RING.lock) do
        (copy(LOG_RING.records), LOG_RING.dropped, length(LOG_RING.records))
    end
    matches(r) = log_level_rank(r.level) >= minrank &&
        (isempty(needle) || occursin(needle, lowercase(r.msg)) ||
         any(kv -> occursin(needle, lowercase(kv.first)) || occursin(needle, lowercase(kv.second)),
             r.kv))
    hits = filter(matches, recs)
    shown = length(hits) > limit ? hits[(end - limit + 1):end] : hits
    return Dict{String,Any}(
        "in_ring"        => total,
        "matched"        => length(hits),
        "returned"       => length(shown),
        "evicted_total"  => dropped,
        "capacity"       => LOG_RING.capacity,
        "records"        => [Dict{String,Any}(
            "t"     => round(r.time; digits = 3),
            "ago_s" => round(time() - r.time; digits = 1),
            "level" => r.level,
            "msg"   => r.msg,
            "mod"   => r.mod,
            "at"    => "$(basename(r.file)):$(r.line)",
            "kv"    => r.kv) for r in shown],
    )
end

# ── memory ──────────────────────────────────────────────────────────────────

# Resident set size in bytes. `Sys.maxrss()` is the PEAK, which is the wrong
# number for "is it growing right now" — on Linux read the live value out of
# /proc; elsewhere fall back to the peak and say which one it is.
function process_rss()
    if Sys.islinux() && isfile("/proc/self/statm")
        fields = split(read("/proc/self/statm", String))
        length(fields) >= 2 &&
            return (bytes = parse(Int, fields[2]) * Sys.PAGESIZE, kind = "current")
    end
    return (bytes = Sys.maxrss(), kind = "peak")
end

# Every registry in this codebase that has, at some point, grown without bound.
# Counting them is the cheap first pass of a leak hunt: the one that keeps rising
# across two readings is the one to look at with `deep = true`.
function registry_counts(state::ServerState)
    models = lock(() -> copy(state.chat_models), state.lock)
    bridges = lock(() -> copy(state.eval_workers), state.lock)
    msgs = Dict{String,Int}()
    tool_caches = Dict{String,Int}()
    for (k, m) in models
        sh = shared(m)
        msgs[k] = lock(() -> length(sh.msgs_store), sh.lock)
        tool_caches[k] = length(sh.tool_content_cache)
    end
    parked = sum(eb -> lock(() -> eb.parked_bytes, eb.parked_lock), values(bridges); init = 0)
    return Dict{String,Any}(
        "chat_models"          => length(models),
        "messages_per_chat"    => msgs,
        "messages_total"       => sum(values(msgs); init = 0),
        "tool_cache_per_chat"  => tool_caches,
        "eval_bridges"         => length(bridges),
        "eval_parked_bytes"    => parked,
        "eval_stream_sinks"    => lock(() -> length(state.eval_stream_sinks), state.lock),
        "mcp_channels"         => lock(() -> length(state.mcp_ctrl), state.lock),
        "pending_rpcs"         => lock(() -> length(state.pending_rpcs), state.lock),
        "pending_chunks"       => lock(() -> length(state.pending_chunks), state.lock),
        "worker_control_ws"    => lock(() -> length(state.worker_control_ws), state.lock),
        "session_inflight"     => lock(() -> length(state.session_inflight), state.lock),
        "show_fetch_locks"     => lock(() -> length(state.show_fetch_inflight), state.lock),
        "show_mirror_stamps"   => lock(() -> length(state.show_mirror_stamps), state.lock),
        "bound_lru"            => lock(() -> length(state.bound_lru), state.lock),
        "projects"             => length(state.projects[]),
        "workers"              => length(state.workers[]),
        "log_records"          => lock(() -> length(LOG_RING.records), LOG_RING.lock),
    )
end

# `Base.summarysize` per registry. Real bytes, and genuinely slow — it walks the
# whole object graph, and a chat's message store reaches into rendered DOM and
# ACP content. Opt-in for exactly that reason, and note it holds each chat's own
# lock while measuring it: on a live server that chat stops rendering for the
# duration. Take the reading when you mean to, not on every poll.
function deep_sizes(state::ServerState)
    models = lock(() -> copy(state.chat_models), state.lock)
    per_chat = Dict{String,Int}()
    for (k, m) in models
        sh = shared(m)
        per_chat[k] = lock(() -> Base.summarysize(sh.msgs_store), sh.lock)
    end
    return Dict{String,Any}(
        "msgs_store_per_chat" => per_chat,
        "msgs_store_total"    => sum(values(per_chat); init = 0),
        "projects"            => Base.summarysize(state.projects[]),
        "workers"             => Base.summarysize(state.workers[]),
        "discovered"          => Base.summarysize(state.discovered[]),
        "log_ring"            => lock(() -> Base.summarysize(LOG_RING.records), LOG_RING.lock),
    )
end

function dev_op(state::ServerState, ::Val{:memory}, args::AbstractDict)
    do_gc = get(args, "gc", false) === true
    deep  = get(args, "deep", false) === true
    live_before = Base.gc_live_bytes()
    rss_before = process_rss()
    if do_gc
        GC.gc(true)
        GC.gc(false)      # a second, incremental pass sweeps what the full one freed
    end
    rss_after = process_rss()
    gc = Base.gc_num()
    result = Dict{String,Any}(
        "uptime_s"          => server_uptime(),
        "gc_ran"            => do_gc,
        "live_bytes_before" => live_before,
        "live_bytes_after"  => Base.gc_live_bytes(),
        "rss_bytes"         => rss_after.bytes,
        "rss_kind"          => rss_after.kind,
        "rss_bytes_before"  => rss_before.bytes,
        "total_allocated"   => gc.allocd + gc.total_allocd,
        "gc_collections"    => gc.pause,
        "gc_time_ns"        => gc.total_time,
        "threads"           => Threads.nthreads(),
        "registries"        => registry_counts(state),
    )
    deep && (result["deep_sizes"] = deep_sizes(state))
    return result
end

# ── control ─────────────────────────────────────────────────────────────────
# Operations with real, user-visible effects. Each one resolves its target FIRST
# and errors by name if it can't — an op that silently no-ops when the project id
# is wrong is the worst possible outcome for an agent driving the server blind.

function dev_project(state::ServerState, project_id::AbstractString)
    isempty(project_id) && error("this op needs a `project_id`")
    p = get(state.projects[], project_id, nothing)
    p === nothing && error("no project '$project_id' (list them with bt_dev_inspect section=projects)")
    return p
end

dev_op(state::ServerState, ::Val{:control}, args::AbstractDict) =
    dev_control(state, Val(known_or_throw(Symbol(String(get(args, "op", ""))),
                                          DEV_CONTROL_OPS, "control op")), args)

function dev_control(state::ServerState, ::Val{:open_chat}, args::AbstractDict)
    p = dev_project(state, String(get(args, "project_id", "")))
    ensure_project_session!(state, p)
    return Dict{String,Any}("ok" => true, "project_id" => p.id,
                            "title" => project_display_title(p))
end

function dev_control(state::ServerState, ::Val{:send_message}, args::AbstractDict)
    p = dev_project(state, String(get(args, "project_id", "")))
    text = String(get(args, "text", ""))
    isempty(strip(text)) && error("`text` is empty — nothing to send")
    model = ensure_project_session!(state, p)
    model === nothing && error("could not bring up a chat session for '$(p.id)'")
    send_message!(model, UserMsg(text))
    return Dict{String,Any}("ok" => true, "project_id" => p.id, "sent_chars" => length(text))
end

function dev_control(state::ServerState, ::Val{:restart_chat}, args::AbstractDict)
    p = dev_project(state, String(get(args, "project_id", "")))
    model = lock(() -> get(state.chat_models, p.id, nothing), state.lock)
    model === nothing && error("project '$(p.id)' has no live chat to restart")
    restart_chat_session!(model)
    return Dict{String,Any}("ok" => true, "project_id" => p.id,
                            "session_alive" => shared(model).session_alive[])
end

function dev_control(state::ServerState, ::Val{:close_chat}, args::AbstractDict)
    p = dev_project(state, String(get(args, "project_id", "")))
    p.dismissed = true
    lock(state.lock) do; save_projects!(state); end
    safe_notify!(state.projects)
    return Dict{String,Any}("ok" => true, "project_id" => p.id, "dismissed" => true)
end

function dev_control(state::ServerState, ::Val{:rescan_worker}, args::AbstractDict)
    wid = String(get(args, "worker_id", ""))
    haskey(state.workers[], wid) || error("no worker '$wid'")
    scan_and_store!(state, wid)
    found = length(get(state.discovered[], wid, []))
    return Dict{String,Any}("ok" => true, "worker_id" => wid, "sessions_found" => found)
end

function dev_control(state::ServerState, ::Val{:set_title}, args::AbstractDict)
    p = dev_project(state, String(get(args, "project_id", "")))
    set_project_title!(state, p.id, String(get(args, "title", "")))
    return Dict{String,Any}("ok" => true, "project_id" => p.id,
                            "title" => project_display_title(state.projects[][p.id]))
end

# Move a project's FILES to another worker. Reuses the same `sync_across_workers!`
# the UI's ⇄ button runs, so there is one implementation of "copy a project
# between machines" and this can't drift from it. The destination project is the
# same-named sibling on `worker_id`; if there isn't one yet we create it, which is
# what makes this a MOVE rather than a sync between two things that both exist.
function dev_control(state::ServerState, ::Val{:move_project}, args::AbstractDict)
    src = dev_project(state, String(get(args, "project_id", "")))
    dst_worker = String(get(args, "worker_id", ""))
    haskey(state.workers[], dst_worker) || error("no worker '$dst_worker'")
    src.worker_id == dst_worker &&
        error("project '$(src.id)' is already on worker '$dst_worker'")
    w = state.workers[][dst_worker]
    isopen(w) || error("worker '$dst_worker' is offline — can't copy to it")

    # `worker_join`, not `joinpath`: the root is the DESTINATION WORKER's, which
    # may be a different OS than this server. A server-side separator here also
    # makes the `find_project_by_location` lookup below miss the sibling that
    # already exists (stored paths are normalized), so a re-run would create a
    # duplicate instead of moving into it. Same rule as `transfer_project!`.
    dst_worker_path = worker_join(w.projects_root, src.name)
    dst = find_project_by_location(state, dst_worker, dst_worker_path)
    created = dst === nothing
    if created
        dst = ProjectInfo(string(uuid4())[1:8], src.name, dst_worker,
                          compute_server_path(state, dst_worker, src.name),
                          dst_worker_path, now(UTC))
        dst.title = src.title
        lock(state.lock) do
            state.projects[][dst.id] = dst
            save_projects!(state)
        end
        safe_notify!(state.projects)
    end
    sync_across_workers!(state, src, dst)
    return Dict{String,Any}("ok" => true,
                            "source_project" => src.id, "source_worker" => src.worker_id,
                            "dest_project" => dst.id, "dest_worker" => dst_worker,
                            "dest_path" => dst_worker_path,
                            "created_destination" => created)
end

# ── the "Debug BonitoAgents" chat ───────────────────────────────────────────
# A normal project, pointed at the BonitoAgents source checkout, with `dev_mode`
# set. `dev_mode` is what attaches the `bt_dev_*` tools (via `eval_dialback_env`)
# and the briefing in the system prompt (via `agents_prompt_appendix`); the cwd
# is what lets the agent read, edit and `git` the code. Nothing else is special
# about it — it uses the same bring-up, the same worker, the same everything.

"""
    bonitoagents_repo_root() -> String | nothing

The git repository containing BonitoAgents' source, or `nothing` when this
install isn't a checkout (a bundled app, or a package installed from the
registry). Walks up from `pkgdir` looking for `.git` — which may be a DIRECTORY
(a normal clone) or a FILE (a worktree or a submodule), so both count.

Returning the REPO root rather than the package directory is deliberate: the
sibling packages (BonitoWorker, BonitoMCP, AgentClientProtocol) live next to it
in the same repo, and a bug is as likely to be in one of those.
"""
function bonitoagents_repo_root()
    dir = pkgdir(@__MODULE__)
    dir === nothing && return nothing
    cur = abspath(String(dir))
    while true
        ispath(joinpath(cur, ".git")) && return cur
        parent = dirname(cur)
        parent == cur && return nothing
        cur = parent
    end
end

"""
    debug_project_worker(state, preferred = "") -> worker_id

Which worker the debug chat should run on. The source checkout has to EXIST
there, so this is not just "any online worker": it prefers `preferred` (the
worker of the chat the user clicked from), then any other online worker, and
reports what it tried when none of them has the checkout.
"""
function debug_project_worker(state::ServerState, root::AbstractString,
                              preferred::AbstractString = "")
    candidates = String[]
    isempty(preferred) || push!(candidates, String(preferred))
    for (id, w) in state.workers[]
        (id in candidates || !isopen(w)) && continue
        push!(candidates, id)
    end
    isempty(candidates) && error("no worker is connected — a debug chat needs one to run on")
    tried = String[]
    for wid in candidates
        haskey(state.workers[], wid) || continue
        info = try
            stat_worker_path(state, wid, joinpath(root, ".git"))
        catch e
            e isa InterruptException && rethrow()
            push!(tried, "$(wid): $(first(split(sprint(showerror, e), '\n')))")
            continue
        end
        info.exists && return wid
        push!(tried, "$(wid): no $(root)/.git")
    end
    error("none of the connected workers has the BonitoAgents checkout at '$root'.\n" *
          "Checked: " * join(tried, "; ") * ".\n" *
          "Clone the repo there (or run the server from a checkout) to debug it.")
end

"""
    ensure_debug_project!(state; worker_id = "") -> ProjectInfo

Find or create the "Debug BonitoAgents" project and return it, ready to open.
Idempotent: a second call reuses the existing one, so the button can be clicked
any number of times and the conversation survives.

Throws — with a message meant for the user — when this install has no source
checkout, or when no connected worker has it. That's the honest outcome: without
the source there's nothing to debug WITH, and inventing a chat that can only
read the server's memory would be a worse experience than saying so.
"""
function ensure_debug_project!(state::ServerState; worker_id::AbstractString = "")
    root = bonitoagents_repo_root()
    root === nothing && error(
        "this BonitoAgents install isn't a git checkout, so there's no source to " *
        "debug against. Run the server from a clone of the repository (or `Pkg.develop` it) " *
        "and the debug chat becomes available.")
    wid = debug_project_worker(state, root, worker_id)

    existing = find_project_by_location(state, wid, root)
    if existing !== nothing
        # An ordinary chat already sitting on the checkout is PROMOTED here —
        # this is the one path that may grant `dev_mode`, and it's the user
        # clicking the button that does it.
        changed = !existing.dev_mode || existing.dismissed || existing.title === nothing
        existing.dev_mode = true
        existing.dismissed = false
        existing.title === nothing && (existing.title = DEBUG_PROJECT_TITLE)
        if changed
            lock(state.lock) do; save_projects!(state); end
            safe_notify!(state.projects)
        end
        return existing
    end

    p = ProjectInfo(string(uuid4())[1:8], basename(root), wid,
                    compute_server_path(state, wid, basename(root)), root, now(UTC))
    p.dev_mode = true
    p.title = DEBUG_PROJECT_TITLE
    lock(state.lock) do
        state.projects[][p.id] = p
        save_projects!(state)
    end
    safe_notify!(state.projects)
    return p
end

const DEBUG_PROJECT_TITLE = "Debug BonitoAgents"

"""
    open_debug_chat!(state, current_view; worker_id = "")

Create-or-find the debug project, bring its session up, and navigate this window
to it. The navigation is the whole point of the button: the user clicked "debug
this thing", and landing anywhere other than that chat would be a bug.
"""
function open_debug_chat!(state::ServerState, current_view::Observable{String};
                          worker_id::AbstractString = "")
    p = ensure_debug_project!(state; worker_id)
    ensure_project_session!(state, p)
    current_view[] = p.id
    return p
end
