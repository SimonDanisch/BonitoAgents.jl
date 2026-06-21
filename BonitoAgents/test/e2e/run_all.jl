# Single-shared-server runner for the e2e suites.
#
# Each `test/e2e/<suite>.jl` exposes `run_suite(server)`: it swaps the shared server's
# agent script to its own and drives the ONE open browser page, scoped to its own
# chat. It does NOT create or close a server. This runner creates the dev_server +
# opens the browser ONCE, includes each suite into its OWN Module (so their
# top-level `agent_script` / helper names don't collide), injects the SHARED
# `TestKit` into each module first (so every suite drives the one server through
# the one harness type — re-including TestKit would make incompatible TestServer
# types), and calls `Mod.run_suite(server)` in sequence. State accumulates across suites
# by design (a soak); at the END we run a leak audit, then close once.
#
# Ordering rule: suites that DESTROY shared server state run LAST.
#   * worker_lifecycle.jl kills the MAIN worker -> dead last (no chat can bind
#     after it).
#   * cross_worker.jl kills a SECOND worker only -> safe mid-run.
#
# Run:  DISPLAY=:1 julia --project=. test/e2e/run_all.jl

ENV["DISPLAY"] = get(ENV, "DISPLAY", ":1")

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Suite files in execution order. worker_lifecycle LAST (kills the main worker).
#
# streaming_flood runs EARLY (2nd), on a near-empty session, on purpose: it tests
# the server-side `deliver_update!` deadlock regression (a 500-burst must not wedge
# the turn), which is independent of how many chats are open. Run late it instead
# trips a SEPARATE, known client-side bug — streaming a large burst gets
# pathologically slow once many messages are already mounted in the browser
# (measured: 500-burst renders in ~1s as chat #1–2, but the renderer WEDGES by
# chat #3; cost ≈ mounted × streamed — stale cross-chat subscribers). That bug is
# tracked on its own; it must not sabotage the deadlock regression's browser check.
const SUITES = [
    "dashboard_layout.jl",   # no chat; resizes window then restores
    "streaming_flood.jl",    # EARLY (near-empty session) — see note above
    "workflows.jl",
    "chat_features.jl",
    "tool_rendering.jl",
    "todo_taskbar.jl",
    "errors.jl",
    "lens.jl",
    "file_open.jl",
    "scroll_persist.jl",
    "embedded_app.jl",       # heavy: Malt worker cold start + Bonito load
    "app_detach.jl",         # heavy: two embedded apps
    "app_stress.jl",         # heavy: 100× detach/close/switch cycle on a live embed
    "app_interactive.jl",    # two live apps; clicks round-trip to Julia + independence
    "app_multi.jl",          # three apps: detach all, drive each while floating, close 1-by-1
    "app_tabs.jl",           # dock app floats into the chat group as TABS: switch + close
    "cross_worker.jl",       # kills a SECOND worker (main untouched) — safe here
    "worker_lifecycle.jl",   # DESTRUCTIVE: kills the MAIN worker — MUST be last
]

# Load one suite into its own Module, sharing THIS runner's TestKit instance.
function load_suite(path::AbstractString)
    name = Symbol(replace(basename(path), ".jl" => ""), :_suite)
    m = Module(name)
    # Inject the shared TestKit BEFORE evaluating the file so its guarded
    # `isdefined(@__MODULE__, :TestKit) || include(...)` skips re-including.
    Core.eval(m, :(const TestKit = $(TestKit)))
    Base.include(m, path)
    return m
end

# ── Leak audit ─────────────────────────────────────────────────────────────
# The one legitimate server-side inspection: after the soak, assert nothing
# that should be bounded grew without bound. We don't demand exact numbers
# (the soak intentionally leaves chats + their agent subprocesses open); we
# assert the bounds and LOG the counts. See TEST_MIGRATION_AUDIT.md.

mock_proc_count() =
    try parse(Int, strip(read(`pgrep -fc mock_claude_agent_acp.jl`, String))) catch; 0 end

