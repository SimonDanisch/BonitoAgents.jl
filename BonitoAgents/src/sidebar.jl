# Left-edge nav strip shared by the unified app's main panel — one entry
# per project plus a "home" icon. Each entry click flips `current_view`
# (Observable{String}); the App's main panel reactively swaps to either
# the dashboard (current_view == "") or that project's chat.
#
# Icons are auto-generated: initials from the project name, background
# colour deterministically derived from the project id (so the same
# project always gets the same colour across reloads).

"""
    project_initials(name) → String

Two uppercase characters that sum up `name` for a 32-px icon. Splits on
whitespace / dash / dot / underscore / slash; if there are two or more
"words", takes the first letter of each of the first two; otherwise
takes the first two letters of the only word.
"""
function project_initials(name::AbstractString)
    s = strip(name)
    isempty(s) && return "?"
    parts = split(s, r"[\s\-_/.]+"; keepempty = false)
    isempty(parts) && return "?"
    if length(parts) >= 2
        return uppercase(string(first(parts[1]), first(parts[2])))
    end
    word = parts[1]
    return uppercase(length(word) >= 2 ? String(word[1:2]) : String(word))
end

"""
    project_color(id) → String

A CSS `hsl(...)` value seeded by `id`. Saturation/lightness are fixed so
every icon looks balanced; only hue varies. Same id → same colour.
"""
function project_color(id::AbstractString)
    hue = abs(hash(id) % 360)
    return "hsl($(hue), 60%, 48%)"
end

"""
    identicon_svg(id) → String

A GitHub-style 5×5 identicon as an inline SVG string, deterministically
seeded by `id`. The left half of the grid comes from the id's hash bits and
is mirrored, so every icon is symmetric (symmetric shapes read as "a thing"
rather than noise). Pattern cells are a darker shade of the same hue as
`project_color(id)`, so the icon stays one coherent tile that the worker
initials remain legible on. Single-quoted attributes so the result embeds
directly into a CSS `url("data:image/svg+xml;utf8,…")` (the same trick the
model-picker arrow uses in styles.jl).
"""
function identicon_svg(id::AbstractString)
    h   = hash(id)
    hue = abs(h % 360)
    cells = IOBuffer()
    for row in 0:4, col in 0:2
        ((h >> (row * 3 + col)) & 1) == 1 || continue
        for c in (col == 2 ? (2,) : (col, 4 - col))
            print(cells, "<rect x='", c * 2, "' y='", row * 2, "' width='2' height='2'/>")
        end
    end
    return string(
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'>",
        "<rect width='10' height='10' fill='hsl(", hue, ", 60%, 48%)'/>",
        "<g fill='hsl(", hue, ", 65%, 38%)'>", String(take!(cells)), "</g></svg>")
end

# Renders one icon: an identicon tile seeded by `p.id` (the pattern + hue
# make each chat recognisable at a glance) with the worker's initials on
# top (`[DT]`-style — Desktop/HP Laptop/…) so the user also reads which
# machine hosts the chat. Pass `worker_tag = ""` to fall back to the folder
# initials (used when a worker isn't connected). `size_px` lets the sidebar
# reuse this at 32 px and the project_card at e.g. 24 px.
function project_icon(p::ProjectInfo, worker_tag::AbstractString = "";
                       size_px::Int = 32)
    label = isempty(worker_tag) ? project_initials(p.name) : String(worker_tag)
    tip   = isempty(worker_tag) ? p.name : "$(worker_tag) · $(p.name)"
    DOM.div(label;
        class = "bt-proj-icon",
        style = string("background-image:url(\"data:image/svg+xml;utf8,",
                       identicon_svg(p.id), "\");",
                       "background-size:cover;",
                       "width:$(size_px)px;height:$(size_px)px;",
                       "line-height:$(size_px)px;font-size:$(round(Int, size_px*0.42))px"),
        title = tip)
end

# A single sidebar row: icon + label + identifying data-attribute. NO
# Observables interpolated in here — the click handler and the
# active-highlight class swap are delegated from the outer `<aside>`,
# so this DOM can be recycled by the structural `map(state.projects)`
# below without churning any tracked Observable IDs.
function sidebar_entry(label::AbstractString, icon::Bonito.Node,
                        target_value::AbstractString, title::AbstractString;
                        active::Bool = false, closeable::Bool = false,
                        extra_class::AbstractString = "",
                        status::Union{Symbol,Nothing} = nothing)
    # The icon now carries the worker initials (project_icon does the
    # styling); the title span only needs the chat title text.
    # Status LED (green pulse / yellow / red) nestled as a presence badge on the
    # icon's bottom-right corner (anchored to the icon, so it stays put whether
    # the rail is expanded or collapsed to icons). `data-status` lets the CSS
    # pick the colour + animation; the 1Hz `recompute_status_dom!` JS updates the
    # attr in place. Home entry has no LED (status === nothing).
    icon_node = if status === nothing
        icon
    else
        DOM.div(icon,
                DOM.span(""; class = "bt-side-led", title = string(status),
                         dataStatus = string(status));
                class = "bt-side-icon-wrap")
    end
    kids = Any[icon_node, DOM.span(label; class = "bt-side-name")]
    # A ✕ to close (stop) an active chat. Plain markup — the delegated
    # handler on the aside reads `.bt-side-close` and routes to close_trigger
    # rather than current_view, so no per-entry Observable is interpolated
    # into the recyclable body.
    closeable && push!(kids, DOM.span("✕"; class = "bt-side-close", title = "Close chat"))
    cls = "bt-side-item" * (active ? " bt-side-active" : "")
    isempty(extra_class) || (cls = cls * " " * String(extra_class))
    DOM.div(kids...;
        class = cls,
        title = title,
        # `data-project-id` is the empty string for "Home" (the dashboard
        # entry) and the project id for everything else. The delegated
        # click handler reads this to know which view to switch to.
        dataProjectId = target_value)
end

"""
    open_chat_projects(projects) -> Vector{ProjectInfo}

The persistent half of the sidebar's "Open chats" list. A project counts as
"open" iff the user has interacted with it at least once — i.e. it has
either a backfilled `title` (set on the first user message) or a
`resume_session_id` (imported from claude-agent-acp). This is the
persistent definition: surviving a server OR worker restart, because both
markers live on disk in `projects.json` and are restored on boot. The
`discovered.json` scan cache is deliberately NOT consulted (stale by
definition between rescans).
"""
function open_chat_projects(projects::AbstractDict{<:AbstractString,ProjectInfo})
    out = ProjectInfo[]
    for (_, p) in projects
        chat_in_sidebar(p) || continue
        push!(out, p)
    end
    return out
end

"""
    open_chat_projects(state, projects) -> Vector{ProjectInfo}

What the sidebar actually renders: the persisted-interacted projects PLUS
every project with a LIVE `ChatModel`. A running chat deserves a sidebar
entry from the moment it's brought up — before its first message backfills
a title, a fresh thread was otherwise reachable only through the dashboard.
"""
function open_chat_projects(state::ServerState,
                            projects::AbstractDict{<:AbstractString,ProjectInfo})
    out  = open_chat_projects(projects)
    have = Set(p.id for p in out)
    live = lock(state.lock) do
        collect(keys(state.chat_models))
    end
    for id in live
        id in have && continue
        p = get(projects, id, nothing)
        # A dismissed chat that still has a live model (the ✕ tears the model
        # down, so this is only a brief race) must not be re-added by the
        # live-model path — honour the close.
        (p === nothing || p.dismissed) && continue
        push!(out, p)
    end
    return out
end

"""
    chat_status(state, p) -> Symbol

One of `:active`, `:online`, `:offline` — the sidebar LED state.

  * `:offline`  — worker entry is missing OR its status isn't `:online`.
                  Nothing the agent can do until the worker reconnects.
  * `:online`   — worker is up but no agent turn is in flight. Covers both
                  "ChatModel exists, sitting idle" and "no ChatModel yet,
                  needs a session/load resume on click".
  * `:active`   — ChatModel exists AND `busy_active` is true (a prompt is
                  in flight: claude is thinking or streaming).
"""
function chat_status(state::ServerState, p::ProjectInfo)
    w = get(state.workers[], p.worker_id, nothing)
    (w === nothing || !isopen(w)) && return :offline
    m = lock(state.lock) do; get(state.chat_models, p.id, nothing); end
    m === nothing && return :online
    return m.busy_active[] ? :active : :online
end

# Per-PROCESS boot id scoping the sidebar's localStorage last-route memory:
# a route saved by one server process must not navigate a fresh one. Lazy
# (Ref filled on first use) — a `const x = uuid4()` would be baked into the
# precompile image and shared by every process.
const SERVER_BOOT_ID = Ref("")
function server_boot_id()
    isempty(SERVER_BOOT_ID[]) && (SERVER_BOOT_ID[] = string(uuid4())[1:8])
    return SERVER_BOOT_ID[]
