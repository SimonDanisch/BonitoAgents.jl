# One discovered session, as its row shows it. A row is a snapshot: a rename or a
# chat opening builds a new one, and its folder re-renders when its rows differ.
struct SessionRow
    worker_id   :: String   # which worker this thread lives on (import payload)
    path        :: String
    name        :: String
    session_id  :: String
    preview     :: String   # truncated first user-message; "" if unavailable
    meta        :: String
    running     :: Bool     # confirmed alive via OS-level pid check
    # Which agent owns this session, as a wire name ("KimiCode"); "" for rows
    # from the Claude file scan. Imported onto the project so a resumed thread
    # comes back up under the agent that minted its id.
    provider    :: String
    # The first-prompt preview, or the renamed `ProjectInfo.title` when a project
    # resumes THIS session id, so a user-renamed chat keeps that title here too.
    title       :: String
    # True while a project resuming THIS session is open in the sidebar. The
    # row is NOT hidden then (discover shows every session unconditionally):
    # it carries an "in sidebar" pill instead, and clicking it reuses the
    # existing thread (`find_thread` dedup in `create_project_from_worker!`)
    # rather than importing a duplicate.
    open        :: Bool
end

# The preview-derived fallback title — what we show when no renamed project
# pins a different one.
session_preview_title(preview::AbstractString) =
    isempty(preview) ? "Untitled session" : String(preview)

function SessionRow(c::WorkerCard, r::AbstractDict;
                    titles::AbstractDict = Dict{String,String}(), imported::AbstractSet = Set{String}())
    path       = String(get(r, "path", ""))
    name       = String(get(r, "name", basename(path)))
    sid_raw    = get(r, "session_id", nothing)
    session_id = sid_raw === nothing ? "" : String(sid_raw)
    preview_raw = get(r, "first_prompt", nothing)
    preview    = preview_raw isa AbstractString ? String(preview_raw) : ""
    prov_raw   = get(r, "provider", nothing)
    provider   = prov_raw isa AbstractString ? String(prov_raw) : ""
    meta = if haskey(r, "last_used")
        ts = get(r, "last_used", 0.0)
        dt = Dates.unix2datetime(ts isa Number ? Float64(ts) : 0.0)
        base = "Last used $(Dates.format(dt, "yyyy-mm-dd HH:MM"))"
        at = get(r, "agent_type", nothing)
        at !== nothing && (base *= "  ·  subagent: $at")
        isempty(provider) || (base *= "  ·  $(provider)")
        base
    else
        ""
    end
    # Three-valued `running` from the worker (true | false | nothing); only
    # explicit `true` produces a UI badge. `nothing` (OS check unavailable)
    # falls through silently.
    running = get(r, "running", nothing) === true
    SessionRow(c.worker_id, path, name, session_id, preview, meta, running, provider,
               get(titles, session_id, session_preview_title(preview)),
               !isempty(session_id) && session_id in imported)
end

# The titles renamed chats pin on this worker's sessions, by session id.
function pinned_titles(projects::AbstractDict, worker_id::AbstractString)
    return Dict{String,String}(String(p.resume_session_id) => p.title[] for p in values(projects)
                               if p.worker_id == worker_id && !isnothing(p.resume_session_id) &&
                                  !isempty(p.resume_session_id))
end

function render_part(session::Bonito.Session, s::SessionRow)   # timed: diagnostics.jl
    btn_label = isempty(s.session_id) ? "Import" : "Resume"
    running_pill = s.running ?
        DOM.span("running"; class = "bt-pill bt-pill-online") :
        DOM.span()
    # "in sidebar" pill: this session already has an open chat. The row stays
    # visible (discover is unconditional); the pill just says where it lives,
    # and Resume reuses that thread instead of duplicating it.
    open_pill = s.open ? DOM.span("in sidebar"; class = "bt-pill bt-pill-muted") : DOM.span()
    # The folder is already in the group header, so the row LEADS with the
    # chat's title: the renamed `ProjectInfo.title` when one pins this session,
    # else the cleaned first prompt the user typed, else a neutral fallback.
    # No inline `onclick` per row — that would queue N jscall-id-keyed setup
    # messages per dashboard render. The delegated listener at the panel level
    # (`render_discover_panel`) reads these `data-bt-*` attrs and notifies.
    return Bonito.jsrender(session, DOM.div(
        DOM.div(
            DOM.div(
                # Wrap the title in a span so it ellipsizes when the row is narrow.
                DOM.span(s.title; class = "bt-session-name-text"),
                running_pill,
                open_pill;
                class = "bt-session-name"),
            isempty(s.meta) ? DOM.span() : DOM.div(s.meta; class = "bt-session-meta");
            class = "bt-session-info"),
        DOM.div(btn_label;
            class   = "bw-btn bw-btn-secondary",
            style   = Styles("cursor" => "pointer", "flex-shrink" => "0"),
            # The delegated listener reads these three to construct the
            # `notify(...)` payload. `js_path` normalises backslashes (Windows
            # paths into a JS data attribute, then back).
            dataBtAction      = "session-pick",
            dataBtSessionPath = js_path(s.path),
            dataBtSessionId   = s.session_id,
            dataBtProvider    = s.provider,
            dataBtWorkerId    = s.worker_id);
        class = "bt-session-row"))
end

# One project's header + collapsed list of its session/subagent rows. The rows
# are built when the folder first opens. `expanded` lives here so the folder stays
# open when the list around it re-renders.
struct SessionGroup
    path        :: String                           # identity across rescans
    name        :: String                           # basename(path)
    rows_obs    :: Observable{Vector{SessionRow}}   # ignores equal values
    summary_obs :: Observable{String}               # "5 sessions · 12 subagents · Last used …"
    worker_id   :: String                           # for the "+ New thread" import
    expanded    :: Observable{Bool}
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

function render_part(session::Bonito.Session, g::SessionGroup)   # timed: diagnostics.jl
    # Start a brand-new thread (fresh claude session, no resume) in this folder.
    # Like the session rows, this is a delegated `data-bt-action="session-pick"`
    # button (empty session_id ⇒ the import handler uses session/new and
    # `find_thread` always makes a sibling) — the panel-level listener in
    # `render_discover_panel` reads these attrs and notifies its SESSION-LOCAL
    # pick observable. The only inline JS is `preventDefault`, so the click
    # doesn't toggle the folder; it must NOT stopPropagation, or the event
    # wouldn't bubble up to the panel's delegated listener.
    new_thread_btn = DOM.span("+ New thread";
        class             = "bt-new-thread",
        title             = "Start a fresh chat in this folder",
        dataBtAction      = "session-pick",
        dataBtSessionPath = js_path(g.path),
        dataBtSessionId   = "",
        dataBtWorkerId    = g.worker_id,
        onclick           = js"event => { event.preventDefault(); }")
    header = Any[DOM.span(g.name; class = "bt-group-name"),
                 DOM.span(g.path; class = "bt-group-path"),
                 DOM.span(g.summary_obs; class = "bt-group-meta"),
                 new_thread_btn]
    rows() = DOM.div(map(rows -> DOM.div(rows), session, g.rows_obs); class = "bt-group-body")
    return Bonito.jsrender(session, BonitoWidgets.Collapsible(header, rows;
        expanded = g.expanded, class = "bt-group", header_class = "bt-group-summary"))
end
