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
end

WorkerFileTree(state::ServerState, project_id::AbstractString, pane::PlotPane) =
    WorkerFileTree(state, String(project_id), pane, Observable(false))

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

function tree_file_row(path, name, depth)
    DOM.div(
        DOM.span(""; class = "bt-tree-arrow"),
        DOM.span(name; class = "bt-tree-label", title = name),
        DOM.span("⤓"; class = "bt-tree-download", title = "Download to this computer");
        class = "bt-tree-row bt-tree-file",
        style = "padding-left:$(6 + depth * 12)px",
        dataPath = path, dataDir = "false")
end

# A search hit: basename prominent, the containing dir muted after it.
function tree_search_row(worker_root, rel)
    full = joinpath(worker_root, rel)
    dir  = dirname(rel)
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

    # Session-local UI state (plain locals — one consumer, this session).
    expanded    = Set{String}()
    children    = Dict{String,Any}()      # dir abspath → sorted entries
    inflight    = Set{String}()           # dirs whose list_dir RPC is running
    index_files = Ref(String[])
    index_ready = Ref(false)
    root_loaded = Ref(false)

    tick   = Observable(0)                 # bump → re-render the body
    search = Observable("")                # search box text
    clicked = Observable("")               # "<dir?>\t<path>" from a row click
    bump() = (tick[] = tick[] + 1)

    fetch_dir!(dir) = begin
        (haskey(children, dir) || dir in inflight) && return
        push!(inflight, dir)
        Base.errormonitor(@async begin
            try
                res = list_worker_dir(t.state, worker_id, dir)
                children[dir] = sort_tree_entries(res.entries)
            catch e
                @warn "file tree: list_dir failed" dir exception = e
                children[dir] = []           # cache the failure so we don't loop
            finally
                delete!(inflight, dir)
                bump()
            end
        end)
        return
    end

    load_index!() = begin
        index_ready[] && return
        Base.errormonitor(@async begin
            try
                task = ensure_project_file_index!(t.state, proj)
                task === nothing || wait(task)
                index_files[] = project_index_files(proj)
            catch e
                @warn "file tree: index load failed" project = t.project_id exception = e
            finally
                index_ready[] = true
                bump()
            end
        end)
        return
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
        is_dir = parts[1] == "true"
        path   = String(parts[2])
        isempty(path) && return
        if is_dir
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
                return DOM.div("indexing…"; class = "bt-tree-empty")
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
            return DOM.div((tree_search_row(worker_root, scored[i][2]) for i in 1:n)...;
                           class = "bt-tree-rows")
        end
        # Tree mode.
        if !root_loaded[] || (!haskey(children, worker_root) && worker_root in inflight)
            return DOM.div("loading…"; class = "bt-tree-empty")
        end
        rows = tree_visible_rows(worker_root, expanded, children)
        isempty(rows) && return DOM.div("empty"; class = "bt-tree-empty")
        nodes = Any[]
        for (path, name, isdir, depth) in rows
            push!(nodes, isdir ? tree_dir_row(path, name, depth, path in expanded) :
                                  tree_file_row(path, name, depth))
        end
        DOM.div(nodes...; class = "bt-tree-rows")
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
