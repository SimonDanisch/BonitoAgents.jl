# Tests for the ACP-session restart lifecycle. The user-visible contract:
#
#   • Clicking Restart on a live session is a clean swap — close the agent,
#     spin a fresh one, history is preserved on disk + JS state is consistent
#     with msgs_store.
#   • Clicking Restart while the session is HUNG mid-turn (agent streaming,
#     thinking active, a tool pending) finalizes every in-flight UI surface
#     so the next session starts from a clean slate:
#       - half-streamed AgentMsg bubbles get their final HTML (agent_final
#         emitted, in_flight=false, persisted to chat.md).
#       - half-streamed ThoughtMsg gets thought_final (same shape).
#       - the JS "reasoning…" indicator is cleared — thinking=false ALWAYS
#         emits in pair with the active=true, even when the update iteration
#         throws.
#       - non-terminal ToolMsg pills are forced to "failed" with a final
#         tool_update so the pulsing glow + taskbar slot go away.
#       - busy_active flips to false; session_alive flips to true after
#         bring-up; last_error clears.
#       - A `session_reset` comm event ships to JS BEFORE the new client
#         starts emitting, and a fresh msgs.count follows so the virtual
#         scroll re-anchors.
#
# Migration to the first-class-agent model: `MockTransport` is GONE. Each test
# now drives a REAL `MockAgent` (a real-spawned mock subprocess + ACP handshake;
# only the agent BEHAVIOUR is faked, selected by `BT_MOCK_ACP_SCENARIO`). The
# old `controllable_transport`'s `Ref{Symbol}` behaviour-flip becomes mutating
# `agent.env["BT_MOCK_ACP_SCENARIO"]` between bring-ups — `restart_chat_session!`
# re-`start!`s the SAME agent instance, so the next session reads the new
# scenario. The hang scenarios (`hang_after_chunks` / `hang_in_thought` /
# `hang_in_tool`) are the mock's built-in equivalents of the old
# `:agent_hang` / `:thought_hang` / `:tool_hang`. The pure Base.close
# idempotency check needs no agent at all (a default, un-started ChatModel).

using Test
using BonitoAgents
using Bonito: on
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir   = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

# A live local chat backed by a real MockAgent running `scenario`. The mock
# subprocess + ACP handshake are real; `start_chat_client!` brings it up. The
# `scenario` env is mutable on the returned agent so a test can flip it to
# "normal" before `restart_chat_session!` (mirrors the old behaviour Ref). The
# stderr redirect swallows the mock's SIGTERM backtrace dump on kill (the hang
# scenarios block on `sleep`, so teardown kills them).
function hung_mock_chat(scenario::AbstractString)
    st = newstate()
    ag = BT.MockAgent(; cwd = mktempdir())
    ag.env["BT_MOCK_ACP_SCENARIO"] = scenario
    m  = BT.ChatModel(st, ag.cwd; agent = ag)
    redirect_stderr(devnull) do
        BT.start_chat_client!(m)
    end
    return m
end

# Flip the agent's scenario for the NEXT bring-up, then restart. `redirect_stderr`
# silences the killed-mock backtrace from the old (hung) subprocess.
function restart_with_scenario!(model, scenario::AbstractString)
    model.agent.env["BT_MOCK_ACP_SCENARIO"] = scenario
    redirect_stderr(devnull) do
        BT.restart_chat_session!(model)
    end
    return nothing
end

# Collect every comm event a model emits into a Vector for assertion. The on()
# callback runs on the same task that wrote comm, so the events vector reflects
# wire order.
function capture_comm(model)
    events = Dict{String,Any}[]
    on(d -> push!(events, copy(d)), model.comm)
    return events
end

