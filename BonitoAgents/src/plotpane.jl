# ── PlotPane: the Julia-side handle for the window's workspace ────────────────
# One per browser window. The window's main area is a BonitoWidgets.Workspace
# (split-tree of tab groups + floating windows). The chat/dashboard is one
# (non-closable) "chat" panel; every file the user opens is another panel; a
# detached `bt_show_app` embed is yet another. The user can tab / split / float
# any of them — VSCode-style.
#
# `install_workspace!` (workspace.jl) builds the Workspace and this handle, then
# passes the handle DOWN the object graph — unified_main → ChatPaneRef → the
# per-session ChatModel view — so chat code drives the workspace through plain
# Julia + Observables (`open_file!`, `pane.detach_app`). No window globals.
#
#   • File panels: `open_file!(pane, model, path)` adds (or activates) a closable
#     panel whose content is a Monaco `FileEditor`. The Workspace renders the
#     editor ONCE and only ever *moves* its node, so cursor/scroll/unsaved edits
#     survive every tab switch, split, and float.
#   • App panels: `bt_show_app` embeds live inline in their chat bubble. The ⤢
#     button routes a `DetachAppCommand` → `pane.detach_app`; each detached embed
#     becomes its OWN BonitoWidgets panel whose content ADOPTS the live embed
#     node (`Bonito.move_dom_node`, which keeps its WebSocket state alive). From
#     there BonitoWidgets owns the move/dock/float/split entirely in JS (it moves
#     panel content by identity) — no shared mount, no Julia controller. Closing
#     the panel moves the embed back to its bubble.

struct PlotPane
    # Set to the BonitoWidgets.Workspace once `install_workspace!` builds it.
    # Untyped (Ref{Any}) so plotpane.jl needn't depend on BonitoWidgets ordering.
    workspace  :: Base.RefValue{Any}
    # `bt_show_app` detach: a tool_id pulse → float (or focus) that embed's panel.
    detach_app  :: Observable{String}
    # Transient window-level notice. Setting a non-empty string flashes a toast
    # that auto-dismisses in JS — reachable from the editor open-guard via
    # `model.plotpane` so a file we can't open says so instead of opening blank.
    toast       :: Observable{String}
end

PlotPane() = PlotPane(Ref{Any}(nothing), Observable(""), Observable(""))

"""
    show_toast!(pane::PlotPane, msg)

Flash a transient notice in the window. No-op when `pane` is `nothing` (chat
rendered outside the unified shell). Re-sends even if the text is unchanged so
two identical failures still each blink.
"""
function show_toast!(pane::PlotPane, msg::AbstractString)
    # notify=true forces a fire even when the string equals the current value,
    # so clicking the same un-openable file twice re-shows the toast.
    pane.toast[] = ""
    pane.toast[] = String(msg)
    return nothing
end
show_toast!(::Nothing, ::AbstractString) = nothing

# Window-level toast layer — one transient bubble bound to `pane.toast`. A
# non-empty value shows it for ~3.2s then fades; the JS owns the timer so the
# server never has to schedule a clear. Mounted once in the window shell.
function plotpane_toast_layer(session::Bonito.Session, pane::PlotPane)
    node = DOM.div(DOM.span(pane.toast; class = "bt-toast-text");
                   class = "bt-toast", dataShown = "false")
    Bonito.onjs(session, pane.toast, js"""(msg) => {
        const el = $(node);
        if (!el) return;
        if (!msg) { el.dataset.shown = 'false'; return; }
        el.dataset.shown = 'true';
        if (el.__btToastTimer) clearTimeout(el.__btToastTimer);
        el.__btToastTimer = setTimeout(() => { el.dataset.shown = 'false'; }, 3200);
    }""")
    return node
end

file_tab_id(path::AbstractString) = "file:" * String(path)
# Per-embed panel id. One panel per detached `bt_show_app`, keyed by its tool id
# — so several apps can be detached at once, each its own tab/float, and a
# re-detach just focuses the existing one.
app_panel_id(tool_id::AbstractString) = "app:" * String(tool_id)

# ── Tool-body wrapper helper ─────────────────────────────────────────────────
# Wrap a `RemoteRef` (or any rendered app body) in the slot/embed
# pair the workspace controller needs, plus a placeholder string that takes over
# the inline spot while the embed is detached.
#
#   <div class="bt-embed-frame">
#     <div class="bt-embed-controls">
#       <span class="bt-detach-placeholder">In floating window — close it to bring this back</span>
#     </div>
#     <div class="bt-slot"  id="bt-slot-<tool_id>">
#       <div class="bt-embed" id="bt-embed-<tool_id>"> [rendered body] </div>
#     </div>
#   </div>
"""
    wrap_for_detach(tool_id, body) -> Node

Wrap a tool body so the workspace controller can re-parent it into a floating
"app" panel (⤢ Detach) and back (close → restore-to-slot).
"""
function wrap_for_detach(tool_id::AbstractString, body)
    tid = String(tool_id)
    placeholder = DOM.span("In floating window — close it to bring this back";
                          class = "bt-detach-placeholder")
    DOM.div(
        DOM.div(placeholder; class = "bt-embed-controls"),
        DOM.div(
            DOM.div(body; id = "bt-embed-$(tid)", class = "bt-embed");
            id = "bt-slot-$(tid)", class = "bt-slot");
        class = "bt-embed-frame")
end
