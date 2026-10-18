# What the dev tools (dev_api.jl, the bt_dev_* MCP tools) read about the live
# server beyond its tables: how long its work takes, which browser tabs it holds
# and in what state, and what those tabs' consoles said.
#
# Added after a desktop waited 14 s for the page and a phone minutes, while the
# log said nothing: the time went somewhere no line was written, and tabs that
# had gone away kept being served without anyone being able to see them.

# ── timings ──────────────────────────────────────────────────────────────────

"""
    record_timing!(state, kind, seconds; keep = 500, detail...)

Keep how long one piece of `kind` work took, with `detail` (JSON-able values),
for `bt_dev_timings`. The last `keep` of each kind are kept. Kinds in use:
`:page` (building a page, `page_phase` parts in `phases`), `:browser_load` (the
page's own report), `:chat_command`, `:worker_rpc`, `:notify` (a change fanned
out to every tab), `:scan`.
"""
function record_timing!(state::ServerState, kind::Symbol, seconds::Real; keep::Int = 500, detail...)
    t = root_state(state).timings
    entry = TimingEntry(time(), Float64(seconds), Dict{String,Any}(String(k) => v for (k, v) in detail))
    lock(t.lock) do
        list = get!(Vector{TimingEntry}, t.kinds, kind)
        push!(list, entry)
        length(list) > keep && deleteat!(list, 1:(length(list) - keep))
    end
    return nothing
end

"""
    timed(f, state, kind; detail...) -> f()

Call `f` and record how long it took as `kind` (`record_timing!`), also when it
throws (`ok = false`).
"""
function timed(f, state::ServerState, kind::Symbol; detail...)
    t0 = time()
    ok = false
    try
        result = f()
        ok = true
        return result
    finally
        record_timing!(state, kind, time() - t0; ok, detail...)
    end
end

# Local time, like the log files' timestamps, so a timing and a log line line up.
local_time(t::Real) = Libc.strftime("%Y-%m-%d %H:%M:%S", t)

function timing_summary(entries::AbstractVector{TimingEntry})
    isempty(entries) && return Dict{String,Any}("count" => 0)
    s = sort!([e.seconds for e in entries])
    q(p) = round(s[clamp(ceil(Int, p * length(s)), 1, length(s))]; digits = 3)
    return Dict{String,Any}("count" => length(s), "p50_s" => q(0.5), "p95_s" => q(0.95),
                            "max_s" => round(s[end]; digits = 3),
                            "total_s" => round(sum(s); digits = 2),
                            "since" => local_time(first(entries).t))
end

timing_row(e::TimingEntry) =
    merge(Dict{String,Any}("at" => local_time(e.t), "seconds" => round(e.seconds; digits = 3)),
          jsonable(e.detail))

# The page parts there can be many of, timed as they render: what a page spends
# in Bonito after its handler returned (`render`) is spent in parts like these.
const TimedPart = Union{WorkerCard,SessionGroup,SessionRow,SidebarChat}
part_phase(::WorkerCard)   = :worker_cards
part_phase(::SessionGroup) = :session_groups
part_phase(::SessionRow)   = :session_rows
part_phase(::SidebarChat)  = :sidebar_chats
Bonito.jsrender(session::Bonito.Session, part::TimedPart) =
    page_phase(() -> render_part(session, part), part_phase(part))

# ── browser tabs ─────────────────────────────────────────────────────────────

