# BonitoAgents test entry. Every suite is a ReTestItems `@testitem` discovered
# from a `*_test.jl` file:
#   • headless `unit:*` items (no browser),
#   • black-box `e2e:*` items that share ONE long-lived dev_server + electron
#     window per worker (the `SharedServer` @testsetup) and assert only on the
#     rendered DOM.
#
# Subset selection via `Pkg.test(test_args=[...])`, matched against testitem
# names: `["unit"]` (headless), `["e2e:media"]`, `["e2e"]`, etc. No args runs
# everything (CI does this under xvfb). With `nworkers=4` at most four
# dev_servers live at once, each soaking many e2e items to stress cleanup/leak.
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
ReTestItems.runtests(BonitoAgents;
    nworkers = parse(Int, get(ENV, "BT_TEST_NWORKERS", "4")),
    # Default 0: a retry that turns a red item green only hides a real bug or a
    # test we don't understand. The flakes retries used to paper over were real —
    # the chat-bind deadlock (provider-list build), the multi-pane cancel selector
    # leak, the SIGTERM-vs-load worker kill — and are fixed at the root. Keep it 0
    # so any new flake surfaces instead of being silently retried. (Override with
    # BT_TEST_RETRIES if you must, e.g. to triage a suspected-transient locally.)
    retries = parse(Int, get(ENV, "BT_TEST_RETRIES", "0")),
    name = NAME)