end

"""
    project_sidebar(session, state, current_view) → DOM

Always-visible vertical nav. Top entry is "Home" (dashboard view); below
it, one entry per registered project.

The body re-renders ONLY when `state.projects` changes (project add /
remove / rename). Worker churn doesn't touch this section, so connecting
a new laptop or a worker going offline does not trigger any sidebar
work. Navigation (`current_view` change) does NOT
trigger a re-render: the click handler is delegated on the outer
`<aside>` via `onload`, and active-highlighting is handled by an `onjs`
class swap on the existing DOM. This matters because every re-render
tears down the body subsession, and any Observable interpolated into
that subsession's DOM gets caught in a tracked-object refcount race
with the new subsession (Bonito Sessions.js GLOBAL_OBJECT_CACHE). By
keeping `current_view` only on the OUTER aside (parent session, never
torn down), it crosses the JS bridge once at initial render and stays
in cache forever.
"""
function project_sidebar(session::Bonito.Session, state::ServerState,
                          current_view::Observable{String},
                          pane::Union{Nothing,PlotPane} = nothing)
    # The home glyph isn't a project — it's nav. Renders as a borderless
    # 32px slot so it visually reads as "go home" instead of competing
    # with the colored project tiles below it.
    home_icon = DOM.div(
        DOM.img(src = bonito_asset("icons", "home.svg"), alt = "Home", draggable = "false",
                style = Styles("width" => "18px", "height" => "18px",
                               "display" => "block", "pointer-events" => "none"));
        class = "bt-side-home-icon",
        title = "Dashboard")

    # Closing an active chat from the sidebar: tear its session down and, if it
    # was the one on screen, fall back to the dashboard. Interpolated once on
    # the aside's onload (below), never into the recyclable body.
    close_trigger = Observable("")
    on(session, close_trigger) do pid
        isempty(pid) && return
        p = get(state.projects[], pid, nothing)
        p === nothing && return
        # Mark the chat closed FIRST so it drops out of the "Open chats" list the
        # moment `notify_chats!` / `state.projects` fans out — `dismissed` is what
        # makes the ✕ actually remove the entry (a titled / session-bound chat is
        # otherwise persistently "open"). Persisted so the close survives a
        # restart; reopening from the dashboard clears it (bring_up_project_session!).
        p.dismissed = true
        lock(state.lock) do; save_projects!(state); end
        safe_notify!(state.projects)
        # Flip the view away FIRST, then tear the session down off the event
        # task (T21). `stop_session!` closes the transport (network I/O) and the
        # ChatModel, which can block for seconds — running it inline froze the
        # tab's UI. The view change is what the user sees immediately.
        current_view[] == pid && (current_view[] = "")
        @async begin
            try
                stop_session!(state, p)
            catch e
                @warn "sidebar: closing chat failed" project = p.name exception = (e, catch_backtrace())
            end
        end
    end

    # ONE unified "Open chats" list. A project is "open" iff the user has
    # touched it before — `title` backfilled or `resume_session_id` set
    # (both persist in projects.json, so the list survives a server OR
    # worker restart). The per-entry LED encodes liveness:
    #   green pulse — agent turn in flight (busy_active true) = "working"
    #   green       — worker online, idle (live ChatModel OR resumable)
    #   red         — worker offline / missing
    # Re-renders on structural change (`chat_signal` for chat add/remove,
    # `state.projects` for project add/remove, `state.workers` for worker
    # online/offline transitions). The LED color is recomputed every second
    # by `recompute_status_dom!` on the OUTER aside (below) so a busy_active
    # flip mid-turn doesn't require a body re-render.
    body = map(state.chat_signal, state.projects, state.workers) do _, projects, workers
        active_pid = current_view[]
        open_projs = open_chat_projects(state, projects)
        sort!(open_projs; by = p -> lowercase(p.name))

        entries = Any[sidebar_entry("Home", home_icon, "", "Dashboard";
                                    active = active_pid == "")]
        # New label format: `[WW] <title>` where WW is the worker's editable
        # initials and title is the (possibly auto-backfilled) chat title.
        # The `[WW]` lives in its own span so the title can ellipsize / wrap
        # over two lines without breaking the tag. Two siblings of the same
        # folder still need a tail thread-tag to disambiguate when their
        # titles coincide.
        wtag(p) = haskey(workers, p.worker_id) ?
                    worker_initials(workers[p.worker_id]) :
                    derive_initials(p.worker_id)
        base(p) = project_display_title(p)
        base_counts = Dict{String,Int}()
        for p in open_projs; base_counts[base(p)] = get(base_counts, base(p), 0) + 1; end
        for p in open_projs
            t = wtag(p)
            b = base(p)
            label = base_counts[b] > 1 ? "$b · $(thread_tag(p))" : b
            st = chat_status(state, p)
            tooltip = "[$t] $label · folder: $(p.name) · $(st)"
            if pane === nothing
                push!(entries,
                      sidebar_entry(label, project_icon(p, t), p.id, tooltip;
                                    active = active_pid == p.id, closeable = true,
                                    status = st))
                continue
            end
            # Per-chat file tree (collapsed by default). The affordance is a
            # subtle chevron at the BOTTOM of the pill — NOT a leading arrow,
            # which ate the title's width and forced it to wrap. Clicking it
            # opens the tree INSIDE the pill (so it visibly belongs to the chat)
            # and, on first open, flips `tree.active` for the lazy worker scan.
            # stopPropagation keeps the click off the row's navigate handler.
            tree = WorkerFileTree(state, p.id, pane)
            hint = DOM.div("▾ files";
                class = "bt-side-tree-hint", title = "Show project files",
                onclick = js"""event => {
                    event.stopPropagation();
                    const chat = event.currentTarget.closest('.bt-side-chat');
                    if (!chat) return;
                    const open = chat.classList.toggle('bt-tree-open');
                    event.currentTarget.textContent = open ? '▴ hide files' : '▾ files';
                    event.currentTarget.title = open ? 'Hide project files' : 'Show project files';
                    if (open) $(tree.active).notify(true);
                }""")
            item = sidebar_entry(label, project_icon(p, t), p.id, tooltip;
                                 active = active_pid == p.id, closeable = true,
                                 status = st)
            push!(entries,
                  DOM.div(
                      # `hint` lives INSIDE the row wrapper (not the outer chat
                      # box) so its absolute bottom-right anchor is the ROW —
                      # it stays put when the tree expands below it.
                      DOM.div(item, hint; class = "bt-side-chat-row"),
                      DOM.div(tree; class = "bt-side-tree-wrap");
                      class = "bt-side-chat"))
        end
        isempty(open_projs) && push!(entries,
            DOM.div("No open chats yet — open one from the dashboard.";
                    class = "bt-side-empty"))
        DOM.div(entries...; class = "bt-side-list")
    end

    # VSCode-style collapse toggle: shrinks the sidebar to an icons-only rail
    # (more room for the workspace). State persists in localStorage and is
    # restored on the aside's onload below. Pure-JS toggle — no server hop.
    panel_icon = Bonito.SVG.svg(
        Bonito.SVG.rect(x = "2.5", y = "3", width = "11", height = "10", rx = "1.5"),
        Bonito.SVG.line(x1 = "6.5", y1 = "3", x2 = "6.5", y2 = "13");
        viewBox = "0 0 16 16", width = "16", height = "16", fill = "none",
        stroke = "currentColor", var"stroke-width" = "1.4",
        var"stroke-linecap" = "round", var"stroke-linejoin" = "round",
        var"aria-hidden" = "true")
    collapse_btn = DOM.button(
        panel_icon;
        class = "bt-side-collapse", title = "Toggle sidebar (Ctrl/⌘+B)",
        onclick = js"""event => {
            const aside = event.currentTarget.closest('.bt-sidebar');
            const collapsed = aside.classList.toggle('bt-collapsed');
            try { localStorage.setItem('bt-sidebar-collapsed', collapsed ? '1' : '0'); } catch (_) {}
        }""")
    header = DOM.div(collapse_btn; class = "bt-side-header")

    aside = DOM.aside(header, body; class = "bt-sidebar", dataBootId = server_boot_id())

    # Delegated click handler: one listener on the aside. A click on a
    # `.bt-side-close` ✕ routes to `close_trigger`; anything else on a
    # `.bt-side-item` switches `current_view`. Both Observables enter the JS
    # object cache here exactly once and never get re-tracked by a recycling
    # subsession.
    #
    # Last-route memory: complements Bonito's soft_close session reconnect
    # (which preserves Observable state for an hour, set in `serve()`). When
    # that timeout DOES lapse, or the user opens a fresh tab, this onload
    # restores `current_view` from localStorage so you still land on your last
    # chat instead of getting bounced to home. We only restore IF the entry
    # for that pid exists (worker still has the project) — otherwise fall
    # back to home so a deleted project doesn't strand the user on an empty view.
    #
    # The saved value is SCOPED to this server boot ("<boot>|<pid>"): a value
    # written by a previous server process must not navigate a fresh one (its
    # chats need a fresh bring-up anyway, and on a shared origin — test runs,
    # dev servers reusing a port — the stale pid could coincidentally match an
    # unrelated project of the same name).
    Bonito.onload(session, aside, js"""(el) => {
        const LAST_PID_KEY = 'bt-last-pid';
        const boot = el.dataset.bootId || '';
        el.addEventListener('click', e => {
            const close = e.target.closest('.bt-side-close');
            if (close) {
                e.stopPropagation();
                const item = close.closest('.bt-side-item');
                if (item) $(close_trigger).notify(item.dataset.projectId || '');
                return;
            }
            const item = e.target.closest('.bt-side-item');
            if (item) $(current_view).notify(item.dataset.projectId || '');
        });
        // Restore the collapsed/expanded sidebar state from a previous visit.
        try { if ((localStorage.getItem('bt-sidebar-collapsed') || '0') === '1') el.classList.add('bt-collapsed'); } catch (_) {}
        // Restore last route on fresh sessions (when soft_close didn't catch us).
        const saved = localStorage.getItem(LAST_PID_KEY) || '';
        const sep = saved.indexOf('|');
        if (sep > 0 && saved.slice(0, sep) === boot) {
            const pid = saved.slice(sep + 1);
            // Only restore if that sidebar entry exists right now — projects can
            // be deleted while you're away, and we don't want to navigate to a
            // dangling pid (the loading view would show an error).
            const entry = el.querySelector('.bt-side-item[data-project-id="' + pid.replace(/"/g, '') + '"]');
            if (entry) $(current_view).notify(pid);
        }
    }""")

    # Active-highlight swap: when current_view changes, find every
    # sidebar item, toggle .bt-side-active based on data-project-id
    # match. No DOM replacement, no subsession recycling. Also persists the
    # current pid to localStorage (boot-scoped, see above) so a hard
    # reconnect (past soft_close window OR a fresh tab) can restore it via
    # the onload above.
    Bonito.onjs(session, current_view, js"""(pid) => {
        document.querySelectorAll('.bt-sidebar .bt-side-item').forEach(el => {
            el.classList.toggle('bt-side-active', el.dataset.projectId === pid);
        });
        try {
            const aside = document.querySelector('.bt-sidebar');
            const boot = aside ? (aside.dataset.bootId || '') : '';
            localStorage.setItem('bt-last-pid', boot + '|' + (pid || ''));
        } catch (e) {}
    }""")

    # ── Per-entry LED status updates (no body re-render, no polling) ────────
    # `chat_status` is computed server-side and pushed as a `pid → status`
    # map. The JS handler reads `.bt-side-led` elements by `data-project-id`
    # and swaps the `data-status` attr in place. Pure attribute update —
    # never touches Observable refcounts in the body subsession, so the
    # GLOBAL_OBJECT_CACHE notes at the top still hold.
    #
    # Triggers: any state change that can flip a chat's status fires
    # `chat_signal` server-side. `chat_models` additions/removals already
    # call `notify_chats!`; the `ChatModel` constructor anchors an
    # `on(busy_active) → notify_chats!` so a prompt going in-flight (or
    # finishing) fans straight through to the sidebar without any polling.
    status_obs = Observable(Dict{String,String}())
    function recompute_status!()
        # Snapshot (pid, project) pairs under the lock (T17) so we don't iterate
        # `state.projects[]` across the `chat_status` call (which can yield) while
        # a writer rehashes the dict. `chat_status` then runs on the snapshot.
        # Same membership as the rendered list (`open_chat_projects(state, …)`):
        # persisted-interacted OR carrying a live ChatModel.
        pairs = lock(state.lock) do
            [(pid, p) for (pid, p) in state.projects[]
             if chat_in_sidebar(p) || (!p.dismissed && haskey(state.chat_models, pid))]
        end
        new = Dict{String,String}()
        for (pid, p) in pairs
            new[pid] = string(chat_status(state, p))
        end
        status_obs[] = new
    end
    recompute_status!()
    on(session, state.chat_signal) do _; recompute_status!(); end
    on(session, state.workers)     do _; recompute_status!(); end
    on(session, state.projects)    do _; recompute_status!(); end

    Bonito.onjs(session, status_obs, js"""(map) => {
        document.querySelectorAll('.bt-sidebar .bt-side-led').forEach(el => {
            const pid = el.closest('.bt-side-item')?.dataset.projectId;
            if (!pid) return;
            const st = map[pid] || 'offline';
            if (el.dataset.status !== st) {
                el.dataset.status = st;
                el.title = st;
            }
        });
    }""")

    return aside
