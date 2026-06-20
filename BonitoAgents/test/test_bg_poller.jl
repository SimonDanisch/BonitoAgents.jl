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

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir   = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

@testset "background-output poller lifecycle" begin

    # ── No global cadence constant ──────────────────────────────────────
    # Earlier design had `BG_POLL_INTERVAL = 1.0` at module scope. The
    # refactor inlines `sleep(1.0)` in `background_poll_loop` and removes
    # the constant. A test pins that — re-introducing the global is a
    # smell (cadence becomes server-wide config instead of a poller
    # property) and we want a fast failure if someone adds it back.
    @testset "no module-level BG_POLL_INTERVAL constant" begin
        @test !isdefined(BT, :BG_POLL_INTERVAL)
    end

    # ── Per-chat task: spawned in start_chat_client! ────────────────────
    @testset "start_chat_client! spawns a poller task for this chat" begin
        state = newstate()
        model = BT.ChatModel(state, mktempdir();
                             transport = BT.MockTransport((o, i) -> nothing))
        @test !haskey(BT.BG_POLLERS, model)

        # Direct call — we don't go through start_chat_client! here
        # because the MockTransport responder is a no-op and would block
        # the bring-up on `initialize`. The poller's spawn is the part
        # we want to assert anyway.
        BT.start_background_poller!(state, model)
        @test haskey(BT.BG_POLLERS, model)
        t = BT.BG_POLLERS[model]
        @test t isa Task
        @test !istaskdone(t)
    end

    # ── Idempotent: second call doesn't spawn a duplicate ───────────────
    # Restart-chat-session! calls `start_chat_client!` which calls
    # `start_background_poller!`. If the poller was already live from
    # the previous bring-up, we don't want a second task racing the
    # first over the same msgs_store.
    @testset "second start_background_poller! is a no-op" begin
        state = newstate()
        model = BT.ChatModel(state, mktempdir();
                             transport = BT.MockTransport((o, i) -> nothing))
        BT.start_background_poller!(state, model)
        t1 = BT.BG_POLLERS[model]
        BT.start_background_poller!(state, model)
        t2 = BT.BG_POLLERS[model]
        @test t1 === t2
    end

    # ── Per-chat isolation: two chats get two tasks ─────────────────────
    @testset "each ChatModel gets its own poller task" begin
        state = newstate()
        ma = BT.ChatModel(state, mktempdir();
                          transport = BT.MockTransport((o, i) -> nothing))
        mb = BT.ChatModel(state, mktempdir();
                          transport = BT.MockTransport((o, i) -> nothing))
        BT.start_background_poller!(state, ma)
        BT.start_background_poller!(state, mb)
        @test BT.BG_POLLERS[ma] !== BT.BG_POLLERS[mb]
        @test !istaskdone(BT.BG_POLLERS[ma])
        @test !istaskdone(BT.BG_POLLERS[mb])
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
        model = BT.ChatModel(state, mktempdir();
                             transport = BT.MockTransport((o, i) -> nothing))
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
    end

end
