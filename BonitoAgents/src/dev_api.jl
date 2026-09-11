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

# Per-value caps. A failure gets a much bigger one than an ordinary key: a
# stack trace that stops after 400 characters names no frame at all, which is
# the one thing the record was written to say.
const LOG_VALUE_MAX     = 400
const LOG_EXCEPTION_MAX = 3000
truncate_log(s::AbstractString, n::Int) =
    length(s) > n ? first(String(s), n) * "…" : String(s)

# A logged key's value as text. `show` on a user value can itself throw (a bad
# `show` method, a broken iterator); if it does we keep the record and say so in
# the field, rather than losing the whole log line — a logger that throws inside
# logging takes the process down with it.
function log_value_string(v)
    try
        return truncate_log(sprint(show, v; context = :limit => true), LOG_VALUE_MAX)
    catch e
        e isa InterruptException && rethrow()
        return "<unprintable: $(typeof(e))>"
    end
end

# Strings are already their own text. Going through `show` would wrap every log
# message and every string-valued key in escaped quotes, which is noise in a
# reader whose whole job is being read.
log_value_string(v::AbstractString) = truncate_log(v, LOG_VALUE_MAX)

# `exception = (e, catch_backtrace())` is Base logging's convention for attaching
# a failure, and `show` on that tuple prints the raw instruction pointers: 400
# characters of `Ptr{Nothing}(0x…)` where "which line threw this" belongs. A
# `SystemError("write", 104)` logged that way says a socket was reset and NOTHING
# about which socket — so the exception is rendered, not shown.
function log_value_string(v::Tuple{Any,Vector{<:Union{Ptr{Nothing},Base.InterpreterIP}}})
    try
        return truncate_log(error_detail(v[1], v[2]; frames = 15), LOG_EXCEPTION_MAX)
    catch e
        e isa InterruptException && rethrow()
        return "<unrenderable exception: $(typeof(e))>"
    end
end

function log_value_string(e::Exception)
    try
        return truncate_log(error_detail(e), LOG_EXCEPTION_MAX)
    catch e2
        e2 isa InterruptException && rethrow()
        return "<unrenderable exception: $(typeof(e2))>"
    end
end

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
# `remote_eval` / `remote_workers` / `sync_folder` are not dev tools: every
# chat's MCP may ask them (remote_eval.jl). They share this channel and this
# allow-list because it is the one request/reply path an MCP process has.
const DEV_OPS          = (:inspect, :logs, :memory, :control,
                          :remote_eval, :remote_workers, :sync_folder)
const DEV_SECTIONS     = (:overview, :workers, :worker, :projects, :chats, :evals, :settings)
const DEV_CONTROL_OPS  = (:open_chat, :send_message, :restart_chat, :close_chat,
                          :rescan_worker, :move_project, :set_title)

known_or_throw(name::Symbol, known, what) =
    name in known ? name :
    error("unknown $what '$(name)' — expected one of " * join(known, ", "))

"""
    dev_request(state, op, args, caller = "") -> Any

Run one operation asked over an MCP control channel and return a JSON-encodable
result. `caller` is the project id of the chat whose MCP asked — set by the
channel, never by the request, so an op that grants something per chat
(`remote_eval`) keys on the real caller. Unknown ops throw (the MCP side turns
that into a tool error naming the op), so a typo can't come back as an empty
success.
"""
dev_request(state::ServerState, op::AbstractString, args::AbstractDict,
            caller::AbstractString = "") =
    dev_op(state, Val(known_or_throw(Symbol(op), DEV_OPS, "dev op")), args, String(caller))

# The dev ops don't care who asked; the remote-eval ops (remote_eval.jl) do and
# define the 4-argument method themselves.
dev_op(state::ServerState, v::Val, args::AbstractDict, ::String) = dev_op(state, v, args)

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
        # The two per-chat switches. `dev_mode` in particular is what decides
        # whether a chat's agent gets these very tools, and it was NOT reported
        # here — so the one question a debug chat cannot answer about itself was
        # "am I actually in dev mode?". It is spawn-time state (see
        # `refresh_injected_env`), which is exactly the kind you need to be able
        # to read back.
        "dev_mode"          => p.dev_mode,
        "remote_eval"       => p.remote_eval,
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

