# Same restart-lifecycle contract as `test_restart.jl`, but driven against
# the real `LocalTransport` (subprocess + stdin/stdout + reader-loop EOF
# cascade) instead of the in-memory `MockTransport`. The agent process is
# our Julia-based stand-in (test/mocks/mock_claude_agent_acp.{jl,sh}) so
# the test is hermetic — no real claude-agent-acp binary needed.
#
# Why a second layer of restart tests at all: `MockTransport` shorts the
# entire OS-level teardown plumbing the restart pipeline depends on —
# `kill`, real EOF on stdin/stdout, reader-loop's `EOFError`/`IOError`,
# blocking IO that needs to actually flush. Bugs in that layer are
# invisible to `MockTransport` tests; here they surface as wedged
# subprocesses, missing `agent_final` events, stuck busy flags.

using Test
using JSON
using Random
using BonitoAgents
using Bonito
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

const MOCK_SCRIPT_DIR = joinpath(@__DIR__, "mocks")
const MOCK_BIN        = joinpath(MOCK_SCRIPT_DIR, "mock_claude_agent_acp")

# The test project's root (where BonitoAgents/Project.toml lives). The mock
# activates this so its `using JSON` resolves against the same env we run
# under.
const MOCK_PROJECT = normpath(joinpath(@__DIR__, ".."))

