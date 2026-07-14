# KeyedList-friendly widget for one worker row. Held stable per worker_id
# in dashboard_dom's `worker_cards` Dict; picker form + discover panel
# are sub-DOMs toggled via class-bound Observables so their state
# (folder picker selection, scan results, focus) survives open/close.

mutable struct WorkerCard
    state            :: ServerState
    worker_id        :: String          # KeyedList key
    error_obs        :: Observable{String}
    picker_state     :: Observable{String}    # worker_id of the open picker
    discover_state   :: Observable{String}    # worker_id of the open panel
    busy             :: Observable            # BUSY_IDLE-shape NamedTuple
    discover_busy    :: Observable{Bool}
    discover_results :: Observable{Vector{Dict{String,Any}}}
    do_import        :: Function
    trigger_scan     :: Function
    remote_picker    :: RemoteFolderPicker
    name_obs         :: Observable{String}
    initials_obs     :: Observable{String}
end

function WorkerCard(state::ServerState, worker_id::AbstractString;
                     error_obs::Observable{String},
                     picker_state::Observable{String},
                     discover_state::Observable{String},
                     busy::Observable,
                     discover_busy::Observable{Bool},
                     discover_results::Observable{Vector{Dict{String,Any}}},
                     do_import::Function,
                     trigger_scan::Function)
    w0 = get(state.workers[], worker_id, nothing)
    initial_name     = w0 === nothing ? worker_id : w0.name
    initial_initials = w0 === nothing ? derive_initials(worker_id) :
                                        worker_initials(w0)
    WorkerCard(state, String(worker_id),
                error_obs, picker_state, discover_state,
                busy, discover_busy, discover_results,
                do_import, trigger_scan,
                RemoteFolderPicker(worker_id),
                Observable(initial_name),
                Observable(initial_initials))
end

Base.hash(c::WorkerCard, h::UInt) = hash(c.worker_id, hash(:WorkerCard, h))
Base.:(==)(a::WorkerCard, b::WorkerCard) = a.worker_id == b.worker_id