# ── fleet logs (every machine's log, from a chat that sits on exactly one) ───
# A dev-mode chat runs on a WORKER and nothing but the server runs on the server
# host, so natively its agent can read one machine's journal: its own. That is
# how the 2026-09-11 hang went — the worker journal was local and answered the
# question, the SERVER's had to be pasted in by hand, and the other four workers
# were never looked at.
#
# The log FILE is not a nicer view of `LOG_RING`; it holds what the ring
# structurally cannot. `errormonitor` prints `UNHANDLED TASK ERROR` straight to
# stderr without passing through the logger, so the ring never recorded the one
# error that mattered; the SIGTERM thread dump is not a log record either; and
# the ring dies with the process, which is exactly what happens to a server that
# gets restarted for hanging. We write that file ourselves (BonitoWorker's
# `start_file_log!` redirects fd 1 and 2) rather than reading journald, which
# exists on the Linux boxes and nowhere else.

# Which name means "the server's own log" rather than a worker's.
const SERVER_LOG_SOURCE = "server"
# Fan out to the server AND every connected worker.
const ALL_LOG_SOURCES   = "all"

"""
    resolve_log_worker(state, source) -> worker_id

The worker `source` names, matched against worker id first and then display name
(case-insensitively), so a human can ask for "MacBook" and a script can pass the
uuid. Throws naming what IS available — a typo must not come back as an empty
log, which reads like a quiet machine.
"""
function resolve_log_worker(state::ServerState, source::AbstractString)
    workers = state.workers[]
    haskey(workers, source) && return source
    hit = findfirst(w -> lowercase(w.name) == lowercase(source), workers)
    hit === nothing || return hit
    known = sort([w.name for w in values(workers)])
    error("unknown log source '$source' — expected \"$(SERVER_LOG_SOURCE)\", " *
          "\"$(ALL_LOG_SOURCES)\", or one of: " * join(known, ", "))
end

# One machine's log, shaped the same whichever machine it is, so a fan-out is a
# vector of these and the caller never special-cases the server.
function log_of(state::ServerState, source::AbstractString; lines, since, until, grep)
    if source == SERVER_LOG_SOURCE
        r = BonitoWorker.read_log_file(; lines, since, until, grep)
        return merge(Dict{String,Any}("source" => SERVER_LOG_SOURCE, "role" => "server"), r)
    end
    wid = resolve_log_worker(state, source)
    name = state.workers[][wid].name
    r = try
        worker_log(state, wid; lines, since, until, grep)
    catch e
        e isa InterruptException && rethrow()
        # An unreachable worker is a finding about THAT worker, not a failure of
        # the fan-out — report it in place, like `dev_section(::Val{:worker})`.
        Dict{String,Any}("ok" => false, "error" => first(split(sprint(showerror, e), '\n')))
    end
    delete!(r, "type"); delete!(r, "request_id")
    return merge(Dict{String,Any}("source" => name, "role" => "worker", "worker_id" => wid), r)
end

function dev_op(state::ServerState, ::Val{:logs}, args::AbstractDict)
    source = String(get(args, "source", ""))
    if !isempty(source) && source != "ring"
        raw = get(args, "limit", 200)
        lines = raw isa Integer ? Int(raw) : 200
        kw = (lines = lines,
              since = String(get(args, "since", "")),
              until = String(get(args, "until", "")),
              grep  = String(get(args, "contains", "")))
        if source == ALL_LOG_SOURCES
            # Server first, then workers by name: a cross-machine incident is
            # read in one pass, and a stable order makes two readings comparable.
            srcs = vcat([SERVER_LOG_SOURCE],
                        sort([w.name for w in values(state.workers[]) if isopen(w)]))
            return Dict{String,Any}(
                "sources" => [log_of(state, x; kw...) for x in srcs])
        end
        return log_of(state, source; kw...)
    end
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
        # CUMULATIVE since process start, not the last pause — reading it as a
        # single pause is how a perfectly healthy 0.4%-of-uptime figure turns
        # into a "7-second stop-the-world" that explains a hang it did not cause.
        "gc_time_ns"        => gc.total_time,
        "threads"           => Threads.nthreads(),
        "open_fds"          => open_fd_count(),
        "fd_limit"          => fd_limit(),
        "registries"        => registry_counts(state),
    )
    deep && (result["deep_sizes"] = deep_sizes(state))
    return result
end