newstate() = BT.ServerState(; state_dir   = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

# `scenario` is the BT_MOCK_ACP_SCENARIO env var the mock reads.
# `chunk_ms` paces the streaming side so a test can land its restart
# inside a known mid-stream window (default 0 = back-to-back).
function mock_local_transport(scenario::AbstractString;
                              cwd::AbstractString   = mktempdir(),
                              chunk_ms::Int         = 0,
                              n_chunks::Int         = 3)
    BT.LocalTransport(cwd;
        agent_bin = MOCK_BIN,
        agent_env = Dict(
            "BT_MOCK_ACP_SCENARIO" => scenario,
            "BT_MOCK_ACP_CHUNK_MS" => string(chunk_ms),
            "BT_MOCK_ACP_CHUNKS"   => string(n_chunks),
            "BT_MOCK_PROJECT"      => MOCK_PROJECT,
        ))
end

function capture_comm(model)
    events = Dict{String,Any}[]
    on(d -> push!(events, copy(d)), model.comm)
    return events
end

@testset "restart_chat_session! against the real LocalTransport (mock binary)" begin

    # Verify the mock binary actually exists + is executable. If this
    # fires you forgot `chmod +x mocks/mock_claude_agent_acp` after a
    # fresh checkout.
    @testset "mock binary is set up" begin
        @test isfile(MOCK_BIN)
        # `uperm` returns the user permissions; the execute bit is 0x01.
        @test (uperm(MOCK_BIN) & 0x01) == 0x01
    end

    # ── 1. Clean restart from idle (real subprocess) ────────────────────
    # Spawn an agent, restart with no turn in flight. Verifies bring-up
    # and bring-down both work over real pipes, and the session_reset +
    # msgs.count pair ships.
    @testset "clean restart from idle session" begin
        state = newstate()
        transport = mock_local_transport("normal")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)

        BT.restart_chat_session!(model)

        @test model.session_alive[] == true
        @test isempty(model.last_error[])
        @test model.busy_active[] == false
        types = [get(e, "type", "") for e in events]
        @test "session_reset" in types
        @test "msgs.count" in types
        @test findfirst(==("session_reset"), types) <
              findfirst(==("msgs.count"), types)
    end

    # ── 2. Restart mid agent stream (subprocess gets killed) ────────────
    # The real subprocess is hung in `hang_after_chunks` (it streamed N
    # chunks then sits in `sleep(1.0)` forever). Restart must `kill` it,
    # close its stdin, watch reader-loop EOF, and finalize the half-
    # streamed bubble — all the things MockTransport can't reproduce.
    @testset "restart mid agent stream finalizes the bubble" begin
        state = newstate()
        transport = mock_local_transport("hang_after_chunks"; chunk_ms = 10)
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("go"))

        @test timedwait(() -> model.busy_active[], 5.0) === :ok
        @test timedwait(() ->
            any(m -> m isa BT.AgentMsg && !isempty(m.text), model.msgs_store),
            5.0) === :ok
        am = first(m for m in model.msgs_store if m isa BT.AgentMsg)
        @test am.in_flight == true

        BT.restart_chat_session!(model)

        @test am.in_flight == false
        @test model.busy_active[] == false
        @test model.session_alive[] == true
        finals = [e for e in events
                  if get(e, "type", "") == "agent_final" && get(e, "id", "") == am.id]
        @test length(finals) >= 1
    end

    # ── 3. Restart mid thought → thinking=false is the last thinking event ─
    @testset "restart mid thought emits the trailing thinking=false" begin
        state = newstate()
        transport = mock_local_transport("hang_in_thought")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("think"))

        @test timedwait(() ->
            any(e -> get(e, "type", "") == "thinking" && get(e, "active", false), events),
            5.0) === :ok

        BT.restart_chat_session!(model)

        thinking_events = [e for e in events if get(e, "type", "") == "thinking"]
        @test !isempty(thinking_events)
        @test last(thinking_events)["active"] == false
    end

    # ── 4. Restart with pending tool → status flipped to failed ─────────
    @testset "restart with pending tool: status forced to failed" begin
        state = newstate()
        transport = mock_local_transport("hang_in_tool")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("tool"))

        @test timedwait(() ->
            any(m -> m isa BT.ToolMsg, model.msgs_store),
            5.0) === :ok
        tool = first(m for m in model.msgs_store if m isa BT.ToolMsg)
        @test !(tool.status in ("completed", "failed"))

        BT.restart_chat_session!(model)

        @test tool.status == "failed"
        @test tool.finished_at !== nothing
        @test model.busy_active[] == false
        @test model.session_alive[] == true
        tu = [e for e in events if get(e, "type", "") == "tool_update"
                                && get(e, "status", "") == "failed"]
        @test !isempty(tu)
    end

    # ── 5. Crashed agent → recover via restart ──────────────────────────
    # `crash` exits(1) right after `session/prompt` (no response, no
    # chunks). `MockTransport` can't simulate this — Channel.close yields
    # InvalidStateException, not the EOFError the reader-loop classifies
    # as session-dead. Real subprocess exit produces real EOFError; the
    # turn's catch flips session_alive=false; restart spawns a fresh one.
    @testset "crashed agent: session_alive=false, then restart recovers" begin
        state = newstate()
        transport = mock_local_transport("crash")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        BT.send_message!(model, BT.UserMsg("die"))

        @test timedwait(() -> model.session_alive[] == false, 5.0) === :ok
        @test !isempty(model.last_error[])

        BT.restart_chat_session!(model)
        @test model.session_alive[] == true
        @test isempty(model.last_error[])
    end

    # ── 6. Stress: many restarts in succession ──────────────────────────
    # Tight loop of restart_chat_session! calls. Each iteration kills the
    # current subprocess and spawns a new one. Asserts that:
    #   • The chat doesn't accumulate orphaned `in_flight` bubbles.
    #   • busy_active settles back to false after each.
    #   • session_alive stays true at the end.
    # If any restart left the chat in a stuck state, a subsequent
    # restart would amplify the problem and surface as timeout.
    @testset "stress: 10 consecutive restarts from idle stay clean" begin
        state = newstate()
        transport = mock_local_transport("normal")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)

        for i in 1:10
            BT.restart_chat_session!(model)
            @test model.session_alive[] == true
            @test model.busy_active[] == false
            # No leaked in_flight bubbles across iterations.
            @test !any(m -> m isa BT.AgentMsg   && m.in_flight, model.msgs_store)
            @test !any(m -> m isa BT.ThoughtMsg && m.in_flight, model.msgs_store)
            @test all(m -> !(m isa BT.ToolMsg) || m.status in ("completed","failed"),
                      model.msgs_store)
        end
    end

    # ── 6b. Rapid re-bring-up must not clobber the freshly-spawned proc ──────
    # `model.transport` (a LocalTransport) is REUSED across restarts; each
    # `start_session` swaps `t.inner[]` to a fresh subprocess. The ACP Connection
    # must bind to THAT subprocess, not the shared `t` — otherwise a stale prior
    # reader_loop's `finally → close(conn.transport)` closes `t.inner[]`, i.e.
    # kills the NEW proc mid-bring-up. Symptom: an "ACP connection closed" thrown
    # from the `initialize` RPC (and, before `transport_eof(::LocalTransport)`, a
    # 100% CPU reader spin / hang). We drive close+re-bring-up back-to-back with
    # NO settle gap — the maximal-pressure version of the race the stress loop
    # above hits only intermittently — and assert every bring-up succeeds.
    @testset "rapid re-bring-up does not clobber the new subprocess" begin
        state = newstate()
        model = BT.ChatModel(state, mktempdir(); transport = mock_local_transport("normal"))
        BT.start_chat_client!(model)
        for i in 1:12
            old = model.client[]
            old === nothing || close(old)
            # No yield between teardown and re-bring-up: slams the race window.
            err = nothing
            try
                BT.start_chat_client!(model)
            catch e
                err = e
            end
            @test err === nothing                         # no "ACP connection closed"
            @test model.client[] !== nothing
            @test model.client[].conn.closed == false     # live, usable session
        end
    end

    # ── 7. Stress: restarts interleaved with prompts + cancels ──────────
    # The randomized timing test. For each iteration we either send a
    # prompt, fire a restart, or send a cancel. After the loop, sweep
    # the model and assert NO orphans, NO stuck busy, NO unmatched
    # thinking-on. This is the closest thing in the suite to "production
    # load" — the one that catches races in `restart_chat_session!`'s
    # bounded wait, the orphan-sweep ordering, the thinking-pair emit.
    @testset "stress: prompt/restart/cancel mixed over 30 iterations" begin
        state = newstate()
        transport = mock_local_transport("hang_after_chunks"; chunk_ms = 2)
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)

        # Deterministic RNG so a failure is reproducible; bump the seed
        # locally to fuzz when investigating.
        rng = Random.Xoshiro(0x5acefade)

        for i in 1:30
            action = rand(rng, (:send, :restart, :cancel))
            if action == :send
                BT.send_message!(model, BT.UserMsg("iter$i"))
            elseif action == :restart
                BT.restart_chat_session!(model)
            else
                # Cancel a possibly-running turn. No-op if nothing's in flight.
                BT.handle_command!(model, nothing, BT.CancelCommand())
            end
            # Small jitter so the consumer task has SOME interleaving
            # without making the test glacial.
            sleep(rand(rng, 1:5) / 1000)
        end

        # Drain any in-flight turn by forcing a final restart.
        BT.restart_chat_session!(model)
        @test timedwait(() -> !model.busy_active[], 5.0) === :ok

        # ── Post-stress invariants ───────────────────────────────────
        @test model.session_alive[] == true
        @test model.busy_active[] == false
        @test !any(m -> m isa BT.AgentMsg   && m.in_flight, model.msgs_store)
        @test !any(m -> m isa BT.ThoughtMsg && m.in_flight, model.msgs_store)
        @test all(m -> !(m isa BT.ToolMsg) || m.status in ("completed","failed"),
                  model.msgs_store)
        # Every thinking=true was followed (eventually) by a thinking=false.
        # We assert the LAST thinking event observed in comm is `false`,
        # which is the user-visible property — the indicator isn't stuck.
        thinking_events = [e for e in events if get(e, "type", "") == "thinking"]
        if !isempty(thinking_events)
            @test last(thinking_events)["active"] == false
        end
    end

    # ── 8. Restart with a LIVE TodoListMsg ──────────────────────────────
    # The agent emitted a `TodoWrite` with pending/in_progress entries and
    # then hung. The plan stays in `msgs_store` as `is_live(t) == true`
    # because at least one entry hasn't completed yet. The agent that was
    # supposed to keep driving it just died — the orphan sweep MUST stamp
    # `finished_at` so the JS taskbar removes the plan slot, the bubble
    # stops pulsing, and a fresh agent's first `TodoWrite` starts a NEW
    # plan instead of absorbing into the abandoned one.
    @testset "restart with a live TodoListMsg: closed via orphan sweep" begin
        state = newstate()
        transport = mock_local_transport("todo_hang")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("plan"))

        @test timedwait(() ->
            any(m -> m isa BT.TodoListMsg, model.msgs_store),
            5.0) === :ok
        todo = first(m for m in model.msgs_store if m isa BT.TodoListMsg)
        @test BT.is_live(todo) == true
        @test todo.finished_at === nothing

        BT.restart_chat_session!(model)

        # Sweep finalized the plan. `finished_at` set, `is_live` false.
        @test todo.finished_at !== nothing
        @test BT.is_live(todo) == false
        # JS sees a trailing `plan_update` (its `live` field went false),
        # so the taskbar slot drops and a new agent's first TodoWrite
        # spawns a fresh bubble (`try_absorb_todo!` keys on `is_live`).
        plan_finals = [e for e in events
                       if get(e, "type", "") == "plan_update" &&
                          get(e, "id", "") == todo.id]
        @test !isempty(plan_finals)
        @test model.session_alive[] == true
    end

    # ── 9. Restart with a LIVE background BashToolMsg ───────────────────
    # The agent backgrounded a shell (`run_in_background:true`). On the
    # chat side this materialises as a `BashToolMsg` whose tool_call
    # status is "completed" (the LAUNCH completed instantly) but
    # `is_background=true` + `bg_running=true` + `bg_output_path != ""`.
    # The shell itself runs in the WORKER, not in the ACP session — so
    # restarting the ACP must NOT touch this entry: the poller keeps
    # tailing the file, the taskbar slot stays live, and the user can
    # keep watching its output across as many restarts as they like.
    @testset "restart preserves a live background BashToolMsg" begin
        state = newstate()
        transport = mock_local_transport("bg_bash_hang")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        BT.send_message!(model, BT.UserMsg("background"))

        @test timedwait(() ->
            any(m -> m isa BT.BashToolMsg && m.is_background && m.bg_running,
                model.msgs_store),
            5.0) === :ok
        bash = first(m for m in model.msgs_store
                     if m isa BT.BashToolMsg && m.is_background)
        @test bash.bg_running == true
        @test bash.status == "completed"   # the LAUNCH completed; the shell is live
        @test !isempty(bash.bg_output_path)
        @test bash.finished_at === nothing

        BT.restart_chat_session!(model)

        # Sweep left the background tool ALONE — its lifecycle is the
        # worker's file, not the ACP session.
        @test bash.bg_running == true
        @test bash.finished_at === nothing
        @test bash.status == "completed"
        @test BT.is_live(bash) == true  # still live for the taskbar
        @test model.session_alive[] == true
    end

    # ── 10. Restart-during-restart: concurrent calls ────────────────────
    # Two `restart_chat_session!` calls racing. The current implementation
    # has no mutex around restart; if this test wedges or leaves the
    # chat in a half-state, we need to add one. Bounded-wait timeout
    # below caps the failure mode at 10 s instead of hanging the suite.
    @testset "two concurrent restarts converge to one live session" begin
        state = newstate()
        transport = mock_local_transport("normal")
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)

        t1 = @async BT.restart_chat_session!(model)
        t2 = @async BT.restart_chat_session!(model)
        # Wait for both to return; timedwait caps at 10 s.
        @test timedwait(() -> istaskdone(t1) && istaskdone(t2), 10.0) === :ok

        @test model.session_alive[] == true
        @test model.busy_active[] == false
        # The client[] must point to a usable client (non-nothing).
        @test model.client[] !== nothing
    end

end
