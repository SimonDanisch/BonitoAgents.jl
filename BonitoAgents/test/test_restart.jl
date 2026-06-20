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
#       - the JS "💭 reasoning…" indicator is cleared — thinking=false ALWAYS
#         emits in pair with the active=true, even when the update iteration
#         throws.
#       - non-terminal ToolMsg pills are forced to "failed" with a final
#         tool_update so the pulsing glow + taskbar slot go away.
#       - busy_active flips to false; session_alive flips to true after
#         bring-up; last_error clears.
#       - A `session_reset` comm event ships to JS BEFORE the new client
#         starts emitting (the browser handler drops stale streaming
#         classes, cancels pending chase rAFs, etc.), and a fresh
#         msgs.count follows so the virtual scroll re-anchors.
#
# Each test uses a MockTransport whose responder behaviour is controlled
# by a Ref<Symbol> — the test starts the chat in some hung state, calls
# `restart_chat_session!`, then asserts the invariants above.

using Test
using JSON
using BonitoAgents
using Bonito
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir   = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

# A responder whose behaviour for `session/prompt` is dictated by a shared
# Ref: `:normal` finishes a small agent reply, `:agent_hang` streams chunks
# but never sends the end-turn response, `:thought_hang` raises the
# thinking indicator then hangs, `:tool_hang` pushes a non-terminal
# tool_call then hangs. The Ref is mutable so a single transport can flip
# behaviours across restarts (the on_setup callback fires fresh per
# session, see `start_session(::MockTransport, …)`).
function controllable_transport(behavior::Ref{Symbol} = Ref(:normal); n_chunks::Int = 3)
    pid = Ref{Any}(nothing)
    upd(text) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
        "params"=>Dict("sessionId"=>"s",
            "update"=>Dict("sessionUpdate"=>"agent_message_chunk",
                           "content"=>Dict("type"=>"text","text"=>text)))))
    thought_upd(text) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
        "params"=>Dict("sessionId"=>"s",
            "update"=>Dict("sessionUpdate"=>"agent_thought_chunk",
                           "content"=>Dict("type"=>"text","text"=>text)))))
    tool_call(status) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
        "params"=>Dict("sessionId"=>"s",
            "update"=>Dict("sessionUpdate"=>"tool_call",
                           "toolCallId"=>"tc1",
                           "kind"=>"execute",
                           "title"=>"mock tool",
                           "status"=>status))))
    resp(id, result) = JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result))

    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg    = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, resp(id, Dict()))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, resp(id, Dict("sessionId" => "s")))
                elseif method == "session/prompt" && id !== nothing
                    pid[] = id
                    b = behavior[]
                    if b == :agent_hang
                        # Stream agent chunks then hang — no end-turn
                        # response. Test will call restart while the
                        # bubble is mid-stream.
                        for i in 1:n_chunks
                            put!(incoming, upd("agent$i "))
                        end
                    elseif b == :thought_hang
                        # Raise the "thinking" indicator then hang. Test
                        # will call restart while the JS class is on.
                        put!(incoming, thought_upd(""))
                    elseif b == :tool_hang
                        # Open a non-terminal tool then hang. Test will
                        # call restart while the pill is pending.
                        put!(incoming, tool_call("pending"))
                    else
                        # :normal — small clean agent reply.
                        for i in 1:n_chunks
                            put!(incoming, upd("chunk$i "))
                        end
                        put!(incoming, resp(id, Dict("stopReason" => "end_turn")))
                    end
                end
            end
        catch e
            e isa InvalidStateException || @warn "responder failed" exception=e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup), behavior
end

# Convenience: collect every comm event a model emits into a Vector for
# assertion. The on() callback runs on the same task that wrote comm, so
# the events vector reflects wire order.
function capture_comm(model)
    events = Dict{String,Any}[]
    on(d -> push!(events, copy(d)), model.comm)
    return events
end

