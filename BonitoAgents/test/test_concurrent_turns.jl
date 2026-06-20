# The background-shell hold + handoff (validated against the real agent):
# claude-agent-acp never resolves a prompt while a background shell lives —
# the NEXT prompt (officially supported mid-turn, `promptQueueing`) is what
# releases it. So BonitoAgents must send a new prompt immediately instead of
# serializing behind the held turn, and end-of-turn cleanup must belong to
# the LAST active turn only.
using Test
using BonitoAgents
using JSON
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# A responder that mimics the SDK's prompt-queueing contract:
#   prompt 1 → stream a bg-bash launch + a chunk, then HOLD (no response).
#   prompt 2 (mid-hold) → resolve prompt 1 end_turn (handoff), stream a
#   chunk for turn 2, resolve prompt 2.
# A serializing client deadlocks here by construction — prompt 1 only ever
# resolves after prompt 2 hits the wire.
function handoff_transport()
    BT.MockTransport((outgoing, incoming) -> begin
        Base.errormonitor(@async try
            send(d) = put!(incoming, JSON.json(d))
            resp(id, result) = send(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
            upd(u) = send(Dict("jsonrpc" => "2.0", "method" => "session/update",
                "params" => Dict("sessionId" => "s", "update" => u)))
            chunk(text) = upd(Dict("sessionUpdate" => "agent_message_chunk",
                "content" => Dict("type" => "text", "text" => text)))

            held_prompt = nothing
            for line in outgoing
                msg = JSON.parse(line)
                id = get(msg, "id", nothing)
                m  = get(msg, "method", "")
                if m == "initialize"
                    resp(id, Dict("agentCapabilities" =>
                        Dict("_meta" => Dict("claudeCode" =>
                            Dict("promptQueueing" => true)))))
                elseif m == "session/new"
                    resp(id, Dict("sessionId" => "s"))
                elseif m == "session/prompt" && held_prompt === nothing
                    held_prompt = id
                    upd(Dict("sessionUpdate" => "tool_call",
                        "toolCallId" => "bg1", "title" => "Terminal",
                        "kind" => "execute", "status" => "pending",
                        "content" => Any[],
                        "rawInput" => Dict("command" => "sleep 600",
                                           "run_in_background" => true,
                                           "description" => "Monitor"),
                        "_meta" => Dict("claudeCode" => Dict("toolName" => "Bash"))))
                    upd(Dict("sessionUpdate" => "tool_call_update",
                        "toolCallId" => "bg1", "status" => "completed",
                        "_meta" => Dict("claudeCode" => Dict("toolName" => "Bash"))))
                    chunk("LAUNCHED")
                    # …and HOLD: no response until the next prompt.
                elseif m == "session/prompt"
                    resp(held_prompt, Dict("stopReason" => "end_turn"))   # handoff
                    chunk("HELLO")
                    resp(id, Dict("stopReason" => "end_turn"))
                end
            end
        catch e
            e isa InvalidStateException || @warn "handoff responder" e
        end)
        nothing
    end)
end

@testset "background-shell hold: second send releases the first turn (handoff)" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = handoff_transport())
    BT.start_chat_client!(model)
    @test timedwait(() -> model.client[] !== nothing, 5.0) === :ok

    BT.send_message!(model, BT.UserMsg(model, "start a monitor"))
    # Turn 1 streams its content, then its prompt is HELD by the mock.
    @test timedwait(5.0) do
        any(m -> m isa BT.AgentMsg && occursin("LAUNCHED", m.text), model.msgs_store)
    end === :ok
    @test model.turns_active[] == 1

    # The fix under test: this prompt must hit the wire IMMEDIATELY (a
    # serializing consumer would queue it forever behind the held turn).
    BT.send_message!(model, BT.UserMsg(model, "you still there?"))
    @test timedwait(10.0) do
        any(m -> m isa BT.AgentMsg && occursin("HELLO", m.text), model.msgs_store)
    end === :ok

    # Both turns resolve; cleanup (gated on the LAST turn) has run.
    @test timedwait(() -> model.turns_active[] == 0, 10.0) === :ok
    @test timedwait(() -> !model.busy_active[], 5.0) === :ok
    # No queued badge left anywhere.
    @test !any(m -> m isa BT.UserMsg && m.queued, model.msgs_store)
    close(model)