"""
    register_tab!(state, session, user, client, view; keep_closed = 50) -> TabRecord

Record a browser tab: for the dev tools, and for `close_user_sessions!`. When its
session closes, the record moves to the recently closed tabs (the last
`keep_closed`), without the session.
"""
function register_tab!(state::ServerState, session::Bonito.Session, user::User,
                       client::AbstractString, view::Observable{String}; keep_closed::Int = 50)
    tabs = root_state(state).tabs
    root = Bonito.root_session(session)
    rec = TabRecord(root.id, user.name, String(client), time(), root, view, "", 0.0, "", 0.0,
                    ConsoleEntry[])
    lock(() -> (tabs.open[rec.id] = rec), tabs.lock)
    on(root.on_close) do closed
        closed || return
        lock(tabs.lock) do
            rec.closed == 0 || return
            delete!(tabs.open, rec.id)
            rec.last_view = rec.view === nothing ? "" : rec.view[]
            rec.session = nothing
            rec.view = nothing
            rec.closed = time()
            push!(tabs.closed, rec)
            length(tabs.closed) > keep_closed && deleteat!(tabs.closed, 1:(length(tabs.closed) - keep_closed))
        end
    end
    return rec
end

"""
    close_user_sessions!(state, name) -> Int

Close every tab of the account `name` (disabled, removed, its password reset):
an open websocket is not asked again whether its login still holds.
"""
function close_user_sessions!(state::ServerState, name::AbstractString)
    tabs = root_state(state).tabs
    sessions = lock(tabs.lock) do
        Bonito.Session[r.session for r in values(tabs.open) if r.user == name && r.session !== nothing]
    end
    foreach(close, sessions)
    return length(sessions)
end

# The tab a dev tool names, by a prefix of its id (the log's 8-character `tab`).
function find_tab(state::ServerState, prefix::AbstractString)
    tabs = root_state(state).tabs
    found = lock(tabs.lock) do
        [r for r in Iterators.flatten((values(tabs.open), Iterators.reverse(tabs.closed)))
         if startswith(r.id, prefix)]
    end
    isempty(found) && error("no tab '$prefix' (open or recently closed); `bt_dev_inspect section=tabs` lists them")
    length(unique(r -> r.id, found)) > 1 &&
        error("'$prefix' names $(length(found)) tabs; give more of the id")
    return first(found)
end

subsession_count(s::Bonito.Session) =
    lock(Bonito.deletion_lock(s)) do
        sum((1 + subsession_count(c) for c in values(s.children)); init = 0)
    end

"""
    tab_report(rec) -> Dict

A tab as the dev tools show it. `connected` is whether its socket is live.
`status` is Bonito's: `SOFT_CLOSED` lost its socket and is still served (and
queues what it is sent) until the cleanup time; a connected page can be `OPEN`
or stay `DISPLAYED` (the render marks it after the page may already have
connected).
"""
function tab_report(rec::TabRecord)
    d = Dict{String,Any}(
        "tab"        => first(rec.id, 8),
        "session"    => rec.id,
        "user"       => rec.user,
        "client"     => rec.client,
        "opened"     => local_time(rec.opened),
        "age_s"      => round(time() - rec.opened; digits = 1),
        "visibility" => rec.visibility,
        "console_from_beacons" => length(rec.console))
    rec.visibility_t == 0 || (d["visibility_s_ago"] = round(time() - rec.visibility_t; digits = 1))
    s = rec.session
    if s === nothing
        d["status"] = "CLOSED"
        d["view"] = rec.last_view
        d["closed"] = local_time(rec.closed)
        d["closed_s_ago"] = round(time() - rec.closed; digits = 1)
    else
        d["status"] = string(s.status)
        d["connected"] = isopen(s)
        d["view"] = rec.view === nothing ? "" : rec.view[]
        d["queued_messages"] = length(s.message_queue)
        d["subsessions"] = subsession_count(s)
        s.status == Bonito.SOFT_CLOSED && (d["dropped_s_ago"] = round(time() - s.closing_time; digits = 1))
    end
    return d
end

# ── browser consoles ─────────────────────────────────────────────────────────

const CONSOLE_ROUTE = "/console-log"

