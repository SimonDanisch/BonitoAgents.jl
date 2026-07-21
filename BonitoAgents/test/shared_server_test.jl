# Shared, long-lived dev server for the black-box e2e testitems.
#
# ReTestItems evaluates a `@testsetup` module ONCE per worker process and
# memoises it for that worker's whole lifetime, reused by every testitem that
# lists it in `setup=[...]`. So with `nworkers=4` we get at most FOUR live
# `dev_server`+electron instances, each soaking through all the e2e testitems
# routed to its worker. That long life is deliberate: it exercises the
# cleanup/leak paths under real accumulation (many chats opened/closed against
# one server) instead of a fresh server per test. Worker exit kills the
# subprocess, tearing the server down — no manual teardown hook needed.
#
# Everything here drives the app BLACK-BOX: a real server reachable at a URL,
# driven only through electron (DOM events + eval_js). No server-state
# introspection in assertions — testitems assert on the rendered DOM only.

@testsetup module SharedServer

include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Lazily-started, per-worker singletons.
const SERVER = Ref{Any}(nothing)

# Default agent: a plain echo. Each testitem swaps `server().agent_fn[]` to its
# own scenario before driving the UI, so suites don't interfere.
default_agent(prompt) = [TK.text("echo: $(prompt)"), TK.end_turn()]

# The live-app e2e suites (app_reload, eval_embed_park, bt_eval*) all eval in this
# one env; the FIRST live mount pays ~5s of cold Julia compilation of the render
# path (host `render_eval_html` + the worker's Bonito App/observable
# serialization). On a slow CI runner that cold JIT can blow a suite's tight
# "first value" wait. Warm it ONCE per worker process with a throwaway live mount,
# exactly like the evalenv `Pkg.instantiate` warmup — NOT a timeout mask.
const EVALENV = abspath(joinpath(@__DIR__, "evalenv"))
# Mirror the real live-app suites' structure (Observable + map + a button with a
# js onclick) so the warmup JITs the SAME render/observable/event path they hit,
# not a thinner subset.
const WARM_APP = """using Bonito
App() do
    clicks = Observable(0)
    out = map(c -> "WARM=" * string(c), clicks)
    btn = DOM.div("bump"; class="warm-btn",
                  onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
    DOM.div(DOM.span("WARM "), DOM.span(out; class="warm-out"), btn; style="padding:8px")
end"""
warm_agent(_prompt) = Any[TK.bt_eval(WARM_APP; env_path = EVALENV, id = "warmup")]

function warm_render!(s)
    @info "SharedServer: warming the live-render path (one-time JIT)"
    t0 = time()
    prev = s.agent_fn[]
    s.agent_fn[] = warm_agent
    try
        # `new_chat` resets the dial-back on exit, so the warmup leaves no binding
        # for the first real suite's chat to inherit.
        TK.new_chat(s; title = "RenderWarmup")
        TK.send_message(s, "warm")
        TK.wait_for(s, "render path warm",
                    "document.body.innerText.includes('WARM')"; timeout = 120)
        @info "SharedServer: render path warmed" secs = round(time() - t0; digits = 1)
    catch e
        @warn "SharedServer render warmup FAILED (first live mount will pay cold JIT)" exception = e
    finally
        s.agent_fn[] = prev
    end
    return nothing
end

"""
    server() -> TestServer

The worker's shared dev server + open electron window, started on first use and
reused for the rest of the worker's life.
"""
function server()
    if SERVER[] === nothing
        # Mock agent uses TestKit's default tiny `test/mocks` env (instantiate it
        # once: `julia --project=test/mocks -e 'using Pkg; Pkg.instantiate()'`) —
        # its small manifest keeps the per-chat mock-agent cold start fast, which
        # matters under load (a big env can blow the 90s chat-bind timeout).
        s = TK.dev_server(agent = default_agent)
        TK.open_browser(s)
        SERVER[] = s
        warm_render!(s)     # JIT the live-render path once (see above)
    end
    return SERVER[]
end

end # module SharedServer
