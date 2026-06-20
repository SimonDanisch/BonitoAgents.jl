# Stress the cancel path under the conditions that actually break it: a heavy
# token/tool-call stream with a SLOW consumer (the single FIFO dispatcher must
# still reach the `cancelled` response behind the backlog), rapid send→cancel
# cycles (no wedge, no spurious force-close, session stays alive), and a cancel
# with no turn in flight (no-op). All headless + deterministic via MockTransport.

using Test
using JSON
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

upd(text) = JSON.json(Dict("jsonrpc"=>"2.0","method"=>"session/update",
    "params"=>Dict("sessionId"=>"s",
        "update"=>Dict("sessionUpdate"=>"agent_message_chunk",
                       "content"=>Dict("type"=>"text","text"=>text)))))
resp(id, result) = JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result))

# Floods `nchunks` update notifications on session/prompt, then blocks until
# session/cancel, which it honors by resolving the open prompt as `cancelled`.
function streamer_transport(; nchunks = 400)
    pid = Ref{Any}(nothing)
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg = JSON.parse(line); method = get(msg,"method",""); id = get(msg,"id",nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, resp(id, Dict()))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, resp(id, Dict("sessionId"=>"s")))
                elseif method == "session/prompt" && id !== nothing
                    pid[] = id
                    for i in 1:nchunks; put!(incoming, upd("chunk$i ")); end
                    # no prompt response yet — the turn stays open until cancel
                elseif method == "session/cancel"
                    pid[] !== nothing && put!(incoming, resp(pid[], Dict("stopReason"=>"cancelled")))
                end
            end
        catch e; e isa InvalidStateException || @warn "streamer failed" exception=e end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

# A responsive agent: every prompt finishes quickly with end_turn; a cancel of an
# open prompt resolves it as cancelled. Used for rapid send→cancel cycling.
function responsive_transport()
    pid = Ref{Any}(nothing)
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg = JSON.parse(line); method = get(msg,"method",""); id = get(msg,"id",nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, resp(id, Dict()))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, resp(id, Dict("sessionId"=>"s")))
                elseif method == "session/prompt" && id !== nothing
                    pid[] = id
                    put!(incoming, upd("ok "))
                    put!(incoming, resp(id, Dict("stopReason"=>"end_turn")))  # finishes fast
                    pid[] = nothing
                elseif method == "session/cancel"
                    pid[] !== nothing && (put!(incoming, resp(pid[], Dict("stopReason"=>"cancelled"))); pid[] = nothing)
                end
            end
        catch e; e isa InvalidStateException || @warn "responsive failed" exception=e end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

@testset "cancel under heavy backlog + slow render reaches the response fast" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = streamer_transport(nchunks = 400))
    # Simulate a SLOW browser: every wire emit blocks ~15ms. Rendering all 400
    # chunks would take ~6s; cancel must NOT wait for that.
    BT.Bonito.on(BT.shared(model).comm) do _; sleep(0.015); end
    BT.start_chat_client!(model)
    BT.send_message!(model, BT.UserMsg("go"))
    @test timedwait(() -> model.busy_active[], 5.0) === :ok
    sleep(0.4)                                   # let the pipeline genuinely back up
    t0 = time()
    BT.handle_command!(model, nothing, BT.CancelCommand())
    cleared = timedwait(() -> !model.busy_active[], 3.0)
    dt = round(time() - t0, digits=2)
    @test cleared === :ok                        # well under the ~6s full-render time
    @test model.session_alive[] == true          # graceful — no force-close
    @info "cancel-under-backlog cleared" seconds = dt
end

@testset "rapid send→cancel cycles never wedge or force-close" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = responsive_transport())
    BT.start_chat_client!(model)
    for i in 1:12
        BT.send_message!(model, BT.UserMsg("msg $i"))
        sleep(0.01)
        BT.handle_command!(model, nothing, BT.CancelCommand())   # immediate cancel each
        @test timedwait(() -> !model.busy_active[], 5.0) === :ok # always clears
        @test model.session_alive[] == true                      # never force-closed
    end
end

@testset "cancel with no turn in flight is a safe no-op" begin
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = responsive_transport())
    BT.start_chat_client!(model)
    @test !model.busy_active[]
    BT.handle_command!(model, nothing, BT.CancelCommand())       # idle cancel
    BT.handle_command!(model, nothing, BT.CancelCommand())       # twice
    @test model.session_alive[] == true
    @test !model.busy_active[]
end