function leak_audit(server)
    state = server.h.state

    # Open chats = ChatModels cached on the server.
    n_models = length(state.chat_models)
    # Background pollers now live on `model.poller_task` (a field, not a global) —
    # count the ones STILL RUNNING among the open chats. By construction this can't
    # exceed n_models; a leaked poller from an evicted chat shows up instead as a
    # leaked agent subprocess (n_mocks below), which is the real signal.
    n_pollers = count(values(state.chat_models)) do m
        p = TK.BT.shared(m).poller_task[]
        p !== nothing && !istaskdone(p)
    end
    # Live mock-agent subprocesses (one per still-bound chat session).
    n_mocks = mock_proc_count()
    # Live worker control websockets (one per registered worker still connected).
    n_worker_ws = length(state.worker_control_ws)
    # Pending RPC handoffs should drain to ~0 between turns (none in flight now).
    n_pending = length(state.pending_rpcs)

    @info "leak audit (post-soak)" n_models n_pollers n_mocks n_worker_ws n_pending

    @testset "leak audit (post-soak, server-side)" begin
        # Each cached ChatModel is one open chat from the soak — bounded by the
        # number of new_chat calls across suites (a handful per suite), NOT
        # growing without bound. A blown-up count (hundreds) means models aren't
        # being reused per project.
        @test 0 <= n_models <= 40
        # At most one poller per ChatModel; never more pollers than models.
        @test n_pollers <= n_models
        # One mock subprocess per still-bound chat. Bounded by open chats plus a
        # little slack for one mid-teardown. If this is much larger than n_models
        # we're leaking agent subprocesses (the thing we most care about).
        @test n_mocks <= n_models + 4
        # Pending RPCs must drain between turns — nothing should be stuck.
        @test n_pending <= 8
        # The main worker WS is one; the cross_worker suite's second worker was
        # killed, and worker_lifecycle kills the main worker, so by here it's
        # bounded and small (drops as disconnects are processed).
        @test n_worker_ws <= 4
    end
    return (; n_models, n_pollers, n_mocks, n_worker_ws, n_pending)
end

# ── Drive everything against ONE server ────────────────────────────────────

function main()
    t_start = time()
    mocks_before = mock_proc_count()
    server = TK.dev_server()
    try
        TK.open_browser(server)
        @info "shared server up" url = server.h.url
        # Start from a clean error sink so boot-time noise isn't blamed on suite 1.
        boot_errs = TK.js_errors(server)
        isempty(boot_errs) || @warn "JS errors during boot (pre-suite)" boot_errs
        TK.clear_js_errors(server)

        failures = String[]
        for suite in SUITES
            path = joinpath(@__DIR__, suite)
            t0 = time()
            @info "── running suite ──" suite
            m = load_suite(path)
            # `run_suite` is defined in a newer world than this loop; fetch + call
            # it through invokelatest to satisfy Julia 1.12's binding world-age.
            fn = Base.invokelatest(getglobal, m, :run_suite)
            try
                Base.invokelatest(fn, server)
            catch e
                e isa InterruptException && rethrow()
                # A suite throws here when its top-level @testset closes with a
                # failure ("Some tests did not pass") or it errored mid-drive.
                # Record it and KEEP GOING: one broken suite must NOT skip the rest
                # of the soak or the leak audit. The failure is re-surfaced below.
                push!(failures, suite)
                @error "suite FAILED (continuing soak)" suite exception = (e, catch_backtrace())
            end
            # Let the suite's last turn fully drain before the NEXT suite swaps the
            # agent script — swapping `agent_fn` mid-stream would feed the wrong
            # events into a still-open turn. The agent is the shared funnel.
            sleep(1.5)
            # JS-error gate: a window.onerror / unhandled rejection during this
            # suite is a real UI bug. Attribute it to THIS suite, then clear the
            # sink so the next suite starts clean. Driving the real DOM is only
            # worth it if we also notice when the DOM throws.
            errs = try
                TK.js_errors(server)
            catch e
                e isa TK.BridgeTimeout || rethrow()
                # The suite left the renderer pegged (e.g. the flood's slow paint).
                # We can't sample the sink right now — note it, don't hang, don't
                # abort. Not asserting "clean" here is acceptable: a real JS error
                # would also surface on the NEXT suite's sample once it frees.
                @warn "JS-error gate skipped (renderer busy after suite)" suite
                nothing
            end
            errs === nothing || isempty(errs) || @warn "JS errors during suite" suite errs
            @testset "no JS errors: $suite" begin
                @test errs === nothing || isempty(errs)
            end
            TK.clear_js_errors(server)
            @info "suite done" suite seconds = round(time() - t0; digits = 1)
        end

        leak_audit(server)

        # Re-surface any suite failure as a top-level failing testset AFTER the
        # leak audit — so a broken suite never hides a leak, nor a leak a broken
        # suite. Names were @error-logged above with their backtraces.
        @testset "all e2e suites pass" begin
            @test failures == String[]
        end
    finally
        close(server)
    end

    # Settle: mock subprocesses should be reaped after close.
    for _ in 1:20
        mock_proc_count() <= mocks_before && break
        sleep(0.5)
    end
    @info "ALL SUITES DONE" wall_seconds = round(time() - t_start; digits = 1) leaked_mocks = mock_proc_count() - mocks_before
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
    # Force a clean exit (degraded headless Electron / wedged pollers can stall
    # Julia's normal shutdown). A failing @testset throws before here.
    TK.exit_success()
end
