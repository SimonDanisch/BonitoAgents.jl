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

const NAME = isempty(ARGS) ? nothing : Regex(join(ARGS, "|"))
ReTestItems.runtests(BonitoAgents;
    nworkers = parse(Int, get(ENV, "BT_TEST_NWORKERS", "4")),
    retries = parse(Int, get(ENV, "BT_TEST_RETRIES", "1")),  # cover transient electron/bind flakes
    name = NAME)