@testset "restart_chat_session!" begin

    # ── 1. Idempotent close on AgentMsg / ThoughtMsg ─────────────────────
    # The orphan sweep can race with `process_update!`'s own close-in-
    # finally — if `Base.close` weren't idempotent, the second one would
    # re-append to chat.md and re-emit `agent_final` to JS.
    @testset "Base.close on AgentMsg / ThoughtMsg is idempotent" begin
        chat = BT.ChatModel(newstate(), mktempdir();
                            transport = BT.MockTransport((o, i) -> nothing))
        events = capture_comm(chat)

        am = BT.send!(chat, BT.AgentMsg(chat, "hello"))
        @test am.in_flight == true
        close(am)
        @test am.in_flight == false
        n_after_first = count(e -> get(e, "type", "") == "agent_final", events)
        @test n_after_first == 1

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
    # No turn in flight. Restart should flip the client, ship a
    # session_reset + msgs.count event pair, and leave session_alive=true.
    @testset "clean restart from idle session" begin
        state = newstate()
        transport, _ = controllable_transport(Ref(:normal))
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)

        BT.restart_chat_session!(model)

        @test model.session_alive[] == true
        @test isempty(model.last_error[])
        @test model.busy_active[] == false
        # session_reset is emitted BEFORE the new bring-up; msgs.count
        # is the post-bring-up re-broadcast. Order: reset → count.
        types = [get(e, "type", "") for e in events]
        @test "session_reset" in types
        @test "msgs.count" in types
        @test findfirst(==("session_reset"), types) <
              findfirst(==("msgs.count"), types)
    end

    # ── 3. Restart mid agent stream ──────────────────────────────────────
    # An AgentMsg is being streamed; restart must finalize it (in_flight
    # flips false, agent_final emitted) instead of leaving a half-stream.
    @testset "restart mid agent stream finalizes the bubble" begin
        state = newstate()
        transport, behavior = controllable_transport(Ref(:agent_hang))
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("go"))

        @test timedwait(() -> model.busy_active[], 5.0) === :ok
        # Wait until at least one chunk landed in the streaming AgentMsg.
        @test timedwait(() ->
            any(m -> m isa BT.AgentMsg && !isempty(m.text), model.msgs_store),
            5.0) === :ok
        am = first(m for m in model.msgs_store if m isa BT.AgentMsg)
        @test am.in_flight == true   # mid-stream

        # Flip the responder so the NEXT session's prompt works normally
        # (we don't drive a follow-up prompt here, but a leftover :agent_hang
        # behavior would leave the next session in the same wedge).
        behavior[] = :normal
        BT.restart_chat_session!(model)

        @test am.in_flight == false              # orphan sweep finalized it
        @test model.busy_active[] == false
        @test model.session_alive[] == true
        # agent_final shipped to JS for this id.
        finals = [e for e in events
                  if get(e, "type", "") == "agent_final" && get(e, "id", "") == am.id]
        @test length(finals) >= 1
    end

    # ── 4. Restart mid thought → thinking=false is the LAST thinking event ─
    # `process!(::Thought)` raises `thinking=true` then iterates updates;
    # if that iteration throws (session died), the paired `thinking=false`
    # MUST still ship — otherwise the JS "💭 reasoning…" indicator stays
    # stuck on. We assert by checking that the trailing `thinking` event
    # observed in comm is `active=false`.
    @testset "restart mid thought emits the trailing thinking=false" begin
        state = newstate()
        transport, behavior = controllable_transport(Ref(:thought_hang))
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("think"))

        @test timedwait(() ->
            any(e -> get(e, "type", "") == "thinking" && get(e, "active", false), events),
            5.0) === :ok

        behavior[] = :normal
        BT.restart_chat_session!(model)

        thinking_events = [e for e in events if get(e, "type", "") == "thinking"]
        @test !isempty(thinking_events)
        @test last(thinking_events)["active"] == false
    end

    # ── 5. Restart with a pending ToolMsg → status flipped to failed ────
    # An in-progress tool pill must not survive across a restart — the
    # browser's pulsing glow + taskbar slot key on the live status. The
    # orphan sweep in `restart_chat_session!` calls `close(::ToolMsg)`
    # which flips the status to "failed" and emits the terminal
    # `tool_update`.
    @testset "restart with pending tool: status forced to failed" begin
        state = newstate()
        transport, behavior = controllable_transport(Ref(:tool_hang))
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        events = capture_comm(model)
        BT.send_message!(model, BT.UserMsg("tool"))

        @test timedwait(() ->
            any(m -> m isa BT.ToolMsg, model.msgs_store),
            5.0) === :ok
        tool = first(m for m in model.msgs_store if m isa BT.ToolMsg)
        @test !(tool.status in ("completed", "failed"))

        behavior[] = :normal
        BT.restart_chat_session!(model)

        @test tool.status == "failed"
        @test tool.finished_at !== nothing
        @test model.busy_active[] == false
        @test model.session_alive[] == true
        # JS sees the terminal tool_update.
        tu = [e for e in events if get(e, "type", "") == "tool_update"
                                && get(e, "status", "") == "failed"]
        @test !isempty(tu)
    end

    # ── 6. After a clean restart from idle, a fresh turn completes ──────
    # The post-restart session must accept new prompts. We send "go" and
    # wait for the busy spinner to clear with at least one agent chunk
    # rendered, proving the new ACP session is fully wired.
    @testset "after clean restart, a fresh prompt completes end-to-end" begin
        state = newstate()
        transport, _ = controllable_transport(Ref(:normal))
        model = BT.ChatModel(state, mktempdir(); transport = transport)
        BT.start_chat_client!(model)
        BT.restart_chat_session!(model)
        @test model.session_alive[] == true

        BT.send_message!(model, BT.UserMsg("hello"))
        @test timedwait(() ->
            !model.busy_active[] &&
            any(m -> m isa BT.AgentMsg && occursin("chunk", m.text), model.msgs_store),
            10.0) === :ok
    end

end
