# Lifecycle invariants for the per-chat background-output poller.
#
# What the user asked for and these tests pin down:
#
#   • One task PER ChatModel — not a global server-wide loop walking
#     `state.chat_models`. The task IS the server's mirror of the JS
#     taskbar: same source-of-truth set on both sides
#     (`is_background && bg_running && !empty(bg_output_path)`), same
#     1 s cadence.
#   • Spawned in `start_chat_client!`, so a chat that never had a live
#     bg item still has a poller — idempotent (re-call on restart finds
#     the existing live task and no-ops), cheap (sleeps and walks an
#     empty store).
#   • Lifetime tied to the chat: when the task throws / errormonitors,
#     the registry entry self-cleans via the `finally` in
#     `start_background_poller!`.
#   • No `BG_POLL_INTERVAL` global constant — the 1 s sleep is inline
#     in `background_poll_loop`. The cadence is a property of the
#     poller task, not server config.
#
# MIGRATION NOTE: the old fixtures built a `ChatModel(...; transport =
# MockTransport((o,i)->nothing))` purely as a no-op state holder — those
# fake transports are deleted. The poller's lifecycle (spawn / idempotent /
# per-chat isolation / nil-poll robustness / no-global-constant) is
# AGENT-FREE: it walks `msgs_store` and never drives a turn. So those stay
# direct unit tests, swapping the no-op `MockTransport` for `MockAgent([])`
# (a real agent type used only as an inert state holder — never started, so
# no subprocess is spawned).
#
# The one genuinely agent-driven invariant — "a real chat ALWAYS gets a
# poller, spawned in start_chat_client!, idempotent on the live model, and
# robust to a nil poll" — is verified end-to-end through the TestKit harness
# (real dev_server + worker + ACP + Electron), asserting against the live
# model's poller in `BG_POLLERS` reached via `s.h.state`.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
using .TestKit: text, end_turn

newstate() = BT.ServerState(; state_dir   = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

# ── Pure unit tests: poller-task lifecycle over a bare ChatModel ─────────────

@testset "background-output poller lifecycle (unit)" begin

    # ── No global cadence constant ──────────────────────────────────────
    # Earlier design had `BG_POLL_INTERVAL = 1.0` at module scope. The
    # refactor inlines `sleep(1.0)` in `background_poll_loop` and removes
    # the constant. A test pins that — re-introducing the global is a
    # smell (cadence becomes server-wide config instead of a poller
    # property) and we want a fast failure if someone adds it back.
    @testset "no module-level BG_POLL_INTERVAL constant" begin
        @test !isdefined(BT, :BG_POLL_INTERVAL)
    end

    # ── Per-chat task: start_background_poller! spawns one ───────────────
    @testset "start_background_poller! spawns a poller task for this chat" begin
        state = newstate()
        model = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
        @test !haskey(BT.BG_POLLERS, model)
        BT.start_background_poller!(state, model)
        @test haskey(BT.BG_POLLERS, model)
        t = BT.BG_POLLERS[model]
        @test t isa Task
        @test !istaskdone(t)
        close(model)
    end

    # ── Idempotent: second call doesn't spawn a duplicate ───────────────
    # Restart-chat-session! calls `start_chat_client!` which calls
    # `start_background_poller!`. If the poller was already live from
    # the previous bring-up, we don't want a second task racing the
    # first over the same msgs_store.
    @testset "second start_background_poller! is a no-op" begin
        state = newstate()
        model = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
        BT.start_background_poller!(state, model)
        t1 = BT.BG_POLLERS[model]
        BT.start_background_poller!(state, model)
        t2 = BT.BG_POLLERS[model]
        @test t1 === t2
        close(model)
    end

    # ── Per-chat isolation: two chats get two tasks ─────────────────────
    @testset "each ChatModel gets its own poller task" begin
        state = newstate()
        ma = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
        mb = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
        BT.start_background_poller!(state, ma)
        BT.start_background_poller!(state, mb)
        @test BT.BG_POLLERS[ma] !== BT.BG_POLLERS[mb]
        @test !istaskdone(BT.BG_POLLERS[ma])
        @test !istaskdone(BT.BG_POLLERS[mb])
        close(ma); close(mb)
    end

    # ── Cadence smoke-test: the loop actually ticks ─────────────────────
    # We can't directly observe "the loop reached its sleep" without
    # injecting test hooks, so instead we install a synthetic
    # `BashToolMsg` whose poll path is short-circuited (worker_id is
    # nothing for the empty project_id, so poll_background_task!
    # returns nothing) and verify the task is still alive after a few
    # ticks. The point is "the task survives and isn't crashing on a
    # null poll result", which exercises the `for m in msgs_store`
    # filter + the `r === nothing` branch.
    @testset "loop is robust to a missing worker (nil poll result)" begin
        state = newstate()
        model = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
        # Synthetic bg bash, no project_id ⇒ poll returns nothing each tick.
        bash = BT.BashToolMsg(
            "bash-test", "execute", "Bash", "completed", "running…",
            time(), nothing,                            # started_at / finished_at
            "echo hi", true,                            # command / is_background
            "/tmp/never-exists.log", 0, true, "",       # bg_*
            nothing)                                    # chat back-ref
        push!(model.msgs_store, bash)
        BT.start_background_poller!(state, model)
        sleep(2.5)  # two ticks of margin
        @test haskey(BT.BG_POLLERS, model)
        @test !istaskdone(BT.BG_POLLERS[model])
        close(model)
    end

end

# ── DOM/state e2e: a real chat always gets a live, idempotent poller ─────────
# The agent-driven invariant: opening a real chat through the full stack runs
# `start_chat_client!`, which spawns the poller. We assert against the LIVE
# model's poller (reached via `s.h.state` → `BG_POLLERS`), prove the re-call
# idempotency on that same live model, then inject a synthetic background
# `BashToolMsg` into the live store (no real worker for that path ⇒ nil poll
# each tick) and confirm the poller rides it out without dying.
@testset "real chat: poller spawned in start_chat_client!, idempotent, nil-poll robust (e2e)" begin
    s = TK.dev_server(; agent = msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        sh = BT.shared(model)

        # Opening the chat already ran start_chat_client! → the poller exists,
        # keyed by the SHARED model, and is alive.
        @test haskey(BT.BG_POLLERS, sh)
        t = BT.BG_POLLERS[sh]
        @test t isa Task
        @test !istaskdone(t)

        # Idempotent on the live model: a restart-style re-call finds the live
        # task and no-ops (same task object, no duplicate racing the store).
        BT.start_background_poller!(s.h.state, model)
        @test BT.BG_POLLERS[sh] === t

        # Inject a synthetic background bash into the LIVE store. Its poll path
        # short-circuits (the file doesn't exist / the tail returns nil), so the
        # loop exercises its `r === nothing` branch every tick. The poller must
        # survive that — not crash and self-evict from BG_POLLERS.
        bash = BT.BashToolMsg(
            "bash-e2e", "execute", "Bash", "completed", "running…",
            time(), nothing, "echo hi", true,
            "/tmp/never-exists-e2e.log", 0, true, "", sh)
        lock(sh.lock) do; push!(sh.msgs_store, bash); end
        sleep(2.5)  # a couple of ticks over the nil-poll branch
        @test haskey(BT.BG_POLLERS, sh)
        @test BT.BG_POLLERS[sh] === t
        @test !istaskdone(t)

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
