# ── WorkerFileTree: a lazy, searchable project file tree for the sidebar ──────
# One per open chat (project). Two modes share one scroll body:
#
#   • Tree mode (search box empty): a VSCode-style expandable tree. Each
#     directory is fetched lazily over the worker `list_dir` RPC the first time
#     it's expanded; the rendered list is a FLAT set of rows (path, depth) so the
#     reactive update is a single `map` — no nested-DOM reconciliation.
#   • Search mode (search box non-empty): a flat, fuzzy-filtered view of the
#     project's file index (`ProjectFileIndex`, fetched once over
#     `list_project_files` and cached on the `ProjectInfo`).
#
# Clicking a file routes through `open_project_file!` (the same guarded path the
# chat link-clicks use), so a folder / binary / oversize file toasts instead of
# opening blank. The whole component is rendered through `jsrender`, so all of
# its Observables/listeners are scoped to the render's (sub)session and get
# cleaned up when the sidebar list re-renders.
#
# `active` is driven by the enclosing collapsible in the sidebar: the tree does
# NO worker I/O until it's first expanded (so collapsed chats cost nothing).

struct WorkerFileTree
    state::ServerState
    project_id::String
    pane::PlotPane
    active::Observable{Bool}     # flipped true by the sidebar on first expand

    # ── UI state, owned by the COMPONENT ────────────────────────────────────
    # These were locals of `jsrender`, which meant a fresh set every time the
    # sidebar re-rendered — and the sidebar re-renders on chat add/remove and on
    # project/worker changes, none of which have anything to do with this tree.
    # The consequences were all one bug: an open tree collapsed, its loaded
    # directories were forgotten, and a click landed on a row whose `clicked`
    # observable had died with the outgoing render, so expanding a folder or
    # opening a file silently did nothing.
    #
    # Held here, the tree keeps its identity across renders: still open, still
    # loaded, and a click always reaches a live observable.
    tick::Observable{Int}                 # bump → re-render the body
    search::Observable{String}
    clicked::Observable{String}           # "<dir?>\t<path>" from a row click
    expanded::Set{String}
    children::Dict{String,Any}            # dir abspath → sorted entries
    inflight::Set{String}                 # dirs whose list_dir RPC is running
    # Dirs whose listing failed → why. Not cached as an empty folder: a worker
    # that was offline or slow when the chat opened left its tree "empty" for
    # good (11-24, after a laptop's worker reconnected). Listed again on Retry and
    # when the worker comes back.
    failed::Dict{String,String}
    index_files::Ref{Vector{String}}
    index_ready::Ref{Bool}
    index_error::Ref{String}              # why the file index failed, "" if it didn't
    root_loaded::Ref{Bool}
end

WorkerFileTree(state::ServerState, project_id::AbstractString, pane::PlotPane) =
    WorkerFileTree(state, String(project_id), pane, Observable(false),
                   Observable(0), Observable(""), Observable(""),
                   Set{String}(), Dict{String,Any}(), Set{String}(), Dict{String,String}(),
                   Ref(String[]), Ref(false), Ref(""), Ref(false))

"""
    WorkerFileTree(prototype) -> WorkerFileTree

A FRESH component sharing `prototype`'s state. The sidebar keeps one prototype
per project and re-wraps it on every render.

Why not just render the prototype again: Bonito tracks the objects it has
rendered, and handing it the same one for a second, third, … render left it
operating on nodes the previous render had already detached — surfacing as an
unhandled `Cannot read properties of null (reading 'parentNode')` in the browser
(caught by `e2e:outdated_worker`, which asserts a clean JS console). A new
wrapper each render keeps Bonito's bookkeeping honest; sharing the fields is
what actually matters, since that is where "still open, still loaded, clicks
still land" lives.
"""
WorkerFileTree(t::WorkerFileTree) =
    WorkerFileTree(t.state, t.project_id, t.pane, t.active,
                   t.tick, t.search, t.clicked,
                   t.expanded, t.children, t.inflight, t.failed,
                   t.index_files, t.index_ready, t.index_error, t.root_loaded)