end

# CSS for the sidebar + icons. Mobile (≤640px) collapses to icons-only at
# 56px wide; desktop expands to 200px with the project name to the right
# of each icon.
const SidebarStyles = Bonito.Styles(
    CSS(".bt-sidebar",
        # Normal flex child of `.bt-shell` rather than `position: fixed`. The
        # old fixed positioning was relative to the viewport, so on wide
        # monitors the sidebar pinned to viewport-left while the centered
        # main panel floated far away — visually disconnecting them. Inside
        # the shell flexbox, it sits flush against the main column.
        "width" => "200px", "flex-shrink" => "0",
        "background" => "var(--bt-surface)",
        "border-right" => "1px solid var(--bt-border)",
        "overflow-y" => "auto", "overflow-x" => "hidden",
        "display" => "flex", "flex-direction" => "column",
        # Small top padding so the first item (Home) rides up near the
        # main-panel logo's line instead of sitting ~20px below it. The
        # collapse rail below adds the rest of the offset.
        "padding" => "4px 0 10px"),
    CSS(".bt-side-list",
        "display" => "flex", "flex-direction" => "column", "gap" => "2px"),
    # Header rail: holds the VSCode-style sidebar toggle. Right-aligned when
    # expanded, centered when collapsed.
    CSS(".bt-side-header",
        "display" => "flex", "align-items" => "center", "justify-content" => "flex-end",
        "padding" => "0 8px 2px", "flex-shrink" => "0"),
    CSS(".bt-side-collapse",
        "display" => "inline-flex", "align-items" => "center", "justify-content" => "center",
        "width" => "28px", "height" => "28px", "padding" => "0",
        "background" => "transparent", "border" => "none",
        "border-radius" => "var(--bt-radius-sm)",
        "color" => "var(--bt-text-muted)", "cursor" => "pointer",
        "transition" => "background 80ms, color 80ms",
        "-webkit-tap-highlight-color" => "transparent"),
    CSS(".bt-side-collapse:hover",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text)"),
    CSS(".bt-sidebar.bt-collapsed", "width" => "56px"),
    CSS(".bt-sidebar.bt-collapsed .bt-side-name", "display" => "none"),
    CSS(".bt-sidebar.bt-collapsed .bt-side-item", "justify-content" => "center"),
    CSS(".bt-sidebar.bt-collapsed .bt-side-section", "display" => "none"),
    CSS(".bt-sidebar.bt-collapsed .bt-side-empty", "display" => "none"),
    CSS(".bt-sidebar.bt-collapsed .bt-side-header", "justify-content" => "center", "padding" => "0 0 6px"),
    CSS(".bt-side-item",
        # Vertically center the label against the icon — reads as a normal
        # inline `[icon] text` row. For a two-line title the icon centers to
        # the text block, which is what you want too.
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "6px 10px",
        "cursor" => "pointer",
        "border-left" => "3px solid transparent",
        "transition" => "background 80ms"),
    CSS(".bt-side-item:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-side-active",
        "border-left-color" => "var(--bt-accent)",
        "background" => "var(--bt-surface-2)"),
    # Per-entry status LED: a 6px dot nestled into the icon's bottom-right
    # corner. No outline ring — the dot sits ON the colored tile, where any
    # of the three status colors reads cleanly against it. `data-status`
    # picks the state; active pulses softly, the other two are flat.
    # Position is relative to the entry so the LED follows the icon when
    # the entry wraps over two lines on a narrow column.
    CSS(".bt-side-item", "position" => "relative"),
    # Icon + presence-badge wrapper: the LED nestles on the icon's corner and
    # rides with it whether the rail is expanded or collapsed.
    CSS(".bt-side-icon-wrap",
        "position" => "relative", "flex-shrink" => "0",
        "display" => "flex", "line-height" => "0"),
    CSS(".bt-side-led",
        "position" => "absolute",
        "right" => "-2px", "bottom" => "-2px",
        "width" => "10px", "height" => "10px",
        "border-radius" => "50%",
        "border" => "2px solid var(--bt-surface)",
        "box-sizing" => "border-box",
        "background" => "var(--bt-text-faint)",
        "transition" => "background 120ms"),
    CSS(".bt-side-led[data-status=\"offline\"]",
        "background" => "var(--bt-status-offline)"),    # red — worker down
    # online = ACP/worker up, idle. Solid green (NOT yellow): an open/online
    # chat is a healthy steady state, not a warning.
    CSS(".bt-side-led[data-status=\"online\"]",
        "background" => "var(--bt-status-online)"),     # green (solid)
    # active = an agent turn is in flight. Same green, but pulsing = "working".
    CSS(".bt-side-led[data-status=\"active\"]",
        "background" => "var(--bt-status-active)",      # green
        "animation" => "bt-side-led-pulse 1.1s ease-in-out infinite"),
    CSS("@keyframes bt-side-led-pulse",
        CSS("0%",   "box-shadow" => "0 0 0 0 rgba(22,163,74,0.55)"),
        CSS("70%",  "box-shadow" => "0 0 0 5px rgba(22,163,74,0)"),
        CSS("100%", "box-shadow" => "0 0 0 0 rgba(22,163,74,0)")),
    CSS(".bt-proj-icon",
        "border-radius" => "8px",
        "color" => "#fff", "font-weight" => "600",
        "text-align" => "center",
        "flex-shrink" => "0",
        "user-select" => "none",
        # Initials sit on the identicon pattern — a soft shadow keeps them
        # legible over both the light and dark pattern cells.
        "text-shadow" => "0 1px 2px rgba(15,23,42,0.45)",
        "font-family" => "'Inter', system-ui, sans-serif",
        # Flex-center the contents so the home <img> sits perfectly in the
        # middle. For initials we still use line-height (set inline by
        # `project_icon`) which falls into the same flex box gracefully.
        "display" => "flex", "align-items" => "center", "justify-content" => "center"),
    # Home icon: borderless 32px slot, glyph in muted text color so it sits
    # quietly above the colorful project tiles. The SVG ships with white
    # strokes, so we recolor it via a CSS filter.
    CSS(".bt-side-home-icon",
        "width" => "32px", "height" => "32px",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "flex-shrink" => "0"),
    # invert+sepia+rotate is the standard trick for tinting a white SVG via
    # CSS without per-color SVG variants. Lands close to --bt-text-muted (#64748b).
    CSS(".bt-side-home-icon img",
        "filter" => "invert(48%) sepia(13%) saturate(540%) hue-rotate(176deg) brightness(92%) contrast(86%)"),
    CSS(".bt-side-active .bt-side-home-icon img",
        "filter" => "invert(38%) sepia(86%) saturate(2400%) hue-rotate(212deg) brightness(99%) contrast(95%)"),
    CSS(".bt-side-name",
        "font-size" => "12px",
        "line-height" => "1.3",
        "color" => "var(--bt-text)",
        "min-width" => "0",
        "flex" => "1 1 auto",
        # Two-line clamp so a long auto-inferred title wraps cleanly without
        # blowing up the row height. Newer Chromium / WebKit honour
        # `-webkit-line-clamp`; fallback for the rare browser that doesn't is
        # nowrap-with-ellipsis (so the row stays single-line at worst).
        "display" => "-webkit-box",
        "-webkit-box-orient" => "vertical",
        "-webkit-line-clamp" => "2",
        "overflow" => "hidden",
        "overflow-wrap" => "anywhere",
        "text-overflow" => "ellipsis"),
    # Close (✕) on an active-chat row: reveal on row hover, red on its own hover.
    # Pinned to the row's TOP-RIGHT corner — the two hover affordances split the
    # right edge: ✕ top-right, "▾ files" (.bt-side-tree-hint) bottom-right, so
    # they never compete for the same spot. Anchored to .bt-side-item's own
    # `position: relative`, which works both with and without the chat-row
    # wrapper. Same legibility backdrop trick as the files hint (the glyph can
    # overlay a long two-line title). `pointer-events: none` while hidden — an
    # INVISIBLE close target that tears a chat down on a stray corner click
    # would be a trap.
    CSS(".bt-side-close",
        "position" => "absolute", "top" => "3px", "right" => "6px",
        "color" => "var(--bt-text-faint)",
        "font-size" => "12px", "line-height" => "1",
        "padding" => "2px 4px", "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-surface-2)",
        "opacity" => "0", "pointer-events" => "none",
        "transition" => "opacity 80ms, background 80ms, color 80ms"),
    # Reveal on the row wrapper too: the files hint is a SIBLING overlaying the
    # item, so hovering IT un-hovers the item — without the wrapper selector the
    # ✕ would flicker away while the pointer crosses the hint.
    CSS(".bt-side-item:hover .bt-side-close, .bt-side-chat-row:hover .bt-side-close",
        "opacity" => "1", "pointer-events" => "auto"),
    CSS(".bt-side-close:hover",
        "background" => "rgba(239,68,68,0.14)", "color" => "var(--bt-error)"),
    # The icons-only rail has no titles — a corner ✕ would overlay the icon
    # itself and misclicks would close chats; the rail is for switching only.
    CSS(".bt-sidebar.bt-collapsed .bt-side-close", "display" => "none"),
    # Shown when no chats are open yet.
    CSS(".bt-side-empty",
        "padding" => "10px 12px", "font-size" => "12px",
        "color" => "var(--bt-text-muted)", "line-height" => "1.4"),

    # ── Per-chat file tree ──────────────────────────────────────────────────
    # The chat row and its file tree share ONE pill: opening flips
    # `.bt-tree-open`, which tints the whole wrapper so the tree visibly belongs
    # to the chat above it.
    CSS(".bt-side-chat",
        "display" => "flex", "flex-direction" => "column",
        "border-radius" => "var(--bt-radius-sm)",
        "transition" => "background 80ms"),
    CSS(".bt-side-chat.bt-tree-open",
        "background" => "var(--bt-surface-2)"),
    # The row wrapper anchors the files affordance: `position: relative` here
    # (NOT on the whole chat box) keeps the hint pinned to the ROW's bottom-right,
    # so it stays in place when the tree expands below.
    CSS(".bt-side-chat-row", "position" => "relative"),
    # Files affordance: a minimal icon+label tucked into the row's bottom-right
    # corner — no chip border / shadow / pill rounding, just text. Hidden until
    # the chat is hovered; ALWAYS shown while open so the collapse control stays
    # obvious.
    CSS(".bt-side-tree-hint",
        "position" => "absolute", "right" => "6px", "bottom" => "3px",
        "display" => "flex", "align-items" => "center", "gap" => "3px",
        "padding" => "0 3px",
        "font-size" => "10px", "font-weight" => "500", "line-height" => "1.3",
        "white-space" => "nowrap",
        "color" => "var(--bt-text-muted)",
        # Subtle backdrop so the floating label stays legible when it overlays
        # the title's text — matches the row's hover/open tint so it blends in.
        "background" => "var(--bt-surface-2)",
        "border-radius" => "var(--bt-radius-sm)",
        "cursor" => "pointer", "user-select" => "none",
        "opacity" => "0", "pointer-events" => "none",
        "transition" => "opacity 100ms, color 100ms"),
    CSS(".bt-side-chat:hover .bt-side-tree-hint, .bt-side-chat.bt-tree-open .bt-side-tree-hint",
        "opacity" => "1", "pointer-events" => "auto"),
    # Feedback on the affordance's own hover — just accent the text.
    CSS(".bt-side-tree-hint:hover",
        "color" => "var(--bt-accent)"),
    # The tree itself — hidden until the chat carries `.bt-tree-open`.
    CSS(".bt-side-tree-wrap", "display" => "none"),
    CSS(".bt-side-chat.bt-tree-open > .bt-side-tree-wrap", "display" => "block"),
    CSS(".bt-tree",
        "display" => "flex", "flex-direction" => "column", "padding" => "2px 0 6px 0"),
    CSS(".bt-tree-search",
        "margin" => "2px 8px 6px 8px", "padding" => "4px 8px", "font-size" => "12px",
        "border" => "1px solid var(--bt-border)", "border-radius" => "5px",
        "background" => "var(--bt-bg)", "color" => "var(--bt-text, #111827)",
        "outline" => "none"),
    CSS(".bt-tree-search:focus", "border-color" => "var(--bt-accent, #2563eb)"),
    CSS(".bt-tree-scroll",
        "max-height" => "42vh", "overflow-y" => "auto", "overflow-x" => "hidden"),
    CSS(".bt-tree-rows", "display" => "flex", "flex-direction" => "column"),
    CSS(".bt-tree-row",
        "display" => "flex", "align-items" => "center", "gap" => "4px",
        "padding" => "2px 8px 2px 4px", "font-size" => "12px", "line-height" => "1.5",
        "cursor" => "pointer", "white-space" => "nowrap",
        "color" => "var(--bt-text, #111827)"),
    CSS(".bt-tree-row:hover", "background" => "var(--bt-hover, rgba(0,0,0,0.05))"),
    CSS(".bt-tree-arrow",
        "flex" => "0 0 auto", "width" => "10px", "font-size" => "8px",
        "color" => "var(--bt-text-muted)", "text-align" => "center"),
    CSS(".bt-tree-label", "overflow" => "hidden", "text-overflow" => "ellipsis"),
    CSS(".bt-tree-dir > .bt-tree-label", "font-weight" => "500"),
    CSS(".bt-tree-relpath",
        "margin-left" => "6px", "font-size" => "11px", "color" => "var(--bt-text-muted)",
        "overflow" => "hidden", "text-overflow" => "ellipsis"),
    # ⤓ download affordance: right-anchored, revealed on row hover.
    CSS(".bt-tree-download",
        "flex" => "0 0 auto", "margin-left" => "auto",
        "padding" => "0 4px", "font-size" => "12px", "line-height" => "1",
        "color" => "var(--bt-text-muted)",
        "opacity" => "0", "transition" => "opacity 80ms, color 80ms"),
    CSS(".bt-tree-row:hover .bt-tree-download", "opacity" => "1"),
    CSS(".bt-tree-download:hover", "color" => "var(--bt-accent)"),
    CSS(".bt-tree-empty",
        "padding" => "4px 12px", "font-size" => "11px", "color" => "var(--bt-text-muted)"),
    # No trees / hint in the collapsed icon rail.
    CSS(".bt-sidebar.bt-collapsed .bt-side-tree-wrap", "display" => "none"),
    CSS(".bt-sidebar.bt-collapsed .bt-side-tree-hint", "display" => "none"),

    # Mobile: collapse to icon-only sidebar.
    CSS("@media (max-width: 640px)",
        CSS(".bt-sidebar",  "width" => "56px"),
        CSS(".bt-side-name", "display" => "none"),
        CSS(".bt-side-item", "justify-content" => "center"),
        # `RUNNING ON WORKER` is ~68px wide at the chosen font/letter-spacing
        # but the icons-only sidebar is 56px — the text wraps to three lines
        # (`RUNNI` / `ON` / `WORKE`) and pushes the layout sideways. The
        # section is purely a visual divider; with names hidden, there's no
        # group to label anyway. Drop it on mobile.
        CSS(".bt-side-section", "display" => "none"),
        # Same story for the "No open chats yet — open one from the
        # dashboard" empty state: a 56px column has no room for a sentence.
        # The dashboard view that text refers to is already visible to the
        # right; hide on mobile so the sidebar stays purely icons.
        CSS(".bt-side-empty", "display" => "none"),
        # The per-chat "▾ files" affordance is absolutely positioned at the
        # row's bottom-right; in the 56px icon rail it overlays the chat icon.
        # The explicit `.bt-collapsed` path hides it (above) — the responsive
        # 56px path must too, or a narrow window shows the menu over the icon.
        CSS(".bt-side-tree-hint", "display" => "none"),
        CSS(".bt-side-tree-wrap", "display" => "none")),
)