# ── file descriptors ────────────────────────────────────────────────────────
# A server that stops serving NEW connections while its existing timers keep
# ticking looks exactly like a hang, and fd exhaustion is the cheapest way to
# get there: accept() fails, nothing logs, CPU stays flat. The 2026-09-11 hang
# had that shape (all threads idle, 11m36s CPU over 2.5h, 18 minutes of silence,
# four workers reconnecting the instant the process was replaced) and this was
# NOT measurable at the time — which is the reason it is measurable now.
#
# Linux only; `nothing` elsewhere, so the report stays honest rather than
# guessing. `/proc/self/fd` counts the entries including the one the read itself
# opens, which is close enough for a trend.

"""
    open_fd_count() -> Union{Int,Nothing}

How many file descriptors this process currently holds, or `nothing` where that
cannot be read. Compare against [`fd_limit`](@ref); a ratio that climbs across
two readings minutes apart is a leak, and a ratio near 1.0 is the hang.
"""
function open_fd_count()
    isdir("/proc/self/fd") || return nothing
    try
        return length(readdir("/proc/self/fd"))
    catch e
        e isa Base.IOError || e isa SystemError || rethrow()
        return nothing
    end
end

"""
    fd_limit() -> Union{Int,Nothing}

The soft `RLIMIT_NOFILE` for this process. Worth reporting next to the count
because the systemd unit does not set `LimitNOFILE`, so the ceiling is whatever
the distribution's default happens to be.
"""
function fd_limit()
    isfile("/proc/self/limits") || return nothing
    try
        for line in eachline("/proc/self/limits")
            startswith(line, "Max open files") || continue
            soft = split(line)[4]
            return soft == "unlimited" ? typemax(Int) : parse(Int, soft)
        end
        return nothing
    catch e
        e isa Base.IOError || e isa SystemError || rethrow()
        return nothing
    end
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

# Continue a chat on another worker. The SAME operation as the chat header's
# "Continue on <worker>" (`start!`): the project's files and the agent's own
# record of the conversation move through the server, the project is re-bound to
# the new worker, and its session is brought up there — so there is one
# implementation of "move a chat between machines" and this can't drift from it.
function dev_control(state::ServerState, ::Val{:move_project}, args::AbstractDict)
    p = dev_project(state, String(get(args, "project_id", "")))
    dst_worker = String(get(args, "worker_id", ""))
    haskey(state.workers[], dst_worker) || error("no worker '$dst_worker'")
    p.worker_id == dst_worker &&
        error("project '$(p.id)' is already on worker '$dst_worker'")
    w = state.workers[][dst_worker]
    isopen(w) || error("worker '$dst_worker' is offline — can't continue there")
    source_worker = p.worker_id
    start!(state, p, dst_worker)
    return Dict{String,Any}("ok" => true, "project_id" => p.id,
                            "source_worker" => source_worker,
                            "dest_worker" => p.worker_id, "dest_path" => p.worker_path,
                            # Whether the agent resumes with its memory (the
                            # transcript travelled) or starts fresh there.
                            "conversation_carried" => p.resume_session_id !== nothing)
end

# ── the "Debug BonitoAgents" chat ───────────────────────────────────────────
# A normal project, pointed at a BonitoAgents source checkout ON THE WORKER it
# runs on, with `dev_mode` set. `dev_mode` is what attaches the `bt_dev_*` tools
# (via `eval_dialback_env`) and the briefing in the system prompt (via
# `agents_prompt_appendix`); the cwd is what lets the agent read, edit and `git`
# the code. Nothing else is special about it — it uses the same bring-up, the
# same worker, the same everything.
#
# The checkout is the WORKER's, not this server's. The server's own checkout (if
# it has one) is a path on the server's machine, which a worker cannot see unless
# the two happen to share a filesystem — so the worker is asked to provide one
# (`debug_checkout_on_worker`): the checkout it already runs from when it is a
# dev install, otherwise a clone at `<env>/dev/BonitoAgents` developed into its
# environment, at the revision this server runs (`current_repo_rev`). That is
# `dev --local` done for the user, and it means a restart of that worker runs
# what the agent edited.

