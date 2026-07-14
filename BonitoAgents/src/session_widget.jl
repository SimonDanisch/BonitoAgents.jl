# KeyedList widget for one discovered Claude Code session row. Keyed on
# (path, session_id); re-scans returning the same data hit the same key and
# touch nothing. The row carries no in-progress UI state (the "Importing…"
# feedback lives only in the JS onclick handler), so we don't need extra
# instance stability beyond the key.

mutable struct SessionRow
    worker_id   :: String   # which worker this thread lives on (import payload)
    path        :: String
    name        :: String
    session_id  :: String
    preview     :: String   # truncated first user-message; "" if unavailable
    meta        :: String
    running     :: Bool     # confirmed alive via OS-level pid check
    row_key     :: String   # "path|session_id"
    # Display title shown for the row. Defaults to the first-prompt preview, but
    # `resolve_session_title!` overrides it with the renamed `ProjectInfo.title`
    # when a project resumes THIS session id — so a user-renamed chat keeps that
    # title here too (the same persisted source the sidebar/header read), live
    # on rename and across worker/server restarts. Reactive so the cached row's
    # DOM updates in place when the title changes.
    title_obs   :: Observable{String}
    # True while a project resuming THIS session is open in the sidebar. The
    # row is NOT hidden then (discover shows every session unconditionally) —
    # it carries an "in sidebar" pill instead, and clicking it reuses the
    # existing thread (`find_thread` dedup in `create_project_from_worker!`)
    # rather than importing a duplicate. Reactive: rows are cached across
    # rescans, so open/close must update the pill in place.
    open_obs    :: Observable{Bool}
end

# The preview-derived fallback title — what we show when no renamed project
# pins a different one.
session_preview_title(preview::AbstractString) =
    isempty(preview) ? "Untitled session" : String(preview)

function SessionRow(c::WorkerCard, r::AbstractDict)
    path       = String(get(r, "path", ""))
    name       = String(get(r, "name", basename(path)))
    sid_raw    = get(r, "session_id", nothing)
    session_id = sid_raw === nothing ? "" : String(sid_raw)
    preview_raw = get(r, "first_prompt", nothing)
    preview    = preview_raw isa AbstractString ? String(preview_raw) : ""
    meta = if haskey(r, "last_used")
        ts = get(r, "last_used", 0.0)
        dt = Dates.unix2datetime(ts isa Number ? Float64(ts) : 0.0)
        base = "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))"
        at = get(r, "agent_type", nothing)
        at === nothing ? base : base * "  ·  subagent: $at"
    else
        ""
    end
    # Three-valued `running` from the worker (true | false | nothing); only
    # explicit `true` produces a UI badge. `nothing` (OS check unavailable)
    # falls through silently.
    running = get(r, "running", nothing) === true
    row_key = string(path, '|', session_id)
    SessionRow(c.worker_id, path, name, session_id, preview, meta, running, row_key,
               Observable(session_preview_title(preview)), Observable(false))
end

# Point the row's display title at the renamed project's title when one resumes
# this exact session id; otherwise fall back to the first-prompt preview. Set
# only on change so we don't churn the bound observable on every rescan.
function resolve_session_title!(sr::SessionRow, projects::AbstractDict)
    want = session_preview_title(sr.preview)
    if !isempty(sr.session_id)
        for p in values(projects)
            if p.resume_session_id == sr.session_id && p.title !== nothing &&
               !isempty(strip(String(p.title)))
                want = String(p.title)
                break
            end
        end
    end
    sr.title_obs[] == want || (sr.title_obs[] = want)
    return sr
end

# Point the row's "in sidebar" pill at whether an OPEN chat currently resumes
# this session (the caller passes the same in-sidebar sid set the old code used
# to hide these rows). Set only on change, like `resolve_session_title!`.
function resolve_session_open!(sr::SessionRow, imported::AbstractSet)
    want = !isempty(sr.session_id) && sr.session_id in imported
    sr.open_obs[] == want || (sr.open_obs[] = want)
    return sr
end

Base.hash(s::SessionRow, h::UInt) = hash(s.row_key, hash(:SessionRow, h))
Base.:(==)(a::SessionRow, b::SessionRow) = a.row_key == b.row_key

