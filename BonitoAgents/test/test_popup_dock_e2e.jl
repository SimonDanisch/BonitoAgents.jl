# Real E2E for the detach + dock chain of a live `bt_show_app` embed. Boots
# `dev_server` (real worker + BonitoMCP + eval bridge), registers a live
# `bonito_app` tool bubble via the real `bt_show_app` MCP handler (no claude
# needed — host-side direct call), opens the unified shell in a real Electron
# browser, then exercises the REAL detach/dock path against the current
# BonitoWidgets Workspace contract:
#
#   * the ⤢ Detach button on the tool header → the embed migrates into its OWN
#     floating Workspace panel (`.bw-ws-panel[data-panel-id="app:<tid>"]` inside
#     a `.bw-float`), its live `.bt-app-frame` adopting the embed node.
#   * the float's dock button (`.bw-float-dock`) → the panel docks into the
#     group as a tab; the float disappears.
#   * VSCode-style coexistence: opening a FILE adds a second panel/tab; the app
#     embed's live DOM (`#dock_app_root`) survives the whole time.
#   * closing the app tab (`.bw-tab-close`) → the embed restores to its bubble
#     slot (`bt-slot-<tid>`), `data-detached` cleared, the worker app still live.
#
# MIGRATION NOTE: the old version drove a now-deleted `MockTransport` and
# asserted against an obsolete popup/plotpane DOM (`#bt-popup-mount`,
# `.bn-floating-window`, `#bt-plotpane-dropzone`, `.bt-plotpane-visible`,
# `.bt-pp-tab`, drag-to-dock) — that PopupController/plotpane layer was replaced
# by the BonitoWidgets `Workspace` (verified: zero of those selectors remain in
# src/). The ChatModel is a never-started `MockAgent([])` holder (no turn is
# driven; the app arrives via `show_remote_app_for_project!`). Every assertion
# below was confirmed against the live current DOM before being committed.
const BONITO = "/sim/Programmieren/ClaudeExperiments/dev/Bonito"
include(joinpath(BONITO, "test", "ElectronTests.jl"))
TestWindow(args...; options=Dict{String,Any}("show"=>false,"focusOnWebView"=>false)) =
    Bonito.EWindow(args...; app=get_test_app(), options=options)
electron_evaljs(window, js) = run(window, sprint(show, js))

using Test
import BonitoAgents, BonitoMCP, Bonito
import ElectronCall
using BonitoAgents: now, UTC
const BT = BonitoAgents
const ROOT = "/sim/Programmieren/ClaudeExperiments"

function poll_js(win, js, want; timeout = 40.0)
    deadline = time() + timeout
    local v
    while time() < deadline
        v = electron_evaljs(win, js)
        v == want && return true
        sleep(0.1)
    end
    @info "poll timed out" js = string(js) last = v want
    return false
end

const DEMO = """
using Bonito
Bonito.App(s -> Bonito.DOM.div("popup-dock test"; id = "dock_app_root"))
"""

