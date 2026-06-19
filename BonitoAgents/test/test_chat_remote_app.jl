# End-to-end (TestKit): a live interactive worker app appears as a bubble IN THE
# CHAT, rendered by the real ChatModel and driven through a real Electron browser.
#
# Migration. The old version hand-built an Electron window, a bare ChatModel over
# a `MockTransport`, and wired the dial-back manually. Fake transports are gone;
# instead this drives the WHOLE production stack through the TestKit harness — a
# real `dev_server` + worker + ACP wire, with only the agent's behaviour faked.
# The agent emits a single `bt_show_app(DEMO)` event, which the dispatcher runs
# through real `BonitoMCP.julia_show_app_handler`: a Malt eval worker dials back
# over `/eval-ws` (raw Bonito frames, no Malt on the frame path), the app is
# registered + prerendered, and the chat embeds it as a `BonitoAppMsg` bubble.
#
# Asserted in the REAL DOM:
#   1. the embedded app renders (its `#result` span mounts, showing the initial
#      DOUBLED value "0"), and
#   2. a remote Observable round-trips to the DOM: `COUNT.notify(7)` in the
#      browser → the worker's `on(COUNT)` sets `DOUBLED[] = 14` → that relays
#      back through the bridge and the `#result` span updates to "14"; the
#      separate worker PROCESS is confirmed to have seen `COUNT[] == 7`.
#
# Modeled on test_bt_show_app_e2e.jl (TestKit embed) + test_real_e2e.jl (remote
# Observable round-trip + worker introspection via BonitoMCP's own Malt link).

using Test, JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents, BonitoMCP
const TK   = TestKit
const BT   = BonitoAgents
const Malt = BonitoAgents.Malt
using .TestKit: bt_show_app, text, end_turn

# env_path for the eval worker. The root project has the working Bonito the dev
# test stack uses (an empty tmp Project.toml would have no registered Bonito and
# Pkg.instantiate is off-limits per CLAUDE.md).
const ROOT = "/sim/Programmieren/ClaudeExperiments"

# Worker introspection goes through BonitoMCP's OWN Malt link (the dial-back
# carries raw Bonito frames, not Malt; the EvalBridge holds no worker handle).
function root_worker()
    for s in values(BonitoMCP.manager().sessions)
        s.env_path == ROOT && BonitoMCP.is_alive(s) && return s.worker
    end
    error("no live ROOT eval worker")
end

# The app source bt_show_app evaluates (its last value is a `Bonito.App`). The
# COUNT/DOUBLED globals let the test read + drive worker state across the bridge:
# COUNT is driven from JS, the worker doubles it into DOUBLED, which renders into
# `#result`. The `onjs` taps register both observables in the browser's global
# namespace so `lookup_global_object` can find them.
const DEMO = """
using Bonito
global COUNT = Bonito.Observable(0); global DOUBLED = Bonito.Observable(0)
Bonito.App() do s
    Bonito.on(s, COUNT) do c; DOUBLED[] = 2c; end
    Bonito.onjs(s, COUNT,   Bonito.@js_str("(x)=>{}"))
    Bonito.onjs(s, DOUBLED, Bonito.@js_str("(x)=>{}"))
    Bonito.DOM.div("counter=", Bonito.DOM.span(DOUBLED; id="result"))
end
"""

@testset "live worker app in the chat (real browser)" begin
    # Fresh eval worker: a worker from a previous test has `__BT_DIALED` true
    # against an OLD dev_server's WS that's long gone, so it won't dial THIS
    # dev_server's `/eval-ws` without a restart.
    BonitoMCP.restart!(BonitoMCP.manager(), ROOT)

    s = TK.dev_server(; agent = msg -> [
        text("Here's the live counter app."),
        bt_show_app(DEMO; env_path = ROOT, id = "ta-remote-1"),
        text("Drive it with COUNT."),
    ])
    try
        TK.open_browser(s; width = 1280, height = 880)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        TK.send_message(s, "please show me the live counter app")

        # The bt_show_app chain spins up a Malt worker, registers an app, dials a
        # fresh WS back, embeds it. Heavier than bt_eval — give it 90s cold.
        TK.wait_for(s, "BonitoAppMsg completed",
            """document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent === 'completed'""";
            timeout = 90)
        # The eval worker dialed OUR dev_server's /eval-ws and is driveable.
        @test timedwait(() -> haskey(BT.EVAL_WORKERS, pid), 30.0) === :ok

        # (1) the embedded app rendered: its #result span is in the DOM and shows
        # the initial DOUBLED value "0". Auto-expand mounts the body once app_id
        # lands; give it a beat.
        @test TK.wait_for(s, "embed #result rendered",
            "!!document.querySelector('#result')"; timeout = 30) == true
        @test TK.wait_for(s, "#result shows initial 0",
            "document.querySelector('#result').textContent === '0'"; timeout = 10) == true

        # (2) remote Observable round-trip. The embed's wrapper carries the bridge
        # namespace prefix on `data-bonito-remote`; COUNT's global key is
        # "$prefix/$(COUNT.id)". Notifying it from JS drives the worker's
        # on(COUNT) → DOUBLED = 14, which relays back to the DOM.
        prefix = TK.eval_js(s,
            "document.querySelector('[data-bonito-remote]')?.getAttribute('data-bonito-remote') || ''")
        @test !isempty(prefix)
        count_id  = Malt.remote_eval_fetch(root_worker(), :(COUNT.id))
        count_key = "$prefix/$count_id"

        TK.eval_js(s, "Bonito.lookup_global_object($(JSON.json(count_key))).notify(7); true")
        @test TK.wait_for(s, "#result round-trips to 14",
            "document.querySelector('#result').textContent === '14'"; timeout = 15) == true
        # The separate worker PROCESS actually saw the new value.
        @test timedwait(() -> Malt.remote_eval_fetch(root_worker(), :(COUNT[])) == 7, 10.0) === :ok

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-remote-app.png"))
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