# ── Unified App ────────────────────────────────────────────────────────────
# Single Bonito App that owns the whole site. The sidebar always shows on
# the left; the main area swaps between the dashboard and a project's chat
# based on `current_view::Observable{String}`. "" → dashboard; otherwise →
# the project id (looked up in state.chat_models).

const UnifiedShellStyles = Bonito.Styles(
    CSS("html, body",
        "height" => "100%", "margin" => "0", "padding" => "0",
        "overflow" => "hidden",
        # Light off-white surrounding the centered chat column on wide monitors —
        # subtle, just enough that the app reads as a contained surface
        # instead of dissolving into the page bg. Match the dashboard's bg
        # variable so theming stays in one place.
        "background" => "var(--bt-bg, #fafaf9)"),
    # Width tokens for the chat/dashboard column. `--bt-main-max` is the bounded,
    # centered width when the plotpane is CLOSED — chosen so home / a plotpane-less
    # chat look identical to the old centered 1600px shell (1600 − 200px sidebar =
    # 1400px). `--bt-main-min` is the floor the chat shrinks to once the plotpane
    # has eaten all the surrounding whitespace and reached the "left wall".
    CSS(":root",
        "--bt-main-max" => "1400px",
        "--bt-main-min" => "480px"),
    # Full-viewport shell — NO centered cap. The centering moved down to `.bt-main`
    # so the plotpane (a `.bt-stage` child, sibling of `.bt-main`) can extend past
    # the chat into the right-hand whitespace the old centered shell used to waste.
    CSS(".bt-shell",
        # 100dvh, not 100vh (mobile URL-bar safe).
        "height"    => "100dvh",
        "display"   => "flex", "flex-direction" => "row",
        "background"   => "var(--bt-bg)",
        # Root font for the WHOLE shell. Without this only `.bt-dash` carried a
        # font-family and everything else (sidebar, loading/error cards, chat)
        # fell back to the browser default — i.e. Times serif. A modern system
        # stack renders cleanly on every OS with no web-font fetch.
        "font-family" => "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif",
        "color"        => "var(--bt-text)",
        "-webkit-font-smoothing" => "antialiased"),
    # Window-level toast — a transient notice (e.g. the editor open-guard's
    # "can't open <file>"). Fixed, centered near the bottom; JS flips
    # data-shown and clears it after ~3.2s (see plotpane_toast_layer).
    CSS(".bt-toast",
        "position" => "fixed",
        "bottom" => "22px", "left" => "50%",
        "transform" => "translateX(-50%) translateY(12px)",
        "max-width" => "min(520px, 86vw)",
        "background" => "#1f2937", "color" => "#f9fafb",
        "padding" => "10px 16px", "border-radius" => "8px",
        "font-size" => "13px", "line-height" => "1.4",
        "box-shadow" => "0 6px 24px rgba(0,0,0,0.28)",
        "z-index" => "9999",
        "opacity" => "0", "pointer-events" => "none",
        "transition" => "opacity 0.18s ease, transform 0.18s ease"),
    CSS(".bt-toast[data-shown=\"true\"]",
        "opacity" => "1",
        "transform" => "translateX(-50%) translateY(0)"),
    # Everything to the right of the sidebar: the chat/dashboard column plus the
    # plotpane. Fills the viewport minus the sidebar; `.bt-main` centers within
    # whatever horizontal space the plotpane leaves it.
    CSS(".bt-stage",
        "flex" => "1 1 auto", "min-width" => "0",
        "display" => "flex", "flex-direction" => "row",
        # Positioning context for the narrow-viewport plotpane overlay.
        "position" => "relative",
        "overflow" => "hidden"),
    # The chat / dashboard column. `flex: 0 1 max` + `margin: 0 auto` ⇒ it caps at
    # `--bt-main-max` and sits centered in the free space when the plotpane is
    # closed (identical to the old look). As the plotpane grows, the free space
    # shrinks so the column slides left; once the free space is gone it shrinks
    # down to `--bt-main-min` — the two-stage "slide then shrink at the wall".
    # Side borders give the contained-surface frame the shell used to provide.
    CSS(".bt-main",
        "flex" => "0 1 var(--bt-main-max)",
        "min-width" => "var(--bt-main-min)",
        "margin" => "0 auto",
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "overflow" => "hidden",
        "border-left"  => "1px solid var(--bt-border)",
        "border-right" => "1px solid var(--bt-border)"),
    # When the plotpane is OPEN, the chat stops centering and becomes a fixed,
    # resizable LEFT column — the plotpane (flex:1) then fills ALL the space to
    # its right with no gap. The divider sets `--bt-chat-width` (clamped to the
    # chat's sensible reading range). This is what makes "everything right of the
    # chat is the plotpane/editor/drop zone" true.
    CSS(".bt-stage:has(.bt-plotpane.bt-plotpane-visible) .bt-main",
        "flex"   => "0 0 clamp(var(--bt-main-min), var(--bt-chat-width, 820px), var(--bt-main-max))",
        "margin" => "0"),

    # Mobile: drop the 480px desktop floor that keeps the chat readable on
    # split screens. On a 393px-wide phone the floor forces .bt-main to
    # 480px so the chat pane runs ~143px off the right edge of the viewport
    # — header, messages, input and toolbar all shift right and clip. Let
    # the column shrink to whatever the viewport gives us (sidebar takes
    # 56px, the chat gets the rest).
    CSS("@media (max-width: 640px)",
        CSS(":root", "--bt-main-min" => "0px"),
        CSS(".bt-main", "min-width" => "0")),

    # Narrow viewports with the PLOTPANE OPEN: a side-by-side split would
    # force chat-min + pane-min past the stage and clip the messages. Below
    # the breakpoint the pane becomes a full-stage OVERLAY instead — the
    # chat keeps its full width underneath; × / tab-close brings it back.
    # The divider is meaningless in overlay mode.
    CSS("@media (max-width: 1100px)",
        CSS(".bt-plotpane.bt-plotpane-visible",
            "position" => "absolute", "inset" => "0",
            "z-index" => "30",
            "width" => "100%",
            "border-left" => "none",
            "box-shadow" => "var(--bt-shadow-lg, 0 8px 32px rgba(0,0,0,0.25))"),
        CSS(".bt-stage:has(.bt-plotpane.bt-plotpane-visible) .bt-main",
            "flex" => "0 1 var(--bt-main-max)",
            "margin" => "0 auto"),
        CSS(".bt-plotpane-visible .bt-pp-resize",
            "display" => "none")),

    # ── Keep-alive view stack ────────────────────────────────────────────────
    # The dashboard and every opened chat are all mounted at once and stacked on
    # top of each other (absolute inset:0); the nav handler toggles `display` so
    # exactly one shows. Stacking (not a flow swap) is what lets us preserve each
    # chat's DOM/embeds while only one is on screen.
    CSS(".bt-main-views",
        "position" => "relative",
        "flex" => "1 1 auto", "min-height" => "0", "min-width" => "0"),
    CSS(".bt-view",
        "position" => "absolute", "inset" => "0",
        "display" => "flex", "flex-direction" => "column", "min-width" => "0"),
    # The chats container is just a positioning context; its panes are the
    # absolutely-positioned, individually-toggled children. It is stacked ON TOP
    # of the dashboard (later in DOM), so it MUST be click-transparent — otherwise
    # the empty container (all panes hidden on home) swallows every click meant
    # for the dashboard beneath it. Only a visible pane re-enables pointer events.
    CSS(".bt-view-chats", "display" => "block", "pointer-events" => "none"),
    CSS(".bt-chatpane",
        "position" => "absolute", "inset" => "0",
        "display" => "none", "flex-direction" => "column", "min-width" => "0",
        "pointer-events" => "auto"),
    # Overlay sits on top (loading / unknown card). Click-through when empty so
    # it never blocks the chat behind it; its card re-enables pointer events.
    CSS(".bt-view-overlay",
        "position" => "absolute", "inset" => "0",
        "pointer-events" => "none"),
    CSS(".bt-view-overlay .bt-loading-wrap, .bt-view-overlay .bt-empty",
        "pointer-events" => "auto"),
    # The loading card doubles as the chat's mount curtain (phases 2/3, see
    # chat_waiting_view): full height + opaque so the pane's initial geometry
    # churn (estimate→measured heights, image mounts, scrollbar pumping)
    # never shows around or below the card. The wrap stays a PLAIN block, so
    # `.bt-loading`'s flex centering is inert and the card hugs the top —
    # the same spot across all phases.
    CSS(".bt-view-overlay .bt-loading-wrap",
        "height" => "100%",
        "background" => "var(--bt-bg)",
        "transition" => "opacity 200ms ease"),
    # Hidden-until-onload: a card over an already-settled pane (kept-alive
    # revisit) is dismissed before it ever paints.
    CSS(".bt-loading-wrap.bt-loading-pending",
        "visibility" => "hidden"),
    # The settle fade — mirrors the old curtain reveal.
    CSS(".bt-loading-wrap.bt-loading-hide",
        "opacity" => "0", "pointer-events" => "none"),
)

