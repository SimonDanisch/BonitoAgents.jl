# BonitoAgents test entry. Every suite is a ReTestItems `@testitem` discovered
# from a `*_test.jl` file:
#   • headless `unit:*` items (no browser),
#   • black-box `e2e:*` items that share ONE long-lived dev_server + electron
#     window per worker (the `SharedServer` @testsetup) and assert only on the
#     rendered DOM.
#
# ⚠ E2E POLICY (STRICT — see CONVENTIONS.md "E2E tests — STRICT policy"): an
# `e2e:*` item reproduces EXACTLY what a user hits — the REAL dev_server + a REAL
# electron browser driven by URL, asserting ONLY on the rendered DOM. NO manual
# setup: never hand-spawn Malt/eval workers, never call handlers /
# `render_eval_html` / internals directly, never bypass the chat (importing `Malt`
# or calling a `*_handler` in an e2e item is a bug). Eval packages → a committed
# test env (like `test/evalenv`) + warmup, NOT a runtime-built tmp project.
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

# `e2e:bt_eval_types` runs a Malt eval worker on the committed `test/evalenv`
# project (dev Bonito + DataFrames/Colors/ImageShow/Tables for the render-type
# cases). That env must be RESOLVED + PRECOMPILED before the worker dials in —
# otherwise the worker re-resolves the heavy env on first touch and the
# render/mount times out. The packages are precompiled in the depot, so this is a
# fast cache hit; do it once here, before the workers fork.
let cur = Base.active_project()
    import Pkg
    for env in ("evalenv",)
        path = joinpath(@__DIR__, env)
        isdir(path) || continue
        try
            Pkg.activate(path; io = devnull)
            Pkg.instantiate(; io = devnull)
        catch e
            # Best-effort warmup: a failure here only makes that env's e2e items
            # re-resolve on first touch — it must NOT abort the whole suite (e.g.
            # `e2e:bt_eval` uses neither env).
            @warn "test/$env instantiate failed — its e2e items may be slow on first mount" exception = e
        end
    end
    cur === nothing || Pkg.activate(cur; io = devnull)
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