@testset "Detach + dock chain against a real bonito_app" begin
    h = BT.dev_server()
    win = nothing
    try
        # 1. Wait for the in-process dev worker to register on /worker-ws.
        @test timedwait(() -> !isempty(h.state.workers[]), 20.0) === :ok
        worker_id = first(keys(h.state.workers[]))

        # 2. Register a fake project bound to that worker. We use a path
        #    under the dev worker's projects_root so the worker can find it.
        pid = "popup-" * string(rand(UInt16))
        wpath = joinpath(h.worker_root, "PopupDockTest")
        mkpath(wpath)
        srv_path = joinpath(h.working_dir, "PopupDockTest")
        mkpath(srv_path)
        h.state.projects[][pid] = BT.ProjectInfo(pid, "PopupDockTest",
            worker_id, srv_path, wpath, now(UTC))
        BT.safe_notify!(h.state.projects)

        # 3. Boot the eval dial-back: a trivial bt_show_app makes the worker
        #    dial back over /eval-ws and populate EVAL_WORKERS[pid].
        for (k, v) in BT.eval_dialback_env(h.state, pid); ENV[k] = v; end
        ENV["BONITOAGENTS_SERVER_URL"] = Bonito.online_url(h.state.srv, "")
        BonitoMCP.restart!(BonitoMCP.manager(), ROOT)
        @test BonitoMCP.julia_show_app_handler(Dict(
            "code"     => "using Bonito; Bonito.App(s -> Bonito.DOM.div(\"dial\"))",
            "env_path" => ROOT,
        ))["isError"] == false
        @test timedwait(() -> haskey(BT.EVAL_WORKERS, pid), 30.0) === :ok

        # 4. Build a ChatModel + pre-register it so the sidebar/navigation
        #    skips the ACP bring-up path. A never-started MockAgent holder — we
        #    don't drive a turn, only the chat shell + the live bonito_app embed.
        chat_dir = mktempdir()
        model = BT.ChatModel(h.state, chat_dir;
                              project_id = pid,
                              agent      = BT.MockAgent([]))
        lock(h.state.lock) do; h.state.chat_models[pid] = model; end
        BT.notify_chats!(h.state)

        # 5. Add the live worker app as a `bonito_app` tool bubble. The
        #    placeholder's `jsrender` (in remote_app.jl) calls embed_remote_app
        #    on mount, which produces the actual `bt-embed-<tool_id>` DOM the
        #    detach/dock controller moves around.
        appid = BT.show_remote_app_for_project!(model, DEMO; title = "PopupDockApp")

        # 6. Open the unified shell in a real browser. Wide enough that the
        #    dock zone (stage width minus the capped chat column) clears the
        #    controller's 40px minimum — drag-to-dock correctly no-ops when
        #    there's no room to dock into.
        win = TestWindow(options = Dict{String,Any}(
            "show" => false, "focusOnWebView" => false,
            "width" => 1700, "height" => 950))
        ElectronCall.load(win.window, URI(h.url))
        @test poll_js(win, js"document.body ? 'y' : 'n'", "y")

        # 7. Navigate via the sidebar to PopupDockTest. Wait for the chat to
        #    mount, then expand the bonito_app tool body (the auto-expand event
        #    that `show_remote_app_for_project!` fires is lost when no browser
        #    is yet connected, so the bubble lands collapsed and we click it
        #    here to trigger `tool.render` → embed render via dom_in_js).
        @test poll_js(win,
            js"document.querySelector('.bt-side-item[data-project-id=' + JSON.stringify($(pid)) + ']') ? 'y':'n'",
            "y")
        electron_evaljs(win, js"document.querySelector('.bt-side-item[data-project-id=' + JSON.stringify($(pid)) + ']').click()")
        @test poll_js(win, js"document.querySelector('.bt-text-input') ? 'y':'n'", "y")
        @test poll_js(win, js"document.querySelector('.bt-tool-msg') ? 'y':'n'", "y", timeout = 10.0)
        # Click the tool header → expand → `tool.render` → embed mounts.
        electron_evaljs(win, js"document.querySelector('.bt-tool-msg .bt-tool-header').click()")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)) ? 'y':'n'", "y", timeout = 40.0)
        @test poll_js(win, js"document.querySelector('#dock_app_root') ? 'y':'n'", "y")

        # 8. Sanity: embed is currently in its slot inside the bubble.
        @test electron_evaljs(win, js"document.getElementById('bt-embed-' + $(appid)).parentElement.id") ==
              "bt-slot-" * appid

        # Sanity: the detach affordance is on the pill (there is no global
        # controller object any more — by design; the PopupController is an
        # ES6 module instance reached only through observables).
        @test poll_js(win, js"document.querySelector('.bt-tool-msg .bt-tool-detach') ? 'y':'n'", "y")

        # 9. Detach — the REAL user path: ⤢ on the tool header. The click is
        #    wired in the chat module's createNode (not the tool-body
        #    subsession), routes comm → DetachAppCommand → pane.detach_app →
        #    `float_panel!` (workspace_stage.jl): the embed becomes its OWN
        #    floating Workspace panel and the live embed node is ADOPTED into
        #    that panel's `.bt-app-frame`.
        # `appSel()` resolves the floating/docked app panel by its data-panel-id
        # ("app:<tid>") — JSON.stringify runs browser-side on the id literal.
        appSel = js"(() => document.querySelector('.bw-ws-panel[data-panel-id=' + JSON.stringify('app:' + $(appid)) + ']'))"
        electron_evaljs(win, js"document.querySelector('.bt-tool-msg .bt-tool-detach').click()")
        # The app panel exists and is floating (its content is inside a .bw-float).
        @test poll_js(win, js"""(() => { const p = ($(appSel))(); return (p && p.closest('.bw-float')) ? 'y':'n'; })()""", "y")
        # The live embed node was moved into the panel's frame (not its bubble slot).
        @test poll_js(win, js"""(() => {
            const p = ($(appSel))(); const frame = p && p.querySelector('.bt-app-frame');
            return frame && frame.querySelector('#bt-embed-' + $(appid)) ? 'y':'n'; })()""", "y")
        # The embed's own DOM is alive in the float.
        @test poll_js(win, js"document.querySelector('#dock_app_root') ? 'y':'n'", "y")
        # The inline slot is marked detached (its placeholder shows in the bubble).
        @test poll_js(win, js"""(() => { const s = document.getElementById('bt-slot-' + $(appid));
            return s && s.dataset.detached ? 'y':'n'; })()""", "y")

        # 10. Dock the float into the group — the REAL gesture: the float's dock
        #     button (`.bw-float-dock`). The panel joins the docked group as a
        #     tab; the float disappears; the embed rides along untouched.
        electron_evaljs(win, js"document.querySelector('.bw-float .bw-float-dock').click()")
        @test poll_js(win, js"document.querySelectorAll('.bw-float').length", 0)
        @test poll_js(win, js"""(() => { const p = ($(appSel))(); return (p && !p.closest('.bw-float')) ? 'y':'n'; })()""", "y")
        @test poll_js(win, js"document.querySelector('#dock_app_root') ? 'y':'n'", "y")
        # The docked app is a TAB labelled "App".
        @test poll_js(win, js"""(() => {
            const t = [...document.querySelectorAll('.bw-tab')].find(t => (t.textContent||'').indexOf('App') !== -1);
            return t ? 'y':'n'; })()""", "y")

        # 10b. VSCode-style coexistence: open a FILE while the app is docked —
        #      both live as tabs; switching preserves the app embed's DOM. Under
        #      the chat model's cwd — that's the mirror open_file! resolves
        #      relative paths against.
        write(joinpath(chat_dir, "notes.md"), "# hello tabs\n")
        electron_evaljs(win, js"""(() => {
            document.querySelector('.bt-messages').__bt_chat.comm.notify(
                { type: 'edit_file', path: 'notes.md' });
            return true;
        })()""")
        # A second (file) panel joins; the app panel stays present and its embed
        # stays ALIVE.
        @test poll_js(win, js"document.querySelectorAll('.bw-tab').length", 3)  # chat + app + notes.md
        @test poll_js(win, js"""(() => {
            const t = [...document.querySelectorAll('.bw-tab')].find(t => (t.textContent||'').indexOf('notes.md') !== -1);
            return t ? 'y':'n'; })()""", "y")
        @test electron_evaljs(win, js"document.querySelector('#dock_app_root') !== null") == true
        # Click back to the app tab → it activates; the embed stays alive.
        electron_evaljs(win, js"""(() => {
            const t = [...document.querySelectorAll('.bw-tab')].find(t => (t.textContent||'').indexOf('App') !== -1);
            if (t) t.click(); return true; })()""")
        @test poll_js(win, js"""(() => {
            const t = [...document.querySelectorAll('.bw-tab')].find(t => (t.textContent||'').indexOf('App') !== -1);
            return (t && t.classList.contains('bw-active') && document.querySelector('#dock_app_root')) ? 'y':'n'; })()""", "y")

        # 11. Close the app tab (`.bw-tab-close`) → RESTORE: the embed moves back
        #     to its bubble slot (`bt-slot-<tid>`), `data-detached` cleared, and
        #     the worker app is still live (its DOM survived the round trip).
        electron_evaljs(win, js"""(() => {
            const t = [...document.querySelectorAll('.bw-tab')].find(t => (t.textContent||'').indexOf('App') !== -1);
            const x = t && t.querySelector('.bw-tab-close'); if (x) x.click(); return true; })()""")
        @test poll_js(win, js"""(() => (($(appSel))() ? 'present':'gone'))()""", "gone")
        @test poll_js(win, js"""(() => { const e = document.getElementById('bt-embed-' + $(appid));
            return e && e.parentElement.id === 'bt-slot-' + $(appid) ? 'y':'n'; })()""", "y")
        @test poll_js(win, js"""(() => { const s = document.getElementById('bt-slot-' + $(appid));
            return s && !s.dataset.detached ? 'y':'n'; })()""", "y")
        @test poll_js(win, js"document.querySelector('#dock_app_root') ? 'y':'n'", "y")

        println("✓ Detach + dock E2E: bubble → float (⤢) → docked tab (.bw-float-dock) → " *
                "file coexistence → restore-to-slot (tab close); embed alive throughout")

    finally
        for k in ("BONITOAGENTS_SERVER_URL", "BONITOAGENTS_SECRET", "BONITOAGENTS_PROJECT_ID")
            haskey(ENV, k) && delete!(ENV, k)
        end
        win === nothing || (try; close(win.window); catch; end)
        try; close(h); catch; end
    end
end
nothing