# Per-session bring-up bookkeeping for the loading view. `inflight` holds the
# project ids that currently have a `ensure_project_session!` task running (so
# re-renders don't spawn duplicates); `errors` holds the last bring-up failure
# message per id (gates re-kicking AND drives the error card); `retry` is an
# Observable a "Try again" click notifies with the id to retry.
struct LoadingState
    inflight :: Set{String}
    errors   :: Dict{String,String}
    retry    :: Observable{String}
end
LoadingState() = LoadingState(Set{String}(), Dict{String,String}(), Observable(""))

# Loading screen for a project whose ChatModel isn't cached yet. Replaces the
# old bare "Starting chat for X…" text, which had two problems: it never
# changed once shown (so a chat that finished bringing up AFTER you navigated
# stayed stuck on the text until you clicked away and back), and it span
# forever for projects whose worker was offline (the model never builds).
#
# This view depends on `state.workers`, so it re-renders on every worker
# status change — giving us, for free, the offline message AND a re-attempt
# when the worker comes (back) online. When a bring-up task finishes it
# `notify`s `current_view` (value unchanged → pure re-render kick), so
# `unified_main`'s outer `map` re-evaluates and swaps to the now-cached chat.
#
# The state machine (per project id, see `LoadingState`):
#   offline worker        → "worker is offline" card (no task, no spinner)
#   last attempt errored  → error card + "Try again" (no auto-retry — that
#                            would be a tight failure loop)
#   a task is in flight   → spinner
#   otherwise             → spawn ONE bring-up task, show spinner
function project_loading_view(state::ServerState, pid::String,
                               current_view::Observable{String},
                               ls::LoadingState)
    # Wrap the reactive body in a DOM.div: unified_main's outer
    # `map(current_view) do pid ... end` expects each branch to return a
    # Node, not an Observable{Node}. Returning the bare `map(state.workers)`
    # threw `MethodError: Cannot convert Observable{Node} to Node` and the
    # loading view never appeared while the bring-up ran.
    # The spinner is a STABLE sibling, rendered once OUTSIDE the reactive `body`
    # below. If it lived inside the `map`, every `state.workers` notify during
    # bring-up would recreate the element and restart its CSS rotation from 0° —
    # the classic "the spinner doesn't spin". Offline/error branches tag their
    # content `.bt-loading-msg`, and CSS (`:has`) hides the spinner for them.
    spinner = DOM.div(class = "bt-loading-spinner")
    body = map(state.workers) do workers
        p = get(state.projects[], pid, nothing)
        p === nothing && return DOM.div("Unknown project: $pid";
                                        class = "bt-empty bt-loading-msg",
                                        style = Styles("padding" => "40px"))
        w      = get(workers, p.worker_id, nothing)
        wname  = w === nothing ? p.worker_id : w.name
        online = w !== nothing && isopen(w)
        if !online
            return DOM.div(
                DOM.div("⚠"; class = "bt-loading-glyph"),
                DOM.div("Worker is offline"; class = "bt-loading-title"),
                DOM.div("$(p.name) lives on $(wname), which isn't connected " *
                        "right now. Start that worker to open this chat.";
                        class = "bt-loading-sub");
                class = "bt-loading-msg")
        end
        if haskey(ls.errors, pid)
            return DOM.div(
                DOM.div("⚠"; class = "bt-loading-glyph"),
                DOM.div("Couldn't open $(p.name)"; class = "bt-loading-title"),
                DOM.div(ls.errors[pid]; class = "bt-loading-sub"),
                DOM.div("Try again";
                        class   = "bt-btn bt-btn-secondary",
                        style   = Styles("margin-top" => "6px"),
                        onclick = js"() => $(ls.retry).notify($(pid))");
                class = "bt-loading-msg")
        end
        # Gate the bring-up on the chat still being the one on screen (T5). This
        # `map(state.workers)` body is NOT session-scoped, so it survives the
        # user navigating away (or closing the chat via ✕) and re-runs on the
        # next workers-notify. Without this gate that stale re-run would respawn
        # the claude subprocess for a chat the user already closed. T1's funnel
        # also collapses genuine duplicate bring-ups, but this stops the spurious
        # kick at the source.
        if current_view[] == pid &&
           !(pid in ls.inflight) && !haskey(state.chat_models, pid)
            push!(ls.inflight, pid)
            proj = p
            @async begin
                try
                    ensure_project_session!(state, proj)
                catch e
                    ls.errors[pid] = sprint(showerror, e)
                    @warn "loading: chat bring-up failed" project = proj.name exception = e
                finally
                    delete!(ls.inflight, pid)
                    safe_notify!(current_view)   # re-render: show chat, or the error card
                end
            end
        end
        DOM.div(
            DOM.div("Opening $(p.name)…"; class = "bt-loading-title"),
            DOM.div("Connecting to $(wname) and restoring the conversation…";
                    class = "bt-loading-sub");
            class = "bt-loading-text")
    end
    return DOM.div(DOM.div(spinner, body; class = "bt-loading"); class = "bt-loading-wrap")
