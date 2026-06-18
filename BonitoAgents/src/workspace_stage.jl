# ── Workspace stage ──────────────────────────────────────────────────────────
# The window's main area (everything right of the sidebar) is a single
# BonitoWidgets.Workspace. The chat/dashboard is the non-closable "chat" panel;
# files open as closable panels; a detached `bt_show_app` embed becomes a
# floating "app" panel. The user tabs / splits / floats them VSCode-style.
#
# `install_workspace!` builds the Workspace + the embed-detach controller and
# returns `(stage_dom, controller_js, pane)`. The chat content is built BEFORE
# this (it needs the `pane` handle) and handed in as the "chat" panel.

using BonitoWidgets: Workspace, Panel, float_panel!, activate_panel!

"""
    install_workspace!(session, state, current_view, pane, chat_content)
        -> (stage_dom, controller_js, pane)

Build the window's [`Workspace`](@ref BonitoWidgets.Workspace): the `chat_content`
as the non-closable "chat" panel, plus the embed-detach controller. Sets
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

    # The floating "app" panel's mount: detached `bt_show_app` embeds are moved
    # in (and back out) by the controller below. Rebuilt each detach (the panel
    # is removed on close), so the `#bt-app-mount` id always resolves to the
    # current one.
    app_content() = DOM.div(
        DOM.div(""; id = "bt-app-mount", class = "bt-app-mount");
        class = "bt-app-frame")

    # Detach: float an "app" panel (or focus the existing one). The controller's
    # `detachApp.on` then moves the embed DOM into the panel's mount.
    on(session, pane.detach_app) do tid
        isempty(tid) && return
        w = pane.workspace[]
        w === nothing && return
        if any(p -> p.id == APP_PANEL_ID, w.panels[])
            activate_panel!(w, APP_PANEL_ID)
        else
            float_panel!(w, Panel(APP_PANEL_ID, app_content(); label = "App", closable = true);
                         x = 120, y = 80, width = 560, height = 420)
        end
    end

    # The controller owns the embed DOM moves. An Observable notified from JS
    # runs its JS subscribers synchronously BEFORE the Julia round-trip, so for
    # the close path (workspace `closed` → auto-remove the panel in Julia) the
    # embed is moved back to its bubble first, then the empty mount is pruned.
    controller_js = js"""
    (shell) => {
        const detachApp  = $(pane.detach_app);
        const restoreApp = $(pane.restore_app);
        const wsClosed   = $(ws.closed);
        const moveNode = (n, parent) => {
            if (window.Bonito && window.Bonito.Sessions && window.Bonito.Sessions.move_dom_node)
                window.Bonito.Sessions.move_dom_node(n, parent, null);
            else parent.appendChild(n);
        };
        const mountEl = () => document.getElementById('bt-app-mount');

        function restoreEmbed(toolId) {
            if (!toolId) return;
            const slot  = document.getElementById('bt-slot-'  + toolId);
            const embed = document.getElementById('bt-embed-' + toolId);
            if (embed && slot) { moveNode(embed, slot); delete slot.dataset.detached; }
            const m = mountEl();
            if (m && m.dataset.toolId === toolId) delete m.dataset.toolId;
        }
        function detachInto(toolId) {
            if (!toolId) return;
            let tries = 40;
            const step = () => {
                const mount = mountEl();
                if (!mount) { if (tries-- > 0) requestAnimationFrame(step); return; }
                const prev = mount.dataset.toolId;
                if (prev && prev !== toolId) restoreEmbed(prev);
                const embed = document.getElementById('bt-embed-' + toolId);
                if (embed) {
                    moveNode(embed, mount);
                    mount.dataset.toolId = toolId;
                    const slot = document.getElementById('bt-slot-' + toolId);
                    if (slot) slot.dataset.detached = '1';
                }
            };
            step();
        }

        detachApp.on(detachInto);
        if (detachApp.value) detachInto(detachApp.value);
        restoreApp.on(restoreEmbed);
        // Closing the app panel (its × on a tab or float) restores the embed
        // before Julia prunes the now-empty mount.
        wsClosed.on((id) => {
            if (id !== $(APP_PANEL_ID)) return;
            const m = mountEl();
            if (m && m.dataset.toolId) restoreEmbed(m.dataset.toolId);
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
    return (stage, controller_js, pane)
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
    Bonito.CSS(".bt-app-frame",
        "width" => "100%", "height" => "100%",
        "display" => "flex", "flex-direction" => "column", "min-height" => "0"),
    Bonito.CSS(".bt-app-mount",
        "flex" => "1 1 0", "min-height" => "0", "overflow" => "auto"),
)
