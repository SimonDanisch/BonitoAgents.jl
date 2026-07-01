# BonitoAgents test entry. Every suite is a ReTestItems `@testitem` discovered
# from a `*_test.jl` file:
#   • headless `unit:*` items (no browser),
#   • black-box `e2e:*` items that share ONE long-lived dev_server + electron
#     window per worker (the `SharedServer` @testsetup) and assert only on the
#     rendered DOM.
#
# Subset selection via `Pkg.test(test_args=[...])`, matched against testitem
# names: `["unit"]` (headless), `["e2e:media"]`, `["e2e"]`, etc. No args runs
# everything (CI does this under xvfb). `nworkers` is hardcoded to 1 (not
# configurable) — more than one dev_server at a time (each = electron + worker +
# mock subprocesses) over-subscribes a normal box and fakes timing failures.
#
# Run locally via the system julia (the bundled Pkg mis-resolves the dev
# `[sources]`):
#   env -u JULIA_DEPOT_PATH -u JULIA_LOAD_PATH [DISPLAY=:1] \
#     julia --project=. -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["unit"])'
using ReTestItems, BonitoAgents

# The `e2e:*` app-embed items (`app_*`, `embedded_app`, `keyed_list`) mount a
# live Bonito App through `bt_show_app`, which spins a Malt eval worker on the
# `test/appenv` project. That env must be RESOLVED + PRECOMPILED before the
# worker dials in — otherwise the worker re-resolves the heavy test env on
# first touch and the app mount times out. `test/appenv` pins only dev Bonito
# (v5), so this is a fast cache hit; do it once here, before the workers fork.
let appenv = joinpath(@__DIR__, "appenv"), cur = Base.active_project()
    import Pkg
    try
        Pkg.activate(appenv; io = devnull)
        Pkg.instantiate(; io = devnull)
    finally
        Pkg.activate(cur; io = devnull)
    end
end

const NAME = isempty(ARGS) ? nothing : Regex(join(ARGS, "|"))
# No `retries` kwarg on purpose: we NEVER retry a failing test. ReTestItems already
# defaults to 0; a retry that greens a red item only hides a real bug or a test we
# don't understand (the flakes it used to paper over were all real — chat-bind
# deadlock, multi-pane selector leaks, SIGTERM-vs-load worker kill — found + fixed
# once we stopped retrying). Don't add it back.
ReTestItems.runtests(BonitoAgents;
    nworkers = 1,
    name = NAME)