end

# Phases 2+3 of the load screen: the card for a chat whose ChatModel IS
# cached but whose pane hasn't finished mounting and settling yet. Before
# this existed the overlay vanished the instant the model landed server-side
# — but the pane's DOM still had to ship, mount, and settle, so the user saw
# bring-up card → ~1s of bare background → a separate per-chat curtain.
# Now ONE card (identical classes/geometry to `project_loading_view`'s) stays
# up from click to settle and only its sub-text changes:
#
#   "Connecting to <worker>…"   project_loading_view, while session/load runs
#   "Loading the chat…"         this card, pane DOM shipping + mounting
#   "Rendering messages…"       chat module mounted, settle watch running
#
# The chat module drives the hand-offs: `_startSettle` (bonitoagents.js)
# dispatches `bt-chat-settling` / `bt-chat-settled` window events carrying
# the pane pid, and mirrors them as `data-bt-settling` / `data-bt-settled`
# flags on the `.bt-chatpane` so a card that mounts AFTER an event fired
# (kept-alive revisit, rapid navigation) can read the current state
# synchronously instead of waiting for the next event.
#
# A struct + jsrender (not a plain function) for the same reason as
# ChatPaneRef below: `Bonito.onload` must register against the SUBSESSION
# that renders this card (the overlay re-renders one per `current_view`
# change) — registered on the parent session, whose document loaded long
# ago, the mount hook would never fire.
struct ChatWaitingView
    state :: ServerState
    pid   :: String