"""
    bonitoagents_repo_root() -> String | nothing

The git repository containing THIS server's BonitoAgents source, or `nothing`
when the install isn't a checkout (a bundled app, or a package installed from
the registry). Walks up from `pkgdir` to a `.git` — a DIRECTORY (a normal
clone) or a FILE (a worktree or a submodule) — and only accepts a root that is
the monorepo (has the sibling packages), so a dotfiles repository in `\$HOME`
can't claim `~/.julia/packages/…`.

This is the server's view of itself. The debug chat's working directory comes
from the WORKER (see the section comment above); the two coincide when server
and worker run from the same checkout, which is what the test suite does.
"""
function bonitoagents_repo_root()
    dir = pkgdir(@__MODULE__)
    dir === nothing && return nothing
    cur = abspath(String(dir))
    while true
        ispath(joinpath(cur, ".git")) && is_monorepo_root(cur) && return cur
        parent = dirname(cur)
        parent == cur && return nothing
        cur = parent
    end
end

is_monorepo_root(dir::AbstractString) =
    isfile(joinpath(dir, "BonitoAgents", "Project.toml")) &&
    isfile(joinpath(dir, "BonitoWorker", "Project.toml"))

"""
    is_source_checkout_project(state, p) -> Bool

Whether this project's working directory IS a BonitoAgents monorepo checkout on
its worker — i.e. whether its agent can read the code it is debugging.

True for the project the "Debug BonitoAgents" button opens, false for one that
got `dev_mode` from the header toggle while sitting on an ordinary tree. Asked
of the worker (a `stat` of the sibling packages' Project.toml), because a path
only means something on the machine it is on.
"""
function is_source_checkout_project(state::ServerState, p::ProjectInfo)
    root = rstrip(p.worker_path, '/')
    isempty(root) && return false
    for pkg in ("BonitoAgents", "BonitoWorker")
        stat_worker_path(state, p.worker_id, joinpath(root, pkg, "Project.toml")).isfile ||
            return false
    end
    return true
end

"""
    set_dev_mode!(state, project_id, on) -> ProjectInfo

Turn `dev_mode` on or off for one project, persist it, and return the project.
Throws by name if there is no such project.

Writes only on an actual change, so a toggle can be clicked repeatedly without
rewriting `projects.json` each time.

The caller is responsible for RESTARTING the chat afterwards. `dev_mode` is read
at session bring-up and nowhere else: `eval_dialback_env` bakes
`BONITOAGENTS_DEV_TOOLS` into the MCP process's environment when it is spawned,
and `agents_prompt_appendix` composes the briefing into the system prompt at
`open_session`. A live session keeps whatever it started with, so flipping the
flag without a restart changes what is on disk and nothing the agent can see.
"""
function set_dev_mode!(state::ServerState, project_id::AbstractString, on::Bool)
    p = dev_project(state, project_id)
    if p.dev_mode != on
        p.dev_mode = on
        lock(state.lock) do; save_projects!(state); end
        safe_notify!(state.projects)
    end
    return p
end

"""
    debug_project_worker(state, preferred = "") -> worker_id

Which worker the debug chat runs on: `preferred` (the dashboard picker's choice,
or the worker of the chat the button was pressed in) when it is connected, else
the first connected worker by name. Errors — naming the worker — when the
preferred one is unknown or offline, and when there is none at all: the chat
has to run somewhere, and quietly picking another machine than the one the user
chose is worse than saying so.
"""
function debug_project_worker(state::ServerState, preferred::AbstractString = "")
    workers = state.workers[]
    if !isempty(preferred)
        w = get(workers, String(preferred), nothing)
        w === nothing && error("no worker '$(preferred)'")
        isopen(w) || error("worker '$(w.name)' is not connected")
        return String(preferred)
    end
    online = sort([w for w in values(workers) if isopen(w)]; by = w -> w.name)
    isempty(online) && error("no worker is connected — a debug chat needs one to run on")
    return first(online).worker_id
end

"""
    ensure_debug_project!(state; worker_id = "") -> ProjectInfo

Find or create the "Debug BonitoAgents" project on a worker and return it, ready
to open. Idempotent: a second call reuses the existing one, so the button can be
clicked any number of times and the conversation survives.

The worker provides the checkout (see the section comment): a first call on an
ordinary install clones the repository into the worker's environment and
precompiles, which takes a few minutes — `debug_checkout_on_worker`'s timeout is
sized for that. Throws — with a message meant for the user — when no worker is
connected or the worker could not set the checkout up.
"""
function ensure_debug_project!(state::ServerState; worker_id::AbstractString = "")
    wid  = debug_project_worker(state, worker_id)
    root = debug_checkout_on_worker(state, wid; repo = WORKER_REPO_URL,
                                    rev = current_repo_rev(),
                                    packages = WORKER_REPO_PACKAGES)

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
