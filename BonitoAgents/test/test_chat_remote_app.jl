# End-to-end: a live interactive worker app appears as a bubble IN THE CHAT,
# rendered by the real ChatModel, driven through a real Electron browser. The app
# lives in a dial-back eval worker (the production path: the worker dials the dev
# server and the Bonito protocol is piped RAW over that socket — no Malt on the
# frame path) and is added to the chat via `show_remote_app_for_project!`.
const BONITO = "/sim/Programmieren/ClaudeExperiments/dev/Bonito"
include(joinpath(BONITO, "test", "ElectronTests.jl"))
TestWindow(args...; options=Dict{String,Any}("show"=>false,"focusOnWebView"=>false)) =
    Bonito.EWindow(args...; app=get_test_app(), options=options)
electron_evaljs(window, js) = run(window, sprint(show, js))

using Test
import BonitoAgents, BonitoMCP
const BT = BonitoAgents
const Malt = BonitoAgents.Malt
import Bonito
using Bonito: DOM, @js_str
const ROOT = "/sim/Programmieren/ClaudeExperiments"

# Worker introspection goes through BonitoMCP's own Malt link (the dial-back
# carries raw Bonito frames, not Malt; the EvalBridge holds no worker handle).
function root_worker()
    for s in values(BonitoMCP.manager().sessions)
        s.env_path == ROOT && BonitoMCP.is_alive(s) && return s.worker
    end
    error("no live ROOT eval worker")
end

function poll_js(win, js, want; timeout=40)
    t = time() + timeout; local v
    while time() < t; v = electron_evaljs(win, js); v == want && return true; sleep(0.1); end
    @info "poll timed out" js=string(js) last=v want; false
end

# `show_remote_app!` ships this source to the worker (register control), where it's
# `include_string`-d to an App. The COUNT/DOUBLED globals let the test read worker state.
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
    h = BT.dev_server()
    win = nothing
    try
        pid = "chat-" * string(rand(UInt16))
        for (k,v) in BT.eval_dialback_env(h.state, pid); ENV[k] = v; end
        ENV["BONITOAGENTS_SERVER_URL"] = Bonito.online_url(h.state.srv, "")
        BonitoMCP.restart!(BonitoMCP.manager(), ROOT)
        # Establish the dial-back bridge: a trivial bt_show_app makes the worker dial.
        @test BonitoMCP.julia_show_app_handler(
            Dict("code"=>"using Bonito; Bonito.App(s->Bonito.DOM.div(\"dial\"))", "env_path"=>ROOT))["isError"] == false
        @test timedwait(()->haskey(BT.EVAL_WORKERS, pid), 30.0) === :ok

        # The real ChatModel, served BY THE DEV SERVER so the embed's init `.bin`
        # resolves against the same asset_host the bridge registered it on.
        model = BT.ChatModel(h.state, mktempdir(); project_id=pid, transport=BT.MockTransport((o,i)->nothing))
        Bonito.route!(h.state.srv, "/chat-test" => Bonito.App(session -> DOM.div(model)))
        win = TestWindow()
        ElectronCall.load(win.window, URI("http://127.0.0.1:$(h.state.srv.port)/chat-test"))
        @test poll_js(win, js"document.body ? 'yes':'no'", "yes")

        # Add the live app to the chat AFTER the browser is connected → a bonito_app
        # ToolMsg bubble → auto-expand → ToolRenderCommand → embed.
        BT.show_remote_app_for_project!(model, DEMO)
        @test poll_js(win, js"document.querySelector('#result') ? 'yes':'no'", "yes")
        @test electron_evaljs(win, js"document.querySelector('#result').textContent") == "0"

        # The proxied namespace prefix is on the embed's wrapper; build COUNT's key.
        prefix = electron_evaljs(win, js"document.querySelector('[data-bonito-remote]')?.getAttribute('data-bonito-remote') || ''")
        @test !isempty(prefix)
        count_id = Malt.remote_eval_fetch(root_worker(), :(COUNT.id))
        count_key = "$prefix/$count_id"

        electron_evaljs(win, js"Bonito.lookup_global_object($(count_key)).notify(7)")
        @test poll_js(win, js"document.querySelector('#result').textContent", "14")
        @test Malt.remote_eval_fetch(root_worker(), :(COUNT[])) == 7
        println("✓ live worker app renders + drives as a real ChatModel bubble in a browser")
    finally
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
        win === nothing || (try; close(win.window); catch; end)
        try; close(h); catch; end
    end
end
nothing