end

function Bonito.jsrender(session::Bonito.Session, v::ChatWaitingView)
    p     = get(v.state.projects[], v.pid, nothing)
    title = p === nothing ? "Opening chat…" : "Opening $(p.name)…"
    wrap  = DOM.div(
        DOM.div(
            DOM.div(class = "bt-loading-spinner"),
            DOM.div(title; class = "bt-loading-title"),
            DOM.div("Loading the chat…"; class = "bt-loading-sub");
            class = "bt-loading");
        # Starts hidden (`bt-loading-pending`): navigating back to an
        # already-settled pane must not flash a loading card. The onload
        # below either keeps it hidden and bails, or reveals it.
        class = "bt-loading-wrap bt-loading-pending",
        dataWaitingFor = v.pid)
    Bonito.onload(session, wrap, js"""(wrap) => {
        const pid = wrap.dataset.waitingFor;
        const sub = wrap.querySelector('.bt-loading-sub');
        const pane = document.querySelector(
            '.bt-chatpane[data-pane-pid="' + pid + '"]');
        const phase3 = () => { if (sub) sub.textContent = 'Rendering messages…'; };
        let cap = null;
        const cleanup = () => {
            window.removeEventListener('bt-chat-settling', onSettling);
            window.removeEventListener('bt-chat-settled',  onSettled);
            if (cap) clearTimeout(cap);
        };
        const hide = () => {
            cleanup();
            wrap.classList.add('bt-loading-hide');
            setTimeout(() => { wrap.style.display = 'none'; }, 250);
        };
        const onSettling = (e) => { if (e.detail === pid) phase3(); };
        const onSettled  = (e) => { if (e.detail === pid) hide(); };
        if (pane && pane.dataset.btSettled) {       // kept-alive revisit
            wrap.style.display = 'none';
            return;
        }
        wrap.classList.remove('bt-loading-pending');
        if (pane && pane.dataset.btSettling) phase3();  // mounted mid-settle
        window.addEventListener('bt-chat-settling', onSettling);
        window.addEventListener('bt-chat-settled',  onSettled);
        // Failsafe: a pane that dies during render must not leave an opaque
        // overlay forever. The chat's own settle watch hard-caps at 5s, so
        // this only fires when something is genuinely broken.
        cap = setTimeout(hide, 15000);
    }""")
    return Bonito.jsrender(session, wrap)
end

# Max number of chat panes kept mounted (DOM-preserved) at once. Beyond this,
# the least-recently-viewed chat's pane is dropped — its live embeds tear down
# and re-delegate on the next visit. Generous enough that normal back-and-forth
# between a handful of chats never re-renders anything.
const KEEP_ALIVE_CAP = 6

# A stable, per-pid handle the chat-pane KeyedList renders. Memoized per session
# (see `unified_main`) so the SAME object is handed to KeyedList across renders,
# and the pane's DOM — with its live embeds, scroll position, and per-app
# collapse state — is preserved across navigation. That preservation IS the
# "resident per-chat state" requirement: switching chats just hides/shows panes.
struct ChatPaneRef
    state    :: ServerState
    pid      :: String
    # The window's plotpane handle, passed down from unified_app via
    # unified_main. ChatPaneRef is where the per-session ChatModel view is
    # created, so this is where the window-scoped pane attaches to it.
    plotpane :: Union{Nothing,PlotPane}
end

# Render one kept-alive chat pane. The pane is absolutely positioned to fill the
# view area and toggled visible/hidden by the nav handler (see `unified_main`),
# never re-rendered.
function Bonito.jsrender(session::Bonito.Session, r::ChatPaneRef)
    model = get(r.state.chat_models, r.pid, nothing)
    # The flex sizing is load-bearing: the chat shell (.bt-app) is height:100%,
    # so the wrapper must be a flex column that fills, or the chat collapses.
    inner = if model === nothing
        DOM.div()
    else
        # Make the per-session view HERE (rather than letting
        # jsrender(::ChatModel) do it) so the window's plotpane can ride
        # along — chat command handlers reach it as `model.plotpane`.
        view = copy(model, session)
        view.plotpane = r.plotpane
        DOM.div(view; style = Styles("flex" => "1 1 auto", "min-height" => "0",
                                     "display" => "flex", "flex-direction" => "column"))
    end
    pane = DOM.div(inner; class = "bt-chatpane", dataPanePid = r.pid)
    # Self-initialize visibility on mount: a pane the KeyedList adds while its
    # chat is ALREADY the active view must reveal itself (the nav handler ran
    # before this pane existed). We read the active pid from the container's
    # data attribute rather than interpolating the parent-session `current_view`
    # Observable — interpolating a parent Observable into a KeyedList child's JS
    # triggers "Key not found"/null.notify, because the child renders in a
    # different session (see feedback_keyedlist_child_session_observable).
    Bonito.onload(session, pane, js"""(el) => {
        const root = el.closest('.bt-main-views');
        const active = root ? (root.dataset.activeView || '') : '';
        el.style.display = (el.dataset.panePid === active) ? 'flex' : 'none';
    }""")
    Bonito.jsrender(session, pane)
end

