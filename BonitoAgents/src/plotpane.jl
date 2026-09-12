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
    # The window's ONE progress/notice channel — a `BusyState` snapshot
    # (progress.jl) rendered by the single `progress_overlay` card the shell
    # mounts. Long-running work (a chat's "continue on worker", the dashboard's
    # syncs, imports and copies) reports into it with
    # `busy_start!`/`busy_event!`/`busy_done!`/`busy_fail!`; one-line notices go
    # through `show_toast!` / `show_problem!` below. Reachable from chat code via
    # `model.plotpane`, which is how a file that won't open says so instead of
    # opening blank.
    progress    :: Observable{Any}
    # "Show this project in this window" — a project id pulse that
    # `install_workspace!` forwards to the window's `current_view`. Chat-side
    # code reaches the window through `model.plotpane` and nothing else, so this
    # is how a chat navigates the window (the header's Debug button opens the
    # debug chat with it). Empty string = no-op.
    navigate    :: Observable{String}
end

PlotPane() = PlotPane(Ref{Any}(nothing), Observable(""),
                      Observable{Any}(BUSY_IDLE), Observable(""))

"""
    show_toast!(pane::PlotPane, msg)

Report a one-line OUTCOME in the window's progress card ("Continued on Bosgame",
"Can't open foo.bin"). It shows for a few seconds and fades. No-op when `pane`
is `nothing` (chat rendered outside the unified shell).

For a FAILURE use [`show_problem!`](@ref) instead: a message the user has to act
on must not be on a timer.
"""
show_toast!(pane::PlotPane, msg::AbstractString) = busy_done!(pane.progress, msg)
show_toast!(::Nothing, ::AbstractString) = nothing

"""
    show_problem!(pane::PlotPane, headline, detail = "")

Report a failure in the window's progress card. It STAYS until the user
dismisses it and its text is selectable and copyable — the whole reason this is
not a toast. `detail` is the full error (see `error_detail`); the headline says
which operation failed.
"""
show_problem!(pane::PlotPane, headline::AbstractString, detail::AbstractString = "") =
    busy_fail!(pane.progress, headline, detail)
show_problem!(::Nothing, ::AbstractString, ::AbstractString = "") = nothing

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
