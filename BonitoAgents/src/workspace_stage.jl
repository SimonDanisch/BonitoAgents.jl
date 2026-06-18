# ── Workspace stage ──────────────────────────────────────────────────────────
# The window's main area (everything right of the sidebar) is a single
# BonitoWidgets.Workspace. The chat/dashboard is the non-closable "chat" panel;
# files open as closable panels; each detached `bt_show_app` embed becomes its
# own closable panel. The user tabs / splits / floats them VSCode-style.
#
# `install_workspace!` builds the Workspace + the embed restore-on-close glue and
# returns `(stage_dom, glue_js, pane)`. The chat content is built BEFORE this (it
# needs the `pane` handle) and handed in as the "chat" panel.

using BonitoWidgets: Workspace, Panel, float_panel!, activate_panel!

"""
    install_workspace!(session, state, current_view, pane, chat_content)
        -> (stage_dom, glue_js, pane)

Build the window's [`Workspace`](@ref BonitoWidgets.Workspace): the `chat_content`
as the non-closable "chat" panel, plus the embed restore-on-close glue. Sets
`pane.workspace[]` so chat code (`open_file!`, `pane.detach_app`) can drive it.
"""
function install_workspace!(session::Bonito.Session,
                            state::ServerState,
                            current_view::Observable{String},
                            pane::PlotPane,
                            chat_content)
    chat_panel = Panel("chat", DOM.div(chat_content; class = "bt-main");
                       label = "Chat", closable = false)
    # `hide_single_tab`: with only the chat open there's nothing to manage, so
    # the workspace drops its tab bar and the chat goes full-bleed (like a plain
    # app). The bar appears the moment a second panel (a file / detached app)
    # joins or the user splits.
    ws = Workspace(chat_panel; hide_single_tab = true,
                   style = Bonito.Styles("min-height" => "0"))
    pane.workspace[] = ws

    # The chat panel doubles as the Home/dashboard view (current_view == ""). A
    # sidebar click (Home or a project) must (1) bring this panel to the front —
    # the user may have a file/app tab active — and (2) relabel its tab so "Home"
    # reads as Home, not a stale "Chat". `Panel.label` is an Observable, so the
    # tab updates live.
    relabel_chat_panel!() = (chat_panel.label[] = isempty(current_view[]) ? "Home" : "Chat")
    relabel_chat_panel!()
    on(session, current_view) do _
        relabel_chat_panel!()
        activate_panel!(ws, "chat")
    end

    # A detached app's panel content: an empty frame the embed is moved INTO by
    # the glue below once the panel mounts. (A `Bonito.onload` on the content
    # doesn't fire reliably through the workspace's parking-pool shipping path,
    # so the adopt is driven from the shell-level `detach_app` handler instead.)
    # Rendered once by BonitoWidgets and thereafter relocated by identity
    # (dock/float/split/tab), so the live sub-session rides along untouched.
    app_adopt_content(_tid) = DOM.div(; class = "bt-app-frame")

    # Detach: each `bt_show_app` embed becomes its OWN floating panel whose
    # content ADOPTS the live embed node (see `app_adopt_content`). A re-detach
    # just focuses the existing panel. Once the panel exists, BonitoWidgets owns
    # every move (dock / float / split / tab) — it relocates panel content by
    # identity, in JS, with no Julia round-trip — so there is no shared mount and
    # no controller racing the workspace re-render (the old `#bt-app-mount` +
    # `getElementById` design, which could resolve a stale node and silently drop
    # the move, leaving the embed inline and the panel blank).
    on(session, pane.detach_app) do tid
        isempty(tid) && return
        w = pane.workspace[]
        w === nothing && return
        pid = app_panel_id(tid)
        if any(p -> p.id == pid, w.panels[])
            activate_panel!(w, pid)
        else
            float_panel!(w, Panel(pid, app_adopt_content(tid); label = "App", closable = true);
                         x = 120, y = 80, width = 560, height = 420)
        end
    end

    # The two bridges between chat DOM and workspace DOM, both keyed by tool id
    # and scoped to ONE per-app panel (`app:<tid>`) — no shared mount, no
    # first-in-tree `getElementById`:
    #   • ADOPT (on detach): once `float_panel!` has mounted the panel, move the
    #     live embed node into its `.bt-app-frame`. The panel arrives a round-trip
    #     after `detach_app` fires, so we rAF-retry until its frame exists.
    #   • RESTORE (on close): `ws.closed` is notified from JS, so this runs
    #     synchronously BEFORE Julia's `remove_panel!` prunes the node — grab the
    #     embed now and move it back to its bubble slot.
    # Embeds/slots are resolved through the chat's node cache (`toolSlot`), which
    # finds them even on a bubble the virtual scroll currently holds detached.
    glue_js = js"""
    (shell) => {
        const detachApp = $(pane.detach_app);
        const closedObs = $(ws.closed);
        const esc = (s) => (window.CSS ? CSS.escape(s) : s);
        const move = (n, p) => { if (!n || !p) return;
            if (window.Bonito && window.Bonito.Sessions && window.Bonito.Sessions.move_dom_node)
                window.Bonito.Sessions.move_dom_node(n, p, null);
            else p.appendChild(n); };
        function adopt(tid) {
            if (!tid) return;
            let tries = 90;
            const step = () => {
                const panel = shell.querySelector('.bw-ws-panel[data-panel-id="app:' + esc(tid) + '"]');
                const frame = panel && panel.querySelector('.bt-app-frame');
                if (!frame) { if (tries-- > 0) requestAnimationFrame(step); return; }
                if (frame.querySelector('.bt-embed')) return;          // already adopted
                $(ChatLib).then(lib => {
                    const body  = lib.toolSlot(tid);
                    const embed = body && body.querySelector('.bt-embed');
                    const slot  = body && body.querySelector('.bt-slot');
                    if (embed) { move(embed, frame); if (slot) slot.dataset.detached = '1'; }
                });
            };
            step();
        }
        detachApp.on(adopt);
        if (detachApp.value) adopt(detachApp.value);
        closedObs.on((pid) => {
            if (typeof pid !== 'string' || pid.indexOf('app:') !== 0) return;
            const tid = pid.slice(4);
            const panel = shell.querySelector('.bw-ws-panel[data-panel-id="' + esc(pid) + '"]');
            const embed = panel && panel.querySelector('.bt-embed');   // grab NOW (sync)
            if (!embed) return;
            $(ChatLib).then(lib => {
                const body = lib.toolSlot(tid);
                const slot = body && body.querySelector('.bt-slot');
                if (slot) { move(embed, slot); delete slot.dataset.detached; }
            });
        });
    }
    """

    # Theme the BonitoWidgets chrome (tab bars, bodies, gutters, floats) to the
    # app's LIGHT palette — otherwise the workspace renders with BonitoWidgets'
    # dark defaults and the chat panel's body shows as dark voids around the
    # content. `:root:root` (what Theme emits) outranks the dark media query.
    ws_theme = BonitoWidgets.Theme(scheme = :light;
        bg         = "var(--bt-bg)",
        bg_panel   = "var(--bt-surface)",
        bg_bar     = "var(--bt-surface-2)",
        bg_hover   = "rgba(15,23,42,0.05)",
        text       = "var(--bt-text)",
        text_muted = "var(--bt-text-muted)",
        accent     = "var(--bt-accent)",
        accent_bg  = "rgba(59,130,246,0.10)",
        border     = "var(--bt-border)",
        radius     = "var(--bt-radius)",
        radius_sm  = "var(--bt-radius-sm)",
        font       = "'Inter', system-ui, -apple-system, sans-serif",
    )
    stage = DOM.div(ws_theme, ws; class = "bt-stage")
    return (stage, glue_js, pane)
