# Part 1 of cancel-correctness: when the agent HONORS `session/cancel`, the turn
# must end cleanly and FAST — the session stays alive (no force-close escalation),
# and the fast-discard drops any update backlog streamed after the cancel so it
# can't stall the dispatcher (the "cancelled response stuck behind tokens" wedge).
#
# Contrast with test_cancel_escalation.jl, where the agent IGNORES cancel and the
# only recovery is the force-close backstop.

using Test
using JSON
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# Streams "before" chunks on the prompt, then on `session/cancel` streams "AFTER"
# chunks (which the fast-discard must drop) and resolves the prompt as cancelled.
function honors_cancel_transport()
    pid = Ref{Any}(nothing)
    upd(text) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
        "params"=>Dict("sessionId"=>"s",
            "update"=>Dict("sessionUpdate"=>"agent_message_chunk",
                           "content"=>Dict("type"=>"text","text"=>text)))))
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
                    for i in 1:5
                        put!(incoming, upd("before$i "))
                    end
                    # No response yet — the turn stays in flight until cancel.
                elseif method == "session/cancel"
                    for i in 1:5
                        put!(incoming, upd("AFTER$i "))   # must be discarded
                    end
                    pid[] !== nothing &&
                        put!(incoming, resp(pid[], Dict("stopReason" => "cancelled")))
                end
            end
        catch e
            e isa InvalidStateException || @warn "responder failed" exception=e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

@testset "clean cancel: fast end, session alive, backlog discarded" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                             working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = honors_cancel_transport())
    BT.start_chat_client!(model)
    BT.send_message!(model, BT.UserMsg("go"))

    @test timedwait(() -> model.busy_active[], 5.0) === :ok
    # Wait until the "before" chunks have rendered, so the cancel lands AFTER them.
    @test timedwait(() ->
        any(m -> m isa BT.AgentMsg && occursin("before", m.text), model.msgs_store),
        5.0) === :ok

    # Cancel: sets the ACP cancelling flag + sends session/cancel. The mock then
    # streams the AFTER chunks (must be discarded) + the cancelled response.
    BT.handle_command!(model, nothing, BT.CancelCommand())

    # A graceful cancel that the agent HONORS ends cleanly + FAST, and the session
    # STAYS ALIVE (no force-close — that's reserved for an explicit second cancel
    # of a wedged turn; see test_cancel_escalation.jl).
    @test timedwait(() -> !model.busy_active[], 5.0) === :ok
    @test model.session_alive[] == true

    # Fast-discard: AFTER chunks streamed post-cancel were dropped, not rendered.
    am = first(m for m in model.msgs_store if m isa BT.AgentMsg)
    @test occursin("before", am.text)
    @test !occursin("AFTER", am.text)
end
