# KeyedList-friendly widget for one project row. Held stable per
# project_id in dashboard_dom's `project_cards` Dict; reactive bits
# read from `state.projects` / `state.workers` so worker churn or a
# sync starting on one project doesn't touch the others' DOM.

mutable struct ProjectCard
    state         :: ServerState
    project_id    :: String
    error_obs     :: Observable{String}
    sync_request  :: Observable{String}                # notified with project_id on Sync click
    open_request  :: Observable{Dict{String,Any}}      # notified with {project, worker} on Open click
    current_view  :: Union{Observable{String},Nothing} # nothing → no in-app navigation
end

Base.hash(c::ProjectCard, h::UInt) = hash(c.project_id, hash(:ProjectCard, h))
Base.:(==)(a::ProjectCard, b::ProjectCard) = a.project_id == b.project_id

function Bonito.jsrender(session::Bonito.Session, c::ProjectCard)
    state, pid = c.state, c.project_id

    project_obs = map(session, state.projects) do projects
        get(projects, pid, nothing)
    end

    # Editable title — `[WW] <title>` shown in the card heading. The user can
    # click to edit; the auto-backfill in `send_message!` fills it from the
    # first meaningful prompt if it's still nothing.
    initial_title = let p0 = get(state.projects[], pid, nothing)
        p0 === nothing ? "" : project_display_title(p0)
    end
    title_obs = Observable(initial_title)
    on(session, title_obs) do v
        new = strip(String(v))
        haskey(state.projects[], pid) || return
        cur = project_display_title(state.projects[][pid])
        # Empty string clears to fallback (p.name); same value is a no-op.
        new == cur && return
        try
            set_project_title!(state, pid, new)
            title_obs[] = project_display_title(state.projects[][pid])
            c.error_obs[] = ""
        catch e
            c.error_obs[] = "Title update failed: $(sprint(showerror, e))"
            title_obs[] = cur
        end
    end
    title_input = DOM.input(
        type  = "text",
        value = title_obs,
        class = "bt-card-name bt-card-name-edit bt-card-title-input",
        title = "Click to rename this chat — Enter to save, Esc to cancel. Empty = fall back to folder name.",
        onblur    = js"event => $(title_obs).notify(event.target.value)",
        onkeydown = js"""event => {
            if (event.key === 'Enter')  { event.target.blur(); }
            if (event.key === 'Escape') {
                event.target.value = event.target.defaultValue;
                event.target.blur();
            }
        }""")

    # Card body is a single map over project + workers; project-level
    # updates are infrequent so rebuilding the inner DOM each notify is fine.
    body = map(project_obs, state.workers) do p, workers
        # Project removed (KeyedList is about to detach us) — render empty.
        p === nothing && return DOM.div()
        # Keep `title_obs` in sync if the project's title changed elsewhere
        # (auto-backfill in send_message!, another tab's edit, etc.).
        let canon = project_display_title(p)
            title_obs[] == canon || (title_obs[] = canon)
        end
        worker_tag = haskey(workers, p.worker_id) ?
                        worker_initials(workers[p.worker_id]) :
                        derive_initials(p.worker_id)
        tag = DOM.span("[$(worker_tag)]";
                       class = "bt-card-worker-tag",
                       title = haskey(workers, p.worker_id) ?
                               "Lives on $(workers[p.worker_id].name)" :
                               "Lives on worker $(p.worker_id)")
        badge = p.locked_by === nothing ? DOM.span() :
            DOM.span("active";
                     class = "bt-pill bt-pill-active",
                     style = Styles("margin-left" => "6px"),
                     title = "active session on $(p.locked_by)")

        online_workers = [w for w in values(workers) if isopen(w)]
        open_link = if c.current_view === nothing || isempty(online_workers)
            DOM.span("(no chat available)";
                class = "bt-link", style = Styles("color" => "var(--bt-text-muted)"))
        else
            worker_select = DOM.select(
                (DOM.option(w.name; value = w.worker_id,
                            selected = (w.worker_id == p.worker_id))
                 for w in online_workers)...;
                class = "bt-open-on-select",
                onclick = js"event => event.stopPropagation()")
            DOM.div(
                DOM.span("Open chat on "; class = "bt-open-on-label"),
                worker_select;
                class   = "bt-link bt-open-on",
                style   = Styles("cursor" => "pointer"),
                onclick = js"""event => {
                    const sel = event.currentTarget.querySelector('select');
                    $(c.open_request).notify({project: $(p.id), worker: sel.value});
                }""")
        end

        sync_btn = if p.backup_status === :syncing
            DOM.span()
        else
            label = p.backup_status === :synced ? "Re-sync" : "Sync to server"
            DOM.span(label;
                class   = "bt-btn bt-btn-secondary bt-btn-sm",
                style   = Styles("cursor" => "pointer", "margin-right" => "8px"),
                onclick = js"""event => {
                    const btn = event.currentTarget;
                    btn.classList.add('bt-clicked');
                    btn.textContent = 'Syncing…';
                    $(c.sync_request).notify($(p.id));
                }""")
        end

        # The folder name as a meta line — when an explicit title is set the
        # original folder name still lives here so the user doesn't lose track
        # of which directory the chat is bound to.
        worker_label = haskey(workers, p.worker_id) ?
                        workers[p.worker_id].name :
                        "worker:$(first(p.worker_id, 8))"
        folder_line = DOM.span(p.name; class = "bt-card-folder-name",
                               title = "folder: $(p.name)")

        DOM.div(
            DOM.div(
                DOM.div(tag, title_input, badge, backup_pill(p);
                        class = "bt-card-title"),
                DOM.div(
                    folder_line,
                    DOM.span("·"; class = "bt-stat-sep"),
                    DOM.span(worker_label),
                    DOM.span("·"; class = "bt-stat-sep"),
                    DOM.span(p.worker_path; class = "bt-mono",
                             title = "server: $(p.server_path)\nworker: $(p.worker_path)");
                    class = "bt-card-meta");
                class = "bt-card-body"),
            DOM.div(sync_btn, open_link;
                    class = "bt-card-actions"),
            class = "bt-card")
    end

    return Bonito.jsrender(session, DOM.div(body; class = "bt-project-cell"))
end
