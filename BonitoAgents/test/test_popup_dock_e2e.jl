# Real E2E for the popup + plotpane dock chain that wasn't covered by the
# headless tests this session. Boots `dev_server` (real worker + BonitoMCP +
# eval bridge), registers a live `bonito_app` tool bubble via the real
# `bt_show_app` MCP handler (no claude needed — host-side direct call), opens
# the unified shell in a real Electron browser, then exercises:
#
#   * the "↗ Detach" button on the tool body → embed migrates into the
#     `#bt-popup-mount` slot, FloatingWindow becomes visible
#   * `window._btPopup.dock()` → embed migrates into `#bt-plotpane-mount`,
#     `#bt-plotpane-dropzone` gains `.bt-plotpane-visible`, FW hides again
#
# This is exactly the dock flow my session-changes batch didn't cover, because
# the resize-handle test had to fake `bt-plotpane-visible` (no real embed
# available). Here the toggle happens for real.
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
        #    skips the ACP bring-up path. Mock transport — we don't need a
        #    live agent, only the chat shell + the live bonito_app embed.
        chat_dir = mktempdir()
        model = BT.ChatModel(h.state, chat_dir;
                              project_id = pid,
                              transport  = BT.MockTransport((o, i) -> nothing))
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
        #    PopupController.detach.
        electron_evaljs(win, js"document.querySelector('.bt-tool-msg .bt-tool-detach').click()")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)) && document.getElementById('bt-embed-' + $(appid)).parentElement.id", "bt-popup-mount")
        @test poll_js(win, js"getComputedStyle(document.querySelector('.bn-floating-window')).display !== 'none' ? 'y':'n'", "y")
        # Plotpane should still be collapsed.
        @test electron_evaljs(win, js"document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')") == false

        # 10. Dock to plotpane — the REAL gesture: drag the floating window's
        #     title bar into the dock zone (the region right of .bt-main).
        #     The controller's drag-to-dock listens on document; the move/up
        #     pair is gesture-scoped.
        electron_evaljs(win, js"""(() => {
            const tb = document.querySelector('.bn-fw-title');
            const main  = document.querySelector('.bt-main');
            const stage = document.querySelector('.bt-stage');
            const sr = stage.getBoundingClientRect(), mr = main.getBoundingClientRect();
            const x = (mr.right + sr.right) / 2, y = (sr.top + sr.bottom) / 2;
            const opts = (cx, cy) => ({ bubbles: true, clientX: cx, clientY: cy });
            tb.dispatchEvent(new PointerEvent('pointerdown', opts(mr.right - 40, sr.top + 20)));
            document.dispatchEvent(new PointerEvent('pointermove', opts(x, y)));
            document.dispatchEvent(new PointerEvent('pointerup', opts(x, y)));
            return true;
        })()""")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)).parentElement.id", "bt-plotpane-app")
        @test poll_js(win, js"document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')", true)
        @test poll_js(win, js"getComputedStyle(document.querySelector('.bn-floating-window')).display === 'none' ? 'y':'n'", "y")
        # The docked app is a TAB.
        @test poll_js(win, js"""(() => {
            const t = document.querySelector('.bt-pp-tab-active .bt-pp-tab-label');
            return t ? t.textContent.slice(0, 5) : 'none';
        })()""", "App ·")

        # 10b. VSCode-style coexistence: open a FILE while the app is docked —
        #      both live as tabs; switching preserves the app embed's DOM.
        # Under the chat model's cwd — that's the server mirror open_file!
        # resolves relative paths against.
        write(joinpath(chat_dir, "notes.md"), "# hello tabs\n")
        electron_evaljs(win, js"""(() => {
            document.querySelector('.bt-messages').__bt_chat.comm.notify(
                { type: 'edit_file', path: 'notes.md' });
            return true;
        })()""")
        @test poll_js(win, js"document.querySelectorAll('.bt-pp-tab').length", 2)
        # The file tab activated; the app embed is hidden but ALIVE.
        @test poll_js(win, js"""(() => {
            const t = document.querySelector('.bt-pp-tab-active .bt-pp-tab-label');
            return t ? t.textContent : 'none';
        })()""", "notes.md")
        @test electron_evaljs(win,
            js"document.querySelector('#dock_app_root') !== null") == true
        @test poll_js(win, js"""(() => {
            const f = document.querySelector('.bt-pp-tabcontent .bt-file-editor');
            return f && f.offsetParent !== null ? 'y' : 'n';
        })()""", "y")
        # Click back to the app tab → embed visible again, file hidden.
        electron_evaljs(win, js"""(() => {
            const tabs = [...document.querySelectorAll('.bt-pp-tab')];
            tabs.find(t => t.textContent.indexOf('App ·') !== -1).click();
            return true;
        })()""")
        @test poll_js(win, js"""(() => {
            const app = document.getElementById('bt-plotpane-app');
            return app && app.style.display !== 'none' &&
                   document.querySelector('#dock_app_root') ? 'y' : 'n';
        })()""", "y")
        # Close the file tab → app tab stays active, pane stays open.
        electron_evaljs(win, js"""(() => {
            const tabs = [...document.querySelectorAll('.bt-pp-tab')];
            tabs.find(t => t.textContent.indexOf('notes.md') !== -1)
                .querySelector('.bt-pp-tab-close').click();
            return true;
        })()""")
        @test poll_js(win, js"document.querySelectorAll('.bt-pp-tab').length", 1)
        @test poll_js(win, js"document.getElementById('bt-plotpane-dropzone').classList.contains('bt-plotpane-visible')", true)

        # 11. Undock via the pane's ⤡ button (plain DOM onclick → observable
        #     → controller): embed back to the floating window.
        electron_evaljs(win, js"""(() => {
            const b = [...document.querySelectorAll('.bt-pp-btn')]
                .find(x => x.textContent === '⤡');
            b.click();
            return true;
        })()""")
        @test poll_js(win, js"document.getElementById('bt-embed-' + $(appid)).parentElement.id", "bt-popup-mount")
        @test poll_js(win, js"getComputedStyle(document.querySelector('.bn-floating-window')).display !== 'none' ? 'y':'n'", "y")
        println("✓ Detach + dock E2E: bubble → popup (⤢ click) → plotpane (drag-to-dock) → popup (⤡), bt-plotpane-visible toggles")

    finally
        for k in ("BONITOAGENTS_SERVER_URL", "BONITOAGENTS_SECRET", "BONITOAGENTS_PROJECT_ID")
            haskey(ENV, k) && delete!(ENV, k)
        end
        win === nothing || (try; close(win.window); catch; end)
        try; close(h); catch; end
    end
end
nothing