@testset "restart_chat_session!" begin

    # ── 1. Idempotent close on AgentMsg / ThoughtMsg ─────────────────────
    # The orphan sweep can race with `process_update!`'s own close-in-finally —
    # if `Base.close` weren't idempotent, the second one would re-append to
    # chat.md and re-emit `agent_final`/`thought_final` to JS. Pure: a default,
    # un-started ChatModel (no agent subprocess needed — we never prompt).
    @testset "Base.close on AgentMsg / ThoughtMsg is idempotent" begin
        chat   = BT.ChatModel(newstate(), mktempdir())
        events = capture_comm(chat)

        am = BT.send!(chat, BT.AgentMsg(chat, "hello"))
        @test am.in_flight == true
        close(am)
        @test am.in_flight == false
        @test count(e -> get(e, "type", "") == "agent_final", events) == 1

        close(am)   # second close: must be a no-op everywhere
        @test count(e -> get(e, "type", "") == "agent_final", events) == 1

        # ThoughtMsg: same invariant.
        tm = BT.send!(chat, BT.ThoughtMsg(chat, "reasoning"))
        @test tm.in_flight == true
        close(tm)
        @test tm.in_flight == false
        @test count(e -> get(e, "type", "") == "thought_final", events) == 1
        close(tm)
        @test count(e -> get(e, "type", "") == "thought_final", events) == 1
    end

    # ── 2. Clean restart from idle ──────────────────────────────────────
    # No turn in flight. Restart should bring up a fresh client, ship a
    # session_reset + msgs.count event pair, and leave session_alive=true.
    @testset "clean restart from idle session" begin
        model  = hung_mock_chat("normal")
        try
            events = capture_comm(model)
            redirect_stderr(devnull) do
                BT.restart_chat_session!(model)
            end

            @test model.session_alive[] == true
            @test isempty(model.last_error[])
            @test model.busy_active[] == false
            # session_reset is emitted BEFORE the new bring-up; msgs.count is the
            # post-bring-up re-broadcast. Order: reset → count.
            types = [get(e, "type", "") for e in events]
            @test "session_reset" in types
            @test "msgs.count" in types
            @test findfirst(==("session_reset"), types) <
                  findfirst(==("msgs.count"), types)
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
        end
    end

    # ── 3. Restart mid agent stream ──────────────────────────────────────
    # An AgentMsg is being streamed (mock `hang_after_chunks`: chunks then never
    # ends the turn); restart must finalize it (in_flight flips false,
    # agent_final emitted) instead of leaving a half-stream.
    @testset "restart mid agent stream finalizes the bubble" begin
        model  = hung_mock_chat("hang_after_chunks")
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("go"))

            @test timedwait(() -> model.busy_active[], 5.0) === :ok
            @test timedwait(() ->
                any(m -> m isa BT.AgentMsg && !isempty(m.text), model.msgs_store),
                5.0) === :ok
            am = first(m for m in model.msgs_store if m isa BT.AgentMsg)
            @test am.in_flight == true   # mid-stream

            restart_with_scenario!(model, "normal")

            @test am.in_flight == false              # orphan sweep finalized it
            @test model.busy_active[] == false
            @test model.session_alive[] == true
            finals = [e for e in events
                      if get(e, "type", "") == "agent_final" && get(e, "id", "") == am.id]
            @test length(finals) >= 1
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
        end
    end

    # ── 4. Restart mid thought → thinking=false is the LAST thinking event ─
    # `process!(::Thought)` raises `thinking=true` then iterates updates; if that
    # iteration throws (session died on restart), the paired `thinking=false`
    # MUST still ship — otherwise the JS "reasoning…" indicator stays stuck on.
    @testset "restart mid thought emits the trailing thinking=false" begin
        model  = hung_mock_chat("hang_in_thought")
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("think"))

            @test timedwait(() ->
                any(e -> get(e, "type", "") == "thinking" && get(e, "active", false), events),
                5.0) === :ok

            restart_with_scenario!(model, "normal")

            thinking_events = [e for e in events if get(e, "type", "") == "thinking"]
            @test !isempty(thinking_events)
            @test last(thinking_events)["active"] == false
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
        end
    end

    # ── 5. Restart with a pending ToolMsg → status flipped to failed ────
    # An in-progress tool pill must not survive across a restart — the browser's
    # pulsing glow + taskbar slot key on the live status. The orphan sweep in
    # `restart_chat_session!` calls `close(::ToolMsg)` which flips the status to
    # "failed" and emits the terminal `tool_update`.
    @testset "restart with pending tool: status forced to failed" begin
        model  = hung_mock_chat("hang_in_tool")
        try
            events = capture_comm(model)
            BT.send_message!(model, BT.UserMsg("tool"))

            @test timedwait(() ->
                any(m -> m isa BT.ToolMsg, model.msgs_store),
                5.0) === :ok
            tool = first(m for m in model.msgs_store if m isa BT.ToolMsg)
            @test !(tool.status in ("completed", "failed"))

            restart_with_scenario!(model, "normal")

            @test tool.status == "failed"
            @test tool.finished_at !== nothing
            @test model.busy_active[] == false
            @test model.session_alive[] == true
            tu = [e for e in events if get(e, "type", "") == "tool_update"
                                    && get(e, "status", "") == "failed"]
            @test !isempty(tu)
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
        end
    end

    # ── 6. After a clean restart from idle, a fresh turn completes ──────
    # The post-restart session must accept new prompts. Send "hello" and wait
    # for the busy spinner to clear with at least one agent chunk rendered,
    # proving the new ACP session is fully wired.
    @testset "after clean restart, a fresh prompt completes end-to-end" begin
        model = hung_mock_chat("normal")
        try
            redirect_stderr(devnull) do
                BT.restart_chat_session!(model)
            end
            @test model.session_alive[] == true

            BT.send_message!(model, BT.UserMsg("hello"))
            @test timedwait(() ->
                !model.busy_active[] &&
                any(m -> m isa BT.AgentMsg && occursin("chunk", m.text), model.msgs_store),
                10.0) === :ok
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
        end
    end

end
