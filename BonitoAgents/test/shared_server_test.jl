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
    end
    return SERVER[]
end

end # module SharedServer