end

@testset "update_busy!: quiet wire + bg shell only → busy off; live fg tool → busy on" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir();
                          transport = BT.MockTransport((o, i) -> nothing))
    s = BT.shared(model)

    bg = BT.BashToolMsg("bg1", "execute", "Terminal", "completed", "",
                         time(), nothing, "sleep 600", "Monitor", true,
                         "/tmp/x.out", 0, true, "", model)
    push!(s.msgs_store, bg)

    # Open turn + quiet wire + only a bg shell live → not busy.
    s.turns_active[]  = 1
    s.last_stream_at[] = time() - 60
    s.busy_active[]   = true
    BT.update_busy!(model)
    @test !s.busy_active[]

    # Same, but wire active again → busy.
    s.last_stream_at[] = time()
    BT.update_busy!(model)
    @test s.busy_active[]

    # Quiet + bg shell + a LIVE FOREGROUND tool → stays busy (fg tools
    # stream nothing while they run; quiet is not idle).
    s.last_stream_at[] = time() - 60
    fg = BT.GenericToolMsg("fg1", "read", "Read", "Read x", "in_progress",
                            "", time(), nothing, model, Dict{String,Any}())
    # (field order: id, kind, name, title, status, summary, started, finished,
    #  chat, raw_input)
    push!(s.msgs_store, fg)
    BT.update_busy!(model)
    @test s.busy_active[]

    # No open turn → never busy.
    s.turns_active[] = 0
    BT.update_busy!(model)
    @test !s.busy_active[]
end

# The error path through the refactored turn loop (begin_turn! / drain_turn!):
# a prompt that errors (not session-dead) must still push an inline `[error:]`
# AgentMsg bubble. Headless mirror of the electron test_chat_errors case that
# flakes on cold mount — deterministic here.
@testset "prompt error → inline [error: …] AgentMsg (via drain_turn!)" begin
    function erroring_transport()
        BT.MockTransport((outgoing, incoming) -> begin
            Base.errormonitor(@async try
                for line in outgoing
                    msg = JSON.parse(line); id = get(msg, "id", nothing)
                    m = get(msg, "method", "")
                    if m == "initialize"
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>Dict())))
                    elseif m == "session/new"
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                                      "result"=>Dict("sessionId"=>"s"))))
                    elseif m == "session/prompt"
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                            "error"=>Dict("code"=>-32000,
                                          "message"=>"model overloaded, please retry"))))
                    end
                end
            catch e
                e isa InvalidStateException || @warn "erroring responder" e
            end)
            nothing
        end)
    end

    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = erroring_transport())
    BT.start_chat_client!(model)
    @test timedwait(() -> model.client[] !== nothing, 5.0) === :ok

    BT.send_message!(model, BT.UserMsg(model, "hi"))
    @test timedwait(8.0) do
        any(m -> m isa BT.AgentMsg && occursin("[error:", m.text) &&
                 occursin("overloaded", m.text), model.msgs_store)
    end === :ok
    @test model.session_alive[]          # arbitrary error ≠ session death
    @test timedwait(() -> !model.busy_active[], 5.0) === :ok   # turn cleaned up
    close(model)
end

@testset "update_busy!: a live bt_show_app render keeps the spinner on" begin
    # Regression: a long bt_show_app (or eval between checkpoints) is
    # foreground work whose pill is status-live; the spinner must NOT drop
    # while it renders, even though the wire is momentarily quiet. (Earlier
    # the fg-live check wrongly excluded BonitoAppMsg.)
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir();
                          transport = BT.MockTransport((o, i) -> nothing))
    s = BT.shared(model)

    app = BT.BonitoAppMsg("app1", "bonito_app", "Dashboard", "in_progress",
                          "", time(), nothing, "btworker", "", model)
    push!(s.msgs_store, app)
    s.turns_active[]   = 1
    s.last_stream_at[] = time() - 60      # wire quiet
    s.busy_active[]    = true
    BT.update_busy!(model)
    @test s.busy_active[]                 # live app render ⇒ still busy
end