"""
    console_capture(session) -> DOM.script

Keeps the page's console (`console.*`, uncaught errors, unhandled rejections) in
a ring the dev tools read live (`bt_dev_console`), and beacons what is new to
`CONSOLE_ROUTE` whenever the tab is hidden, shown or left, so a tab that went to
sleep (a phone) still has its last words on the server. A `<script>` in the page
itself, so it runs while the page is parsed, before the page's own code.
"""
function console_capture(session::Bonito.Session; keep::Int = 1000, text_max::Int = 2000,
                         per_beacon::Int = 300)
    tab = JSON.json(Bonito.root_session(session).id)
    route = JSON.json(CONSOLE_ROUTE)
    return DOM.script("""(() => {
    if (window.__btConsole) return;
    const entries = [];
    let sent = 0;
    const show = (x) => {
        if (typeof x === 'string') return x;
        if (x instanceof Error) return x.stack || String(x);
        // A cyclic object is a TypeError for JSON; its String() is what's left.
        let s;
        try { s = JSON.stringify(x); }
        catch (error) { if (!(error instanceof TypeError)) throw error; }
        return s === undefined ? String(x) : s;
    };
    const push = (level, args) => {
        let text = Array.from(args, show).join(' ');
        if (text.length > $(text_max)) text = text.slice(0, $(text_max)) + '…';
        entries.push({t: Date.now() / 1000, level, text});
        if (entries.length > $(keep)) {
            const drop = entries.length - $(keep);
            entries.splice(0, drop);
            sent = Math.max(0, sent - drop);
        }
    };
    for (const level of ['debug', 'log', 'info', 'warn', 'error']) {
        const original = console[level].bind(console);
        console[level] = (...args) => { push(level, args); original(...args); };
    }
    window.addEventListener('error', (e) => push('error', [e.message + ' (' + e.filename + ':' + e.lineno + ')']));
    window.addEventListener('unhandledrejection', (e) => push('error', ['unhandled rejection:', e.reason]));
    const beacon = (state) => {
        const fresh = entries.slice(sent).slice(-$(per_beacon));
        sent = entries.length;
        const body = JSON.stringify({tab: $(tab), state, entries: fresh});
        navigator.sendBeacon($(route), new Blob([body], {type: 'application/json'}));
    };
    document.addEventListener('visibilitychange', () => beacon(document.visibilityState));
    window.addEventListener('pagehide', () => beacon('pagehide'));
    window.__btConsole = {tab: $(tab), entries: () => entries.slice()};
})();""")
end

const CONSOLE_LEVELS = ("debug", "log", "info", "warn", "error")
console_level_rank(level::AbstractString) =
    something(findfirst(==(lowercase(level)), CONSOLE_LEVELS), 2)

"""
    console_beacon_response(state, request; max_bytes = 262_144, keep = 1000) -> HTTP.Response

Take what a tab's console capture beaconed (`console_capture`): its new entries
(the tab keeps the last `keep`) and whether it is now hidden, shown or left.
"""
function console_beacon_response(state::ServerState, request::HTTP.Request;
                                 max_bytes::Integer = 262_144, keep::Int = 1000)
    request.method == "POST" || return plain_response(405, "POST a tab's console entries")
    body = request_bytes(request.body)
    length(body) <= max_bytes || return plain_response(413, "send fewer console entries at a time")
    msg = JSON.parse(String(body))
    msg isa AbstractDict || return plain_response(400, "a console beacon is a JSON object")
    tab = string(get(msg, "tab", ""))
    tabs = root_state(state).tabs
    rec = lock(tabs.lock) do
        r = get(tabs.open, tab, nothing)
        r === nothing || return r
        i = findlast(c -> c.id == tab, tabs.closed)   # a tab beacons as it is left
        i === nothing ? nothing : tabs.closed[i]
    end
    rec === nothing && return plain_response(404, "no such tab")
    fresh = ConsoleEntry[]
    for e in get(msg, "entries", Any[])
        e isa AbstractDict || continue
        t = get(e, "t", 0.0)
        level = lowercase(string(get(e, "level", "log")))
        push!(fresh, ConsoleEntry(t isa Real ? Float64(t) : 0.0,
                                  level in CONSOLE_LEVELS ? level : "log", string(get(e, "text", ""))))
    end
    lock(tabs.lock) do
        append!(rec.console, fresh)
        length(rec.console) > keep && deleteat!(rec.console, 1:(length(rec.console) - keep))
        rec.visibility = string(get(msg, "state", ""))
        rec.visibility_t = time()
    end
    return HTTP.Response(204)