end

const WorkspaceStageStyles = Bonito.Styles(
    # The stage hosts the Workspace; it fills the viewport minus the sidebar.
    Bonito.CSS(".bt-stage",
        "flex" => "1 1 auto", "min-width" => "0", "min-height" => "0",
        "position" => "relative", "overflow" => "hidden",
        "display" => "flex"),
    # The chat/dashboard panel FILLS its group body (no floating-in-voids). The
    # chat owns the whole slot; the dashboard, being card-based, caps + centers
    # its own sections (below) so they stay readable when the slot is wide.
    Bonito.CSS(".bt-stage .bw-ws-panel > .bt-main",
        "flex" => "1 1 0", "width" => "100%",
        "min-width" => "0", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column",
        "background" => "var(--bt-bg)"),
    Bonito.CSS(".bt-main > .bt-main-views",
        "flex" => "1 1 auto", "width" => "100%", "min-width" => "0", "min-height" => "0"),
    # Keep the dashboard's stacked sections at a comfortable centered width even
    # though the panel now fills edge-to-edge. `.bt-stats` is targeted directly
    # too: it's a `map(...)` (reactive), so Bonito wraps it in an inline
    # `bonito-fragment` that ignores `max-width` — without this it escapes the
    # `> *` cap and stretches full-width while every other section stays at 1080.
    Bonito.CSS(".bt-stage .bt-dash > *, .bt-stage .bt-dash .bt-stats",
        "max-width" => "1080px", "margin-left" => "auto", "margin-right" => "auto",
        # border-box so a section's own padding (e.g. .bt-stats) counts INSIDE the
        # 1080 cap — otherwise padded sections render ~32px wider than the rest.
        "box-sizing" => "border-box"),

    # ── Detachable app embed (bt_show_app) ───────────────────────────────────
    Bonito.CSS(".bt-embed-frame",
        "display" => "flex", "flex-direction" => "column", "min-width" => "0"),
    Bonito.CSS(".bt-embed-controls",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "2px 0 6px"),
    Bonito.CSS(".bt-detach-placeholder",
        "color" => "var(--bt-text-muted)",
        "font-size" => "11px", "font-style" => "italic",
        "display" => "none"),
    # The controller marks the slot detached while the embed lives in the app
    # panel; reveal the placeholder in the now-empty inline spot.
    Bonito.CSS(".bt-embed-frame:has(.bt-slot[data-detached]) .bt-detach-placeholder",
        "display" => "inline"),
    # A detached app's panel content: the frame fills the panel and scrolls; the
    # adopted embed (moved in by `app_adopt_content`) fills the frame.
    Bonito.CSS(".bt-app-frame",
        "width" => "100%", "height" => "100%",
        "display" => "flex", "flex-direction" => "column",
        "min-height" => "0", "overflow" => "auto"),
    Bonito.CSS(".bt-app-frame > .bt-embed",
        "flex" => "1 1 0", "min-height" => "0", "width" => "100%"),
)