# What a failed listing shows. A worker that is away is named as the sidebar
# names it (the errors carry its id); anything else is the first line of the
# error: a timeout, the worker's own error ("permission denied").
function tree_failure(state::ServerState, worker_id::AbstractString, e)
    worker_connected(state, worker_id) || return "$(last(worker_label(state.workers[], worker_id))) is not connected"
    return String(first(split(sprint(showerror, e), '\n')))
end

# Cap on rendered search hits — keep the DOM small on a big index.
const FILE_TREE_SEARCH_LIMIT = 300

# Sort a directory's entries dirs-first, then case-insensitively by name —
# the conventional file-tree order (worker `readdir` is plain alphabetical).
function sort_tree_entries(entries)
    return sort(entries; by = e -> (e.dir ? 0 : 1, lowercase(e.name)))
end

# Flatten the currently-expanded tree into rows `(path, name, dir, depth)`,
# depth-first. `children[dir]` is the cached entry list for an expanded dir.
function tree_visible_rows(root::AbstractString,
                           expanded::AbstractSet{String},
                           children::AbstractDict{String,<:Any})
    rows = Tuple{String,String,Bool,Int}[]
    function walk(dir, depth)
        for e in get(children, dir, ())
            full = joinpath(dir, e.name)
            push!(rows, (full, e.name, e.dir, depth))
            (e.dir && full in expanded) && walk(full, depth + 1)
        end
    end
    walk(String(root), 0)
    return rows
end

# `subseq_match` (case-insensitive subsequence test, e.g. "lkcy" ⊆ "leak_cycle.jl")
# is shared with the lens search — defined in lens.jl, reused here.

# Rank `rel` against `query` like a fuzzy file-finder. Higher = better, `-1` =
# no match. The tiers matter: a query like "Makie.jl" must put the file actually
# NAMED Makie.jl above the dozens of paths that merely contain those letters as a
# scattered subsequence (the old behaviour returned the first 300 subsequence
# hits in alphabetical order, so an exact match buried late never showed).
#   exact basename  ≫  basename prefix  ≫  basename substring
#       ≫  path substring  ≫  basename subsequence  ≫  path subsequence
# Ties are broken by the caller (shorter/shallower path wins).
function score_match(query::AbstractString, rel::AbstractString)
    q  = lowercase(query)
    bl = lowercase(basename(rel))
    pl = lowercase(rel)
    bl == q              && return 1000
    startswith(bl, q)    && return 900
    occursin(q, bl)      && return 750
    occursin(q, pl)      && return 500
    subseq_match(q, bl)  && return 300
    subseq_match(q, pl)  && return 120
    return -1
end

function tree_dir_row(path, name, depth, is_open)
    DOM.div(
        DOM.span(is_open ? "▾" : "▸"; class = "bt-tree-arrow"),
        DOM.span(name; class = "bt-tree-label", title = name);
        class = "bt-tree-row bt-tree-dir",
        style = "padding-left:$(6 + depth * 12)px",
        dataPath = path, dataDir = "true")
end

# A folder that could not be listed: why, and a Retry that lists it again.
function tree_failed_row(path, why, depth)
    DOM.div(
        DOM.span("Couldn't list this folder: " * why; class = "bt-tree-failed-why", title = why),
        DOM.span("Retry"; class = "bt-tree-retry");
        class = "bt-tree-row bt-tree-failed",
        style = "padding-left:$(6 + depth * 12)px",
        dataPath = path, dataDir = "retry")
end

function tree_file_row(path, name, depth)
    DOM.div(
        DOM.span(""; class = "bt-tree-arrow"),
        DOM.span(name; class = "bt-tree-label", title = name),
        DOM.span("⤓"; class = "bt-tree-download", title = "Download to this computer");
        class = "bt-tree-row bt-tree-file",
        style = "padding-left:$(6 + depth * 12)px",
        dataPath = path, dataDir = "false")
end

