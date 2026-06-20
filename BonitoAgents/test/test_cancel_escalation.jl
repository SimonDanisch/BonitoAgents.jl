# Headless test: force-close is the LAST resort for a genuinely wedged agent
# (resumed onto an orphaned tool call — ignores `session/cancel`, connection
# stays alive so no `ConnectionClosed` ever fires). It must be:
#   • never automatic on a timer — that races legitimate cold/resumed cancels
#     (honor latency 6–18s+) and a premature mid-turn teardown leaves an orphaned
#     tool_use that wedges every future resume (a doom loop);
#   • never triggered by an impatient double-click — that's the same trap;
#   • triggered ONLY by a deliberate re-cancel after the agent has had a real
#     chance (≥ CANCEL_ESCALATE_WAIT) and the turn is still busy.

using Test
using JSON
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# Completes bring-up but then WEDGES: never replies to `session/prompt`, ignores
# `session/cancel`. The server-visible shape of a hung agent on a live connection.
function wedged_transport()
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>Dict())))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                        "result"=>Dict("sessionId"=>"wedged-sess"))))
                # session/prompt + session/cancel: deliberately ignored.
                end
            end
        catch e
            e isa InvalidStateException || @warn "wedged responder failed" exception=e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

@testset "cancel: graceful, double-click safe, force only on deliberate re-cancel" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                             working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = wedged_transport())
    BT.start_chat_client!(model)
    BT.send_message!(model, BT.UserMsg("hello?"))
    @test timedwait(() -> model.busy_active[], 5.0) === :ok   # turn in flight

    c = model.client[]

    # FIRST cancel — graceful. Mock ignores it; busy STAYS (no auto-teardown).
    BT.handle_command!(model, nothing, BT.CancelCommand())
    @test timedwait(() -> !model.busy_active[], 2.0) === :timed_out
    @test model.session_alive[] == true

    # RAPID second cancel (impatient double-click, well within the wait) — STILL
    # graceful. Must not force-close a turn that might be about to honor.
    BT.handle_command!(model, nothing, BT.CancelCommand())
    @test timedwait(() -> !model.busy_active[], 2.0) === :timed_out
    @test model.session_alive[] == true

    # DELIBERATE re-cancel: simulate the agent having had its full chance by
    # backdating the first-cancel stamp past the escalation wait. NOW a re-cancel
    # force-closes → ConnectionClosed breaks the wedged loop → busy clears.
    @atomic c.conn.cancel_at = time() - (BT.CANCEL_ESCALATE_WAIT + 1.0)
    BT.handle_command!(model, nothing, BT.CancelCommand())
    @test timedwait(() -> !model.busy_active[], 5.0) === :ok
    @test model.session_alive[] == false
    @test !isempty(model.last_error[])
end