# Render the main panel given the current view + the bonito session. Pulled out
# so unified_app's body stays small.
#
# Keep-alive architecture (replaces the old `map(current_view)` node-swap, which
# tore the whole panel down on every navigation): the dashboard and every opened
# chat are mounted SIMULTANEOUSLY and only their visibility is toggled. This (a)
# preserves per-chat DOM/embeds/collapse state across navigation and (b) stops
# the `null.bonitoKeyedList` flood — the dashboard's KeyedLists are never torn
# down mid-update because the dashboard is never unmounted.
function unified_main(session::Bonito.Session, state::ServerState,
                      current_view::Observable{String}, ls::LoadingState,
                      pane::Union{Nothing,PlotPane} = nothing)
    # ── Dashboard pane: rendered ONCE, mounted forever ──────────────────────
    dash_pane = DOM.div(
        dashboard_dom(session, state; current_view = current_view);
        class = "bt-view bt-view-dash")

    # ── Chat panes: one per opened chat, DOM-preserved via KeyedList ────────
    # `alive` is the LRU-ordered list of pids whose pane stays mounted. Memoized
    # ChatPaneRefs (same object per pid) give KeyedList a stable identity so it
    # preserves rather than rebuilds. A pid that's no longer cached (chat closed)
    # drops out of the list ⇒ KeyedList detaches its pane.
    alive = Observable(String[])
    panes = Dict{String,ChatPaneRef}()
    ref(pid) = get!(() -> ChatPaneRef(state, pid, pane), panes, pid)
    chatpanes_obs = map(alive) do pids
        ChatPaneRef[ref(pid) for pid in pids if haskey(state.chat_models, pid)]
    end
    chats_host = DOM.div(KeyedList(chatpanes_obs; key = r -> r.pid);
                         class = "bt-view bt-view-chats")

    # ── Overlay: the single, continuous load screen ──────────────────────────
    # Model not cached yet → `project_loading_view` (kicks the bring-up and
    # re-notifies `current_view` on success → we re-enter). Model cached →
    # `chat_waiting_view`: cached ≠ pixels ready — the pane still has to
    # ship, mount, and settle, and the overlay must hold the SAME card up
    # until the chat module's settle events dismiss it. (It used to go
    # display:none here, exposing ~1s of bare background before the
    # now-removed per-chat curtain painted.)
    overlay = map(session, current_view) do pid
        if isempty(pid)
            DOM.div(; style = Styles("display" => "none"))
        elseif haskey(state.chat_models, pid)
            # The wrapper div keeps this branch a Node (like the others) so
            # Bonito renders it directly; height:100% hands the overlay's
            # full height down to the card's `.bt-loading-wrap`.
            DOM.div(ChatWaitingView(state, pid);
                    style = Styles("height" => "100%"))
        elseif haskey(state.projects[], pid)
            project_loading_view(state, pid, current_view, ls)
        else
            DOM.div("Unknown project: $pid"; class = "bt-empty",
                    style = Styles("padding" => "40px"))
        end
    end
    overlay_pane = DOM.div(overlay; class = "bt-view-overlay")

    # ── Navigation → promote to most-recently-used + evict beyond the cap ────
    on(session, current_view) do pid
        (isempty(pid) || !haskey(state.chat_models, pid)) && return
        cur = alive[]
        (!isempty(cur) && cur[end] == pid) && return     # already MRU, no churn
        keep = vcat(filter(!=(pid), cur), pid)
        length(keep) > KEEP_ALIVE_CAP && (keep = keep[(end - KEEP_ALIVE_CAP + 1):end])
        alive[] = keep
    end
    # Closing a chat (✕ → stop_session!) evicts its ChatModel and fires
    # chat_signal — prune the pane NOW so the dead chat's DOM (and its
    # embeds) is dropped immediately, not at the next navigation. The
    # `chatpanes_obs` filter would skip it on the next `alive` change
    # anyway; this makes the change happen.
    on(session, state.chat_signal) do _
        cur = alive[]
        keep = filter(pid -> haskey(state.chat_models, pid), cur)
        # A worker MOVE (transfer_project! → ensure_project_session!) DELETES then
        # RE-ADDS the chat model. The delete edge prunes the still-OPEN chat out of
        # `alive` (filter above); the re-add edge must put it back, or its pane
        # never re-materialises — it stays the current view but renders blank.
        # `current_view` is cleared to "" on a real close, so this only revives a
        # chat that's genuinely live again (a move), never an intentionally closed one.
        cv = current_view[]
        (!isempty(cv) && haskey(state.chat_models, cv) && !(cv in keep)) && push!(keep, cv)
        keep == cur || (alive[] = keep)
    end

    container = DOM.div(dash_pane, chats_host, overlay_pane; class = "bt-main-views")

    # Visibility: pure DOM toggling (no re-render, no teardown). Sets the active
    # pid on the container (so a freshly-added pane can self-init via its onload)
    # and shows the matching chat pane / the dashboard. Interpolating only
    # `current_view` here is safe — this runs in the PARENT session that owns the
    # container; it never crosses into a KeyedList child subsession.
    Bonito.onjs(session, current_view, js"""(pid) => {
        const root = document.querySelector('.bt-main-views');
        if (!root) return;
        root.dataset.activeView = pid || '';
        const dash = root.querySelector('.bt-view-dash');
        if (dash) dash.style.display = (!pid) ? 'flex' : 'none';
        // Per-pane visibility + an `onShown` ping on the one we just
        // revealed. The ping lets BonitoChat re-anchor to the bottom on
        // each open while followMode is on (user was at the bottom), and
        // preserves the user's scroll position otherwise. Without this,
        // a kept-alive pane keeps the scrollTop the browser had when we
        // hid it — fine when the user had scrolled up to read history,
        // but stale ("missing the latest message") when they had been
        // following the conversation. Brand-new chats use this same
        // path: followMode defaults true on construction, so first open
        // also lands at the bottom even if the initial mount's scroll
        // attempts raced against late image / virtual-scroll measuring.
        root.querySelectorAll('.bt-view-chats .bt-chatpane').forEach(p => {
            const wasVisible = p.style.display === 'flex';
            const visible    = (p.dataset.panePid === pid);
            // Hiding edge: snapshot the user's scroll state BEFORE we
            // flip display, so we read the still-valid scrollTop instead
            // of the post-display:none collapsed one.
            if (wasVisible && !visible) {
                const msgs = p.querySelector('.bt-messages');
                const chat = msgs && msgs.__bt_chat;
                if (chat && typeof chat.onHidden === 'function') chat.onHidden();
            }
            p.style.display = visible ? 'flex' : 'none';
            if (visible) {
                const msgs = p.querySelector('.bt-messages');
                const chat = msgs && msgs.__bt_chat;
                if (chat && typeof chat.onShown === 'function') chat.onShown();
            }
        });
    }""")
    return container
end

# BonitoAgents logo family (see bonito-logos/README.md for the design notes).
# The SVG doubles as the favicon — every evergreen browser accepts
# `<link rel="icon" type="image/svg+xml">`; the 32px PNG is the fallback.
logo_svg()    = bonito_asset("logo", "bonitoagents-light.svg")
favicon_svg() = logo_svg()
favicon_png() = bonito_asset("logo", "bonitoagents-light-32.png")

# Bonito has no first-class favicon hook on App, so inject the <link> tags
# into <head> on document load. The assets are served by the same hashed
# asset machinery as everything else — resolved to URL STRINGS here because
# a raw `Asset` has no msgpack mapping inside interpolated JS.
function favicon_onload(session::Bonito.Session, node)
    svg_url = Bonito.url(session, favicon_svg())
    png_url = Bonito.url(session, favicon_png())
    Bonito.onload(session, node, js"""(el) => {
        const ensure = (rel, type, href) => {
            let link = document.querySelector(`link[rel="${rel}"]`);
            if (!link) {
                link = document.createElement('link');
                link.rel = rel;
                document.head.appendChild(link);
            }
            if (type) link.type = type;
            link.href = href;
        };
        ensure('icon', 'image/svg+xml', $(svg_url));
        ensure('apple-touch-icon', '', $(png_url));
    }""")
    return node
end

"""
    unified_app(state) → Bonito.App

Single-page app: sidebar on the left, dashboard or chat in the main area
depending on `current_view`. Replaces the old per-project `/p/<id>` routes.
"""
function unified_app(state::ServerState)
    App(; title = "BonitoAgents") do session
        # Per-session view of the shared state. `copy(state, session)` shares
        # the workers/projects/chat_models tables and the lock, but gives this
        # session its OWN connected child of each version Observable (via
        # `map(identity, session, ...)` — auto-deregisters on tab close).
        # `current_view` is per-session (transient navigation state).
        view = copy(state, session)
        current_view = Observable("")
        # Per-session bring-up bookkeeping for the loading view (see
        # LoadingState / project_loading_view). The retry handler clears the
        # recorded error and re-renders, which re-spawns the bring-up task.
        ls = LoadingState()
        on(session, ls.retry) do retry_pid
            isempty(retry_pid) && return
            delete!(ls.errors, retry_pid)
            safe_notify!(current_view)
        end
        # The window's PlotPane handle wraps a BonitoWidgets.Workspace. Created
        # BEFORE the sidebar + unified_main so it can be passed down to the chat
        # panes (ChatPaneRef sets it on each per-session ChatModel view) AND to
        # the sidebar's per-chat file trees (which open files into it); the
        # Workspace itself is built AFTER, with the chat panel as its first member.
        pane = PlotPane()
        sidebar = project_sidebar(session, view, current_view, pane)
        main_panel = unified_main(session, view, current_view, ls, pane)
        # The whole stage is the Workspace: the chat/dashboard is the "chat"
        # panel; opened files and detached `bt_show_app` embeds become more
        # panels the user can tab / split / float (VSCode-style).
        stage, glue_js, _ =
            install_workspace!(session, view, current_view, pane, main_panel)
        shell = DOM.div(
            # MarkdownCSS FIRST: it's the base sheet our styles override.
            # Stylesheet order breaks specificity ties — with MarkdownCSS
            # last, its `.markdown-body pre` light-gray background beat the
            # chat's dark code blocks (see ChatStyles' agent-pre comment).
            Bonito.MarkdownCSS,
            UnifiedShellStyles,
            DashboardStyles,
            ChatStyles,
            SidebarStyles,
            WorkspaceStageStyles,
            Bonito.ConnectionIndicator(),
            sidebar,
            stage,
            # Window-level toast layer (position:fixed) — flashes "can't open …"
            # from the editor open-guard. One per window, bound to pane.toast.
            plotpane_toast_layer(session, pane);
            class = "bt-shell")
        # Wire the bt_show_app detach controller once the shell is in the DOM:
        # the per-tool #bt-slot-<id> / #bt-embed-<id> pairs it moves are all
        # descendants of the shell, guaranteed present by onload.
        Bonito.onload(session, shell, glue_js)
        # Favicon (SVG + PNG fallback) — injected into <head> on load.
        favicon_onload(session, shell)
        shell
    end
end
