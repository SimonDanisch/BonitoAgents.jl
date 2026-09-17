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
# everything. An extra `i/n` argument runs the i-th of n shards of that
# selection, which is how CI fans the e2e items out (`["^e2e:", "3/8"]`).
# `nworkers` is hardcoded to 1 (not configurable) — more than one dev_server at a
# time (each = electron + worker + mock subprocesses) over-subscribes a normal box
# and fakes timing failures.
#
# Run locally via the system julia (the bundled Pkg mis-resolves the dev
# `[sources]`):
#   env -u JULIA_DEPOT_PATH -u JULIA_LOAD_PATH [DISPLAY=:1] \
#     julia --project=. -e 'using Pkg; Pkg.test("BonitoAgents"; test_args=["unit"])'
using ReTestItems, BonitoAgents

# `e2e:bt_eval_types` runs a Malt eval worker on the committed `test/evalenv`
# project (dev Bonito + DataFrames/Colors/ImageShow/Tables for the render-type
# cases), and `e2e:bt_eval` uses it plus `test/altenv` (Bonito only, same rev —
# a second env so the env_path-isolation testset has two to tell apart). Both
# must be RESOLVED + PRECOMPILED before the worker dials in — otherwise the
# worker re-resolves on first touch and the render/mount times out. The packages
# are precompiled in the depot, so this is a fast cache hit; do it once here,
# before the workers fork.
let cur = Base.active_project()
    import Pkg
    for env in ("evalenv", "altenv")
        path = joinpath(@__DIR__, env)
        isdir(path) || continue
        try
            Pkg.activate(path; io = devnull)
            Pkg.instantiate(; io = devnull)
        catch e
            # Best-effort warmup: a failure here only makes that env's e2e items
            # re-resolve on first touch — it must NOT abort the whole suite, and
            # every item that does NOT eval is unaffected either way.
            @warn "test/$env instantiate failed — its e2e items may be slow on first mount" exception = e
        end
    end
    cur === nothing || Pkg.activate(cur; io = devnull)
end

"""
    testitem_names(dir) -> Vector{String}

Every `@testitem "…"` name declared under `dir`, sorted. ReTestItems has no
sharding of its own and its scan is internal, so the shard split re-reads the
literal names — every item in this suite declares one.
"""
function testitem_names(dir)
    names = String[]
    for (root, _, files) in walkdir(dir), f in files
        endswith(f, ".jl") || continue
        for m in eachmatch(r"@testitem\s+\"([^\"]+)\"", read(joinpath(root, f), String))
            push!(names, m[1])
        end
    end
    return sort!(unique!(names))
end

"""
    shard_name_filter(i, n, name_filter) -> Regex

The `i`-th of `n` equal shards of the items matching `name_filter`, as an anchored
name regex. Items are sorted and dealt round-robin, so neighbouring (usually
similar-cost) suites end up in different shards.
"""
function shard_name_filter(i, n, name_filter)
    1 <= i <= n || error("shard $i/$n is out of range")
    names = testitem_names(@__DIR__)
    name_filter === nothing || filter!(nm -> occursin(name_filter, nm), names)
    mine = names[i:n:end]
    isempty(mine) && error("shard $i/$n selects none of $(length(names)) items")
    @info "shard $i/$n" of = length(names) items = mine
    return Regex("^(" * join(mine, "|") * ")\$")
end

# `i/n` anywhere in ARGS runs that shard of the selected items; the remaining
# args are the name filter, as before (`unit`, `^e2e:`, `e2e:media`, …).
const SHARD_ARG = findfirst(a -> occursin(r"^\d+/\d+$", a), ARGS)
const FILTER = let rest = [a for (i, a) in enumerate(ARGS) if i != SHARD_ARG]
    isempty(rest) ? nothing : Regex(join(rest, "|"))
end
const NAME = if SHARD_ARG === nothing
    FILTER
else
    i, n = parse.(Int, split(ARGS[SHARD_ARG], "/"))
    shard_name_filter(i, n, FILTER)
end

# No `retries` kwarg on purpose: we NEVER retry a failing test. ReTestItems already
# defaults to 0; a retry that greens a red item only hides a real bug or a test we
# don't understand (the flakes it used to paper over were all real — chat-bind
# deadlock, multi-pane selector leaks, SIGTERM-vs-load worker kill — found + fixed
# once we stopped retrying). Don't add it back.
ReTestItems.runtests(BonitoAgents;
    nworkers = 1,
    # Per-ITEM budget (ReTestItems only applies it with nworkers > 0, one more
    # reason the worker count is 1 and not 0). A wedged item fails itself and the
    # worker respawns with a fresh dev_server; before this, CI wrapped the whole
    # job in `timeout 420`, so one slow item killed the run with no test report.
    # The slowest item in CI takes ~2 minutes.
    testitem_timeout = 420,
    name = NAME)