# The containing dir as a search hit shows it: the LAST two segments, with a
# leading `…/` when anything was dropped.
#
# The head of the path is the part every hit shares — it is the tail that tells
# them apart — and in a 200px rail the head is also what eats the row. The full
# relative path is still on the row's `title`.
function search_dir_label(dir::AbstractString)
    isempty(dir) && return ""
    parts = splitpath(String(dir))
    length(parts) <= 2 && return dir
    return "…/" * join(parts[(end - 1):end], "/")
end

# A search hit: basename prominent, the containing dir muted after it.
function tree_search_row(worker_root, rel)
    full = joinpath(worker_root, rel)
    dir  = search_dir_label(dirname(rel))
    DOM.div(
        DOM.span(basename(rel); class = "bt-tree-label"),
        isempty(dir) ? DOM.span("") : DOM.span(dir; class = "bt-tree-relpath"),
        DOM.span("⤓"; class = "bt-tree-download", title = "Download to this computer");
        class = "bt-tree-row bt-tree-file",
        style = "padding-left:6px",
        dataPath = full, dataDir = "false", title = rel)
end

function Bonito.jsrender(session::Session, t::WorkerFileTree)
    proj = get(t.state.projects[], t.project_id, nothing)
    if proj === nothing
        return Bonito.jsrender(session,
            DOM.div("project unavailable"; class = "bt-tree-empty"))
    end
    worker_root = proj.worker_path
    server_cwd  = proj.server_path
    worker_id   = proj.worker_id

    # UI state lives on the component (see `WorkerFileTree`), so everything
    # below survives a sidebar re-render.
    expanded    = t.expanded
    children    = t.children
    inflight    = t.inflight
    failed      = t.failed
    index_files = t.index_files
    index_ready = t.index_ready
    index_error = t.index_error
    root_loaded = t.root_loaded

    tick    = t.tick
    search  = t.search
    clicked = t.clicked
    bump() = (tick[] = tick[] + 1)

    # Only an expand, a Retry, activation or a reconnect lists a dir, never a
    # render, so a failure that is not cached cannot loop.
    fetch_dir!(dir) = begin
        (haskey(children, dir) || dir in inflight) && return
        delete!(failed, dir)
        push!(inflight, dir)
        Base.errormonitor(@async begin
            try
                res = list_worker_dir(t.state, worker_id, dir)
                children[dir] = sort_tree_entries(res.entries)
            catch e
                @warn "file tree: list_dir failed" dir exception = e
                failed[dir] = tree_failure(t.state, worker_id, e)
            finally
                delete!(inflight, dir)
                bump()
            end
        end)
        return
    end

    load_index!() = begin
        index_ready[] && return
        index_error[] = ""
        Base.errormonitor(@async begin
            try
                task = ensure_project_file_index!(t.state, proj)
                task === nothing || wait(task)
                index_files[] = project_index_files(proj)
                index_ready[] = true
            catch e
                # Not "ready": a search would answer "no matches" for good.
                @warn "file tree: index load failed" project = t.project_id exception = e
                index_error[] = tree_failure(t.state, worker_id, e)
            finally
                bump()
            end
        end)
        return
    end

    # The worker is back: list again what failed while it was away.
    worker = get(t.state.workers[], worker_id, nothing)
    worker === nothing || on(session, worker.online) do online
        online || return
        foreach(fetch_dir!, collect(keys(failed)))
        isempty(index_error[]) || load_index!()
    end

    activate!() = begin
        root_loaded[] && return
        root_loaded[] = true
        fetch_dir!(worker_root)
        load_index!()
    end
    # Load on first expand; if the sidebar opened us already, load now.
    on(session, t.active) do active_now
        active_now && activate!()
    end
    t.active[] && activate!()

    on(session, clicked) do payload
        isempty(payload) && return
        parts = split(payload, '\t'; limit = 2)
        length(parts) == 2 || return
        kind = parts[1]
        path = String(parts[2])
        isempty(path) && return
        if kind == "retry"
            fetch_dir!(path)
            bump()
        elseif kind == "retry-index"
            load_index!()
            bump()
        elseif kind == "true"
            if path in expanded
                delete!(expanded, path)
            else
                push!(expanded, path)
                fetch_dir!(path)
            end
            bump()
        else
            open_project_file!(t.pane, t.state, t.project_id, server_cwd, path)
        end
    end


    # First search keystroke pulls the index (if the tree was never expanded).
    on(session, search) do q
        isempty(strip(q)) || index_ready[] || load_index!()
        bump()
    end

    body = map(session, tick, search) do _, q
        query = strip(String(q))
        if !isempty(query)
            if !index_ready[]
                isempty(index_error[]) && return DOM.div("indexing…"; class = "bt-tree-empty")
                return DOM.div(DOM.div(
                        DOM.span("Couldn't index the files: " * index_error[];
                                 class = "bt-tree-failed-why", title = index_error[]),
                        DOM.span("Retry"; class = "bt-tree-retry");
                        class = "bt-tree-row bt-tree-failed", style = "padding-left:6px",
                        dataPath = worker_root, dataDir = "retry-index"); class = "bt-tree-rows")
            end
            # Score EVERY file, then rank — never truncate before ranking, or an
            # exact match that sorts late alphabetically gets cut. Tie-break by
            # path length so the shallowest exact match wins.
            scored = Tuple{Int,String}[]
            for rel in index_files[]
                s = score_match(query, rel)
                s >= 0 && push!(scored, (s, rel))
            end
            isempty(scored) && return DOM.div("no matches"; class = "bt-tree-empty")
            sort!(scored; by = t -> (-t[1], length(t[2]), t[2]))
            n = min(length(scored), FILE_TREE_SEARCH_LIMIT)
            return DOM.div((tree_search_row(worker_root, scored[i][2]) for i in 1:n);
                           class = "bt-tree-rows")
        end
        # Tree mode.
        if !root_loaded[] || (!haskey(children, worker_root) && worker_root in inflight)
            return DOM.div("loading…"; class = "bt-tree-empty")
        end
        if haskey(failed, worker_root)
            return DOM.div(tree_failed_row(worker_root, failed[worker_root], 0); class = "bt-tree-rows")
        end
        rows = tree_visible_rows(worker_root, expanded, children)
        isempty(rows) && return DOM.div("empty"; class = "bt-tree-empty")
        nodes = Any[]
        for (path, name, isdir, depth) in rows
            push!(nodes, isdir ? tree_dir_row(path, name, depth, path in expanded) :
                                  tree_file_row(path, name, depth))
            isdir && path in expanded && haskey(failed, path) &&
                push!(nodes, tree_failed_row(path, failed[path], depth + 1))
        end
        DOM.div(nodes; class = "bt-tree-rows")
    end

    search_box = DOM.input(;
        type = "text", placeholder = "Search files…",
        class = "bt-tree-search", spellcheck = "false",
        oninput = js"""event => {
            const v = event.target.value;
            if (event.target.__btT) clearTimeout(event.target.__btT);
            event.target.__btT = setTimeout(() => $(search).notify(v), 120);
        }""")

    root_node = DOM.div(search_box, DOM.div(body; class = "bt-tree-scroll");
                        class = "bt-tree")
    # One delegated click listener. `stopPropagation` keeps tree clicks from
    # bubbling to the sidebar's aside handler (which would navigate current_view).
    Bonito.onload(session, root_node, js"""(root) => {
        const pid = $(t.project_id);
        root.addEventListener('click', e => {
            e.stopPropagation();
            const row = e.target.closest('.bt-tree-row');
            if (!row) return;
            // The ⤓ download affordance takes precedence over opening the file:
            // hit the server's /download route, which streams the worker file
            // back as an attachment (Content-Disposition). No eval bridge needed.
            if (e.target.closest('.bt-tree-download')) {
                const url = '/download/' + encodeURIComponent(pid) +
                            '?path=' + encodeURIComponent(row.dataset.path || '');
                const a = document.createElement('a');
                a.href = url; a.download = '';
                document.body.appendChild(a); a.click(); a.remove();
                return;
            }
            $(clicked).notify((row.dataset.dir || 'false') + '\t' + (row.dataset.path || ''));
        });
    }""")
    return Bonito.jsrender(session, root_node)
end