function Bonito.jsrender(session::Bonito.Session, c::WorkerCard)
    state, wid = c.state, c.worker_id

    status_obs = map(state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? :unknown : (isopen(w) ? :online : :offline)
    end
    subtitle_obs = map(state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? "(removed)" : worker_subtitle(w)
    end
    is_online_obs = map(s -> s == :online, status_obs)
    title_attr = let w = get(state.workers[], wid, nothing)
        w === nothing ? "(removed)" :
            "$(w.hostname) · home: $(w.home)"
    end

    new_proj_btn = Bonito.Button("+ Project"; style=nothing, class = "bt-btn bt-btn-secondary")
    on(session, new_proj_btn.value) do clicked
        clicked || return
        c.picker_state[]   = c.picker_state[] == wid ? "" : wid
        c.error_obs[]      = ""
    end

    name_input = DOM.input(
        type  = "text",
        value = c.name_obs,
        class = "bt-card-name bt-card-name-edit",
        title = "Click to rename — Enter to save, Esc to cancel",
        onblur    = js"event => $(c.name_obs).notify(event.target.value)",
        onkeydown = js"""event => {
            if (event.key === 'Enter')  { event.target.blur(); }
            if (event.key === 'Escape') {
                event.target.value = event.target.defaultValue;
                event.target.blur();
            }
        }""")
    on(session, c.name_obs) do v
        new = strip(String(v))
        cur = haskey(state.workers[], wid) ? state.workers[][wid].name : wid
        isempty(new) && (c.name_obs[] = cur; return)
        new == cur && return
        try
            rename_worker!(state, wid, new)
            c.error_obs[] = ""
        catch e
            c.error_obs[] = "Rename failed: $(sprint(showerror, e))"
            c.name_obs[]  = cur
        end
    end

    # `[DT]` tag — short worker initials shown next to every chat/project that
    # lives on this worker. Up to 4 chars (room for a short emoji). Empty
    # input clears the override and the UI falls back to derive_initials(name).
    initials_input = DOM.input(
        type      = "text",
        value     = c.initials_obs,
        maxlength = 4,
        class     = "bt-card-initials bt-card-initials-edit",
        title     = "Worker tag (1–4 chars, emoji ok) — shown as [XX] in chat labels",
        onblur    = js"event => $(c.initials_obs).notify(event.target.value)",
        onkeydown = js"""event => {
            if (event.key === 'Enter')  { event.target.blur(); }
            if (event.key === 'Escape') {
                event.target.value = event.target.defaultValue;
                event.target.blur();
            }
        }""")
    on(session, c.initials_obs) do v
        new = strip(String(v))
        w_now = get(state.workers[], wid, nothing)
        cur = w_now === nothing ? derive_initials(wid) : worker_initials(w_now)
        new == cur && return
        try
            set_worker_initials!(state, wid, new)
            # Snap the input to the canonical render (derived if cleared).
            c.initials_obs[] = worker_initials(state.workers[][wid])
            c.error_obs[]    = ""
        catch e
            c.error_obs[] = "Initials update failed: $(sprint(showerror, e))"
            c.initials_obs[] = cur
        end
    end

    status_dot_obs = map(status_obs) do s
        status_dot(s)
    end

    # Remove worker. The confirm() lives in JS so we never fire the
    # destructive call without an explicit OK; only then does the trigger
    # Observable flip and the Julia handler run `remove_worker!`.
    remove_trigger = Observable(false)
    on(session, remove_trigger) do go
        go || return
        try
            remove_worker!(state, wid)
            c.error_obs[] = ""
        catch e
            c.error_obs[] = "Remove failed: $(sprint(showerror, e))"
        end
    end
    remove_btn = DOM.div("✕";
        class = "bt-card-remove",
        title = "Remove this worker",
        onclick = js"""event => {
            event.stopPropagation();
            if (confirm("Remove this worker and its projects from the list?\n\nChat history files are kept on disk. A worker whose process is still running may reconnect."))
                $(remove_trigger).notify(true);
        }""")

    # Render both action variants; toggle visibility via class. Keeps the
    # Bonito.Button instances mounted so click handlers don't churn.
    online_class  = map(o -> o ? "bt-card-actions"            : "bt-card-actions bt-hidden", is_online_obs)
    offline_class = map(o -> o ? "bt-card-actions bt-hidden"  : "bt-card-actions",            is_online_obs)
    actions_block = DOM.div(
        DOM.div(new_proj_btn; class = online_class),
        DOM.div(DOM.span("offline"; class = "bt-pill bt-pill-muted"); class = offline_class))

    card_body = DOM.div(
        DOM.div(status_dot_obs, initials_input, name_input, remove_btn;
                class = "bt-card-title"),
        DOM.div(subtitle_obs; class = "bt-card-meta", title = title_attr);
        class = "bt-card-body")

    # Top row of the worker pill: identity + actions. The discover details lives
    # inside the SAME pill (below this row), so a worker with a collapsed project
    # list takes the same space as a bare card — no separate pill underneath.
    card_row = DOM.div(card_body, actions_block; class = "bt-card-row")

    is_picking_obs = map(s -> s == wid, c.picker_state)
    picker_form    = render_remote_picker_form(session, c, wid)
    picker_class   = map(p -> p ? "bt-form-wrapper" : "bt-form-wrapper bt-hidden", is_picking_obs)
    picker_block   = DOM.div(picker_form; class = picker_class)

    # Project list is a `<details>` nested INSIDE the card so the closed state is
    # just a thin "▸ projects (N)" toggle row — no separate pill chrome. Fed
    # from state.discovered (no scan needed on first paint); the per-card Rescan
    # button refreshes it.
    card = DOM.div(card_row, render_discover_panel(session, c, wid); class = "bt-card")

    return Bonito.jsrender(session,
        DOM.div(card, picker_block; class = "bt-worker-cell"))
end

function render_remote_picker_form(session::Bonito.Session, c::WorkerCard, wid::String)
    create_btn = Bonito.Button("Create"; style=nothing, class = "bt-btn")
    cancel_btn = Bonito.Button("Cancel"; style=nothing, class = "bt-btn bt-btn-secondary")
    rp = c.remote_picker

    on(session, create_btn.value) do clicked
        clicked || return
        is_busy_idle(c.busy[]) || return
        chosen = String(strip(rp.selected[]))
        if isempty(chosen)
            c.error_obs[] = "Pick a folder on the worker first (Browse → Choose)."
            return
        end
        rp.selected[] = ""
        c.do_import(wid, chosen)
    end
    on(session, cancel_btn.value) do clicked
        clicked || return
        is_busy_idle(c.busy[]) || return
        c.picker_state[] = ""
        c.error_obs[]    = ""
    end

    display_name_obs = map(c.state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? wid : w.name
    end
    label_obs = map(n -> "Folder on $n", display_name_obs)

    DOM.div(
        DOM.label(label_obs),
        DOM.div(
            remote_folder_picker_render(session, rp),
            map(rp.selected) do sel
                isempty(sel) ? DOM.div() :
                    DOM.div("✓ selected: $sel",
                            style = Styles("color" => "#065f46",
                                            "font-size" => "12px",
                                            "margin-top" => "4px"))
            end),
        DOM.div(cancel_btn, create_btn, class = "bt-form-actions");
        class = "bt-form")
end

# Persistent folder→threads browser for one worker. Reads from the
# server-side `state.discovered[wid]` cache (saved to discovered.json), so the
# tree survives a restart with no re-scan; the per-card Rescan button refreshes
# it. All pieces (spinner, empty, errors, the KeyedList of folder groups) are
# mounted simultaneously; class-bound observables flip visibility so nothing
# re-renders on busy / results transitions.
function render_discover_panel(session::Bonito.Session, c::WorkerCard, wid::String)
    # Per-card scan-in-flight flag so rescanning one worker doesn't spin every
    # other worker's panel.
    scan_busy = Observable(false)
    rescan_trigger = Observable(false)
    on(session, rescan_trigger) do go
        go || return
        scan_busy[] && return
        scan_busy[] = true
        @async try
            scan_and_store!(c.state, wid)
        catch e
            c.error_obs[] = "Scan failed: $(sprint(showerror, e))"
        finally
            scan_busy[] = false
        end
    end

    # Resume / Import / + New thread all funnel through ONE session-local `pick`
    # observable + the ONE delegated panel listener below. It's created in THIS
    # render's session (like `rescan_trigger`), so `$(pick)` is guaranteed to be
    # in GLOBAL_OBJECT_CACHE at click time. The previous code interpolated the
    # SHARED `import_path` from `dashboard_dom`'s scope — registered in a
    # DIFFERENT session than the card's — so the client lookup returned null and
    # `.notify` threw "Key N not found", silently killing Resume while the
    # optimistic "Resuming…" label still flipped. (bonito skill: never
    # interpolate a shared Observable into a sub-session's render.) The bridge to
    # the shared `c.do_import` keeps the actual import logic in one place.
    pick = Observable(Dict{String,Any}())
    on(session, pick) do payload
        isempty(payload) && return
        path = String(get(payload, "path", ""))
        isempty(path) && return
        sid_raw = get(payload, "session_id", nothing)
        resume_session_id = (sid_raw === nothing || isempty(String(sid_raw))) ?
                                nothing : String(sid_raw)
        w_name = String(get(payload, "worker", ""))
        pick[] = Dict{String,Any}()              # reset so the same row can re-fire
        isempty(w_name) && return
        is_busy_idle(c.busy[]) || return         # drop double-clicks while a start is in flight
        c.do_import(w_name, path; resume_session_id = resume_session_id)
    end
    # Plain DOM (not Bonito.Button) so the onclick can `preventDefault` the
    # enclosing <details> summary toggle (Rescan should NOT collapse the panel
    # — it should open it so the spinner / refreshed tree are visible), and
    # `stopPropagation` belt-and-braces.
    rescan_btn = DOM.span("↻ Rescan";
        class = "bt-btn bt-btn-secondary",
        style = Styles("cursor" => "pointer"),
        onclick = js"""event => {
            event.preventDefault(); event.stopPropagation();
            const d = event.currentTarget.closest('details');
            if (d) d.open = true;
            $(rescan_trigger).notify(true);
        }""")

    # This worker's persisted scan results (worker_id → Vector of session dicts).
    results_obs = map(c.state.discovered) do d
        get(d, wid, Dict{String,Any}[])
    end

    # Session ids that are an OPEN chat in the homebar on this worker (a project
    # whose `resume_session_id` matches AND that `chat_in_sidebar` shows). Used
    # to tag those discover rows with an "in sidebar" pill — the rows stay
    # VISIBLE (discover is unconditional; hiding them made sessions look lost
    # whenever sidebar state and discover disagreed). Clicking such a row reuses
    # the existing thread (`find_thread` dedup), never a duplicate. Session-
    # scoped (`map(session, …)`) so the listener deregisters with the browser
    # session rather than leaking onto the long-lived `state.projects`.
    imported_sids = map(session, c.state.projects) do projects
        Set(String(p.resume_session_id) for p in values(projects)
            if p.resume_session_id !== nothing && p.worker_id == wid && chat_in_sidebar(p))
    end

    display_name_obs = map(c.state.workers) do workers
        w = get(workers, wid, nothing)
        w === nothing ? wid : w.name
    end
    # Live count of distinct project folders for the inline "projects (N)" label.
    # Same dedup the groups_obs builder below uses (skip errors + subagents).
    project_count_obs = map(results_obs) do results
        seen = Set{String}()
        for r in results
            haskey(r, "error") && continue
            String(get(r, "kind", "session")) == "subagent" && continue
            push!(seen, String(get(r, "path", "")))
        end
        length(seen)
    end
    title_obs = map(n -> "projects ($n)", project_count_obs)

    spinner_msg_obs = map(n -> "Scanning $n for Claude Code sessions…", display_name_obs)
    spinner_class = map(b -> b ? "bt-spinner-row" : "bt-spinner-row bt-hidden", scan_busy)
    spinner_block = DOM.div(
        DOM.div(class = "bt-spinner"),
        DOM.span(spinner_msg_obs);
        class = spinner_class)

    empty_msg_obs = map(n -> "No Claude Code sessions found on $n yet — click Rescan.", display_name_obs)
    show_empty_obs = map(scan_busy, results_obs) do busy, results
        !busy && isempty(results)
    end
    empty_class = map(show -> show ? "bt-empty" : "bt-empty bt-hidden", show_empty_obs)
    empty_block = DOM.div(empty_msg_obs; class = empty_class)

    # Errors are 0..N small spans, rebuilt via map(); KeyedList overkill.
    errors_obs = map(results_obs) do results
        DOM.div(
            (DOM.div("Error: $(r["error"])"; class = "bt-error")
             for r in results if haskey(r, "error"))...;
            class = "bt-errors-list")
    end

    # Two-level rendering: one project group per cwd, each containing the
    # session/subagent rows from that project. Both levels use KeyedList
    # for stable identity across rescans — opening a group survives a
    # Refresh because the <details> DOM node is preserved when its key
    # (= path) is unchanged.
    #
    # Caches are pruned each tick to avoid unbounded growth if a project
    # disappears between scans (e.g. its on-disk jsonl was deleted).
    session_groups = Dict{String, SessionGroup}()
    session_rows   = Dict{String, SessionRow}()

    function get_session_row(r::AbstractDict)
        sr = SessionRow(c, r)
        get!(session_rows, sr.row_key, sr)
    end

    # `state.projects` is a dependency too: a chat rename pins a new title on the
    # matching project, and `resolve_session_title!` below reflects it onto the
    # discovered row (live, and across restarts since the title is persisted).
    groups_obs = map(results_obs, imported_sids, c.state.projects) do results, imported, projects
        by_path  = Dict{String, Vector{Any}}()
        latest_by_path = Dict{String, Float64}()
        for r in results
            haskey(r, "error") && continue
            # Subagents share their parent's process and aren't user-startable.
            # Surface only top-level sessions. A project whose only entries are
            # subagents (e.g. older Claude Code versions that didn't persist the
            # parent jsonl) drops out of the list entirely.
            String(get(r, "kind", "session")) == "subagent" && continue
            p = String(get(r, "path", ""))
            # Discover renders the worker's scan UNCONDITIONALLY — a session
            # that's already an open chat stays VISIBLE with an "in sidebar"
            # pill (hiding it made sessions look lost whenever sidebar state
            # and discover disagreed); clicking it reuses the existing thread
            # (`find_thread` dedup). The only drop — "project folder no longer
            # exists" — happens WORKER-side in `entry_from_jsonl` (the paths
            # live on the worker's disk; an `isdir` here on the server box
            # would wrongly drop every row of a remote worker).
            push!(get!(by_path, p, Any[]), r)
            ts = get(r, "last_used", 0.0)
            t = ts isa Number ? Float64(ts) : 0.0
            t > get(latest_by_path, p, 0.0) && (latest_by_path[p] = t)
        end
        out = SessionGroup[]
        seen_row_keys = Set{String}()
        for (p, rs) in by_path
            sort!(rs; by = r -> -Float64(get(r, "last_used", 0.0)))
            rows = SessionRow[get_session_row(r) for r in rs]
            for sr in rows
                resolve_session_title!(sr, projects)   # renamed title pins here too
                resolve_session_open!(sr, imported)    # "in sidebar" pill state
                push!(seen_row_keys, sr.row_key)
            end
            g = get!(session_groups, p) do
                SessionGroup(p, basename(p),
                             Observable(rows), Observable(""),
                             wid)
            end
            g.rows_obs[]    = rows
            g.summary_obs[] = group_summary_string(rs)
            push!(out, g)
        end
        # Prune stale cache entries (paths/rows no longer present).
        for k in collect(keys(session_groups))
            haskey(by_path, k) || delete!(session_groups, k)
        end
        for k in collect(keys(session_rows))
            k in seen_row_keys || delete!(session_rows, k)
        end
        sort!(out; by = g -> -get(latest_by_path, g.path, 0.0))
        return out
    end

    groups_keyed_list = KeyedList(groups_obs; key = g -> g.path)

    # The whole tree is now a collapsable `<details>` so the worker card stays
    # compact by default ("BOOM — opens the list on click"). Rescan inside the
    # summary preventDefaults the toggle and force-opens, so the user always
    # sees scan progress + refreshed results.
    panel = DOM.details(
        DOM.summary(
            DOM.span(title_obs; class = "bt-discover-title"),
            DOM.div(rescan_btn; class = "bt-discover-actions");
            class = "bt-discover-header"),
        spinner_block,
        empty_block,
        errors_obs,
        DOM.div(groups_keyed_list; class = "bt-discover-section");
        class = "bt-discover-panel")

    # One delegated click for the whole panel — every session row AND the
    # per-group "+ New thread" button share ONE listener (matched by the
    # `data-bt-action="session-pick"` attr) instead of N per-row onclick rebinds.
    # Installed as an inline `js"…"` CHILD (serialized with this subtree), and it
    # notifies the SESSION-LOCAL `pick` above — `$(pick)` resolves because it was
    # created in this render's session, unlike the old cross-session
    # `import_path` (see the `pick` comment).
    click_listener = js"""
        $(panel).addEventListener('click', (ev) => {
            const btn = ev.target.closest('[data-bt-action="session-pick"]');
            if (!btn) return;
            // Optimistic UI: the controller-side import is async, so flip the
            // label + dim immediately so the user sees the click landed. (The
            // "+ New thread" span has no Resume/Import label — leave its text.)
            btn.classList.add('bt-clicked');
            const t = btn.textContent.trim();
            if (t === 'Resume')      btn.textContent = 'Resuming…';
            else if (t === 'Import') btn.textContent = 'Importing…';
            $(pick).notify({
                path:       btn.dataset.btSessionPath || '',
                session_id: btn.dataset.btSessionId   || '',
                worker:     btn.dataset.btWorkerId    || '',
            });
        });
    """
    # `display: contents` so the wrapper is transparent to the card's layout.
    return DOM.div(panel, click_listener; style = Styles("display" => "contents"))
end