end

# What a connected tab's console holds now, asked through its own session.
function live_console(session::Bonito.Session; timeout::Real = 5.0)
    raw = Bonito.evaljs_value(session, js"window.__btConsole ? window.__btConsole.entries() : null"; timeout)
    raw === nothing && error("this tab's page has no console capture (it predates it); reload it")
    return ConsoleEntry[ConsoleEntry(Float64(e["t"]), String(e["level"]), String(e["text"])) for e in raw]
end

console_row(e::ConsoleEntry) =
    Dict{String,Any}("at" => local_time(e.t), "level" => e.level, "text" => e.text)

# ── the dev ops ──────────────────────────────────────────────────────────────

function dev_section(state::ServerState, ::Val{:tabs}, prefix::String)
    tabs = root_state(state).tabs
    open, closed = lock(() -> (collect(values(tabs.open)), copy(tabs.closed)), tabs.lock)
    picked(r) = startswith(r.id, prefix)
    return Dict{String,Any}(
        "open"            => [tab_report(r) for r in sort!(filter(picked, open); by = r -> -r.opened)],
        "recently_closed" => [tab_report(r) for r in Iterators.reverse(filter(picked, closed))])
end

function dev_op(state::ServerState, ::Val{:timings}, args::AbstractDict)
    kind = String(get(args, "kind", ""))
    limit = Int(get(args, "limit", 20))
    min_s = Float64(get(args, "min_seconds", 0.0))
    t = root_state(state).timings
    all_kinds = lock(() -> Dict(String(k) => copy(v) for (k, v) in t.kinds), t.lock)
    isempty(kind) || haskey(all_kinds, kind) ||
        error("no timings of kind '$kind' yet; recorded: " * join(sort!(collect(keys(all_kinds))), ", "))
    report = Dict{String,Any}()
    for (k, entries) in all_kinds
        isempty(kind) || k == kind || continue
        shown = filter(e -> e.seconds >= min_s, entries)
        report[k] = Dict{String,Any}(
            "summary" => timing_summary(entries),
            "slowest" => [timing_row(e) for e in first(sort(entries; by = e -> -e.seconds), min(5, length(entries)))],
            "recent"  => [timing_row(e) for e in Iterators.take(Iterators.reverse(shown), limit)])
    end
    return Dict{String,Any}("kinds" => sort!(collect(keys(all_kinds))), "timings" => report)
end

function dev_op(state::ServerState, ::Val{:console}, args::AbstractDict)
    prefix = String(get(args, "tab", ""))
    if isempty(prefix)
        tabs = dev_section(state, Val(:tabs), "")
        return Dict{String,Any}("tabs" => [Dict{String,Any}(k => r[k] for k in ("tab", "user", "client", "status", "console_from_beacons") if haskey(r, k))
                                           for r in vcat(tabs["open"], tabs["recently_closed"])])
    end
    rec = find_tab(state, prefix)
    live = get(args, "live", true) === true && rec.session !== nothing && isopen(rec.session)
    entries = live ? live_console(rec.session) :
                     lock(() -> copy(rec.console), root_state(state).tabs.lock)
    min_rank = console_level_rank(String(get(args, "level", "debug")))
    needle = lowercase(String(get(args, "contains", "")))
    matched = [e for e in entries
               if console_level_rank(e.level) >= min_rank && (isempty(needle) || occursin(needle, lowercase(e.text)))]
    limit = Int(get(args, "limit", 200))
    return Dict{String,Any}(
        "tab" => first(rec.id, 8), "user" => rec.user, "client" => rec.client,
        "source" => live ? "live" : "beacons",
        "total" => length(entries), "matched" => length(matched),
        "entries" => [console_row(e) for e in matched[max(1, end - limit + 1):end]])
end