function Bonito.jsrender(session::Bonito.Session, s::SessionRow)
    btn_label = isempty(s.session_id) ? "Import" : "Resume"
    running_pill = s.running ?
        DOM.span("running"; class = "bt-pill bt-pill-online") :
        DOM.span()
    # "in sidebar" pill: this session already has an open chat. The row stays
    # visible (discover is unconditional); the pill just says where it lives,
    # and Resume reuses that thread instead of duplicating it.
    open_pill = DOM.span("in sidebar";
        class = map(o -> o ? "bt-pill bt-pill-muted" : "bt-pill bt-hidden", s.open_obs))
    # The folder is already in the group header, so the row LEADS with the
    # chat's title: the renamed `ProjectInfo.title` when one pins this session
    # (resolved into `title_obs`), else the cleaned first prompt the user typed,
    # else a neutral fallback. Reactive so a rename updates the row in place.
    # No inline `onclick` per row — that would queue N jscall-id-keyed setup
    # messages per dashboard render. The delegated listener at the panel level
    # (`render_discover_panel`) reads these `data-bt-*` attrs and notifies.
    return Bonito.jsrender(session, DOM.div(
        DOM.div(
            DOM.div(
                # Wrap the title in a span so it ellipsizes when the row is narrow.
                DOM.span(s.title_obs; class = "bt-session-name-text"),
                running_pill,
                open_pill;
                class = "bt-session-name"),
            isempty(s.meta) ? DOM.span() : DOM.div(s.meta; class = "bt-session-meta");
            class = "bt-session-info"),
        DOM.div(btn_label;
            class   = "bt-btn bt-btn-secondary",
            style   = Styles("cursor" => "pointer", "flex-shrink" => "0"),
            # The delegated listener reads these three to construct the
            # `notify(...)` payload. `js_path` normalises backslashes (Windows
            # paths into a JS data attribute, then back).
            dataBtAction      = "session-pick",
            dataBtSessionPath = js_path(s.path),
            dataBtSessionId   = s.session_id,
            dataBtWorkerId    = s.worker_id);
        class = "bt-session-row"))
end

# One project's header + collapsed list of its session/subagent rows.
# Keyed on `path`; remounts only when a project disappears or appears. The
# nested KeyedList over `rows_obs` preserves child identity inside.
mutable struct SessionGroup
    path        :: String                           # KeyedList key
    name        :: String                           # basename(path)
    rows_obs    :: Observable{Vector{SessionRow}}   # nested KeyedList input
    summary_obs :: Observable{String}               # "5 sessions · 12 subagents · Last used …"
    worker_id   :: String                           # for the "+ New thread" import
end

Base.hash(g::SessionGroup, h::UInt) = hash(g.path, hash(:SessionGroup, h))
Base.:(==)(a::SessionGroup, b::SessionGroup) = a.path == b.path

# Build the right-of-name summary line for a group given its (raw) result
# dicts. Counts sessions vs subagents using the `kind` field and reports the
# most recent `last_used` mtime.
function group_summary_string(rs::Vector)
    n_sessions  = 0
    n_subagents = 0
    n_running   = 0
    latest      = 0.0
    for r in rs
        if String(get(r, "kind", "session")) == "subagent"
            n_subagents += 1
        else
            n_sessions += 1
        end
        get(r, "running", nothing) === true && (n_running += 1)
        ts = get(r, "last_used", 0.0)
        ts isa Number && Float64(ts) > latest && (latest = Float64(ts))
    end
    parts = String[]
    n_sessions  > 0 && push!(parts, "$(n_sessions) session"   * (n_sessions  == 1 ? "" : "s"))
    n_running   > 0 && push!(parts, "$(n_running) running")
    n_subagents > 0 && push!(parts, "$(n_subagents) subagent" * (n_subagents == 1 ? "" : "s"))
    if latest > 0
        dt = Dates.unix2datetime(latest)
        push!(parts, "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))")
    end
    return join(parts, "  ·  ")
end

function Bonito.jsrender(session::Bonito.Session, g::SessionGroup)
    # Start a brand-new thread (fresh claude session, no resume) in this folder.
    # Like the session rows, this is a delegated `data-bt-action="session-pick"`
    # button (empty session_id ⇒ the import handler uses session/new and
    # `find_thread` always makes a sibling) — the panel-level listener in
    # `render_discover_panel` reads these attrs and notifies its SESSION-LOCAL
    # pick observable. The only inline JS is `preventDefault` so the click
    # doesn't toggle the enclosing group <details>; it must NOT stopPropagation,
    # or the event wouldn't bubble up to the panel's delegated listener.
    new_thread_btn = DOM.span("+ New thread";
        class             = "bt-new-thread",
        title             = "Start a fresh chat in this folder",
        dataBtAction      = "session-pick",
        dataBtSessionPath = js_path(g.path),
        dataBtSessionId   = "",
        dataBtWorkerId    = g.worker_id,
        onclick           = js"event => { event.preventDefault(); }")
    return Bonito.jsrender(session, DOM.details(
        DOM.summary(
            DOM.span(g.name; class = "bt-group-name"),
            DOM.span(g.path; class = "bt-group-path"),
            DOM.span(g.summary_obs; class = "bt-group-meta"),
            new_thread_btn;
            class = "bt-group-summary"),
        DOM.div(KeyedList(g.rows_obs; key = sr -> sr.row_key);
            class = "bt-group-body");
        class = "bt-group"))   # default-closed: no `open` attribute
end
