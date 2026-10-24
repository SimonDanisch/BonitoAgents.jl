@testitem "unit:active_steering" tags = [:unit] begin
    using BonitoAgents, JSON
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    mutable struct SteeringTransport <: ACP.Transport
        requests::Channel{Any}
        incoming::Channel{String}
    end
    SteeringTransport() = SteeringTransport(Channel{Any}(16), Channel{String}(16))
    ACP.send(t::SteeringTransport, line::AbstractString) = put!(t.requests, JSON.parse(line))
    ACP.recv(t::SteeringTransport) = take!(t.incoming)
    ACP.transport_eof(t::SteeringTransport) = !isopen(t.incoming)
    Base.close(t::SteeringTransport) = close(t.incoming)
    function request(t)
        timedwait(() -> isready(t.requests), 5) === :ok || error("No ACP request arrived")
        take!(t.requests)
    end
    respond(t, id, result) = put!(t.incoming, JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => result)))
    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    m = BT.ChatModel(st, mktempdir(); agent = BT.WorkerAgent(st, "offline", "/project"))
    transport = SteeringTransport()
    cli = ACP.Client(ACP.Connection(transport, ACP.DiscardHandler()), "session", "/project",
        Dict{String,Any}("bonitoActiveSteering" => true))
    m.agent.client = cli
    try
        original = ACP.prompt!(cli, "original")
        @test request(transport)["method"] == "session/prompt"
        BT.send_message!(m, BT.UserMsg("injected correction"); mode = :next)
        delivery = @async BT.deliver_boundary_message!(m)
        steer = request(transport)
        @test steer["method"] == "_session/steering"
        @test steer["params"]["activeOnly"] === true
        respond(transport, steer["id"], Dict("outcome" => "injected"))
        wait(delivery)
        @test isempty(m.pending_sends)
        @test count(x -> x isa BT.UserMsg && x.text == "injected correction", m.msgs_store) == 1
        @test only(ACP.open_turns(cli)) === original
        @test !ACP.isover(original)

        # The original finishes while steering is in flight. The adapter
        # declines, so this message remains queued for one ordinary prompt.
        BT.send_message!(m, BT.UserMsg("race correction"); mode = :next)
        delivery = @async BT.deliver_boundary_message!(m)
        steer = request(transport)
        respond(transport, original.id, Dict("stopReason" => "end_turn"))
        respond(transport, steer["id"], Dict("outcome" => "notInjected"))
        wait(delivery)
        @test ACP.wait_turn!(original)["stopReason"] == "end_turn"
        entry = only(m.pending_sends)
        @test entry.mode === :done && entry.status === :waiting
        @test !any(x -> x isa BT.UserMsg && x.text == "race correction", m.msgs_store)
        BT.handle_command!(m, nothing, BT.QueueActionCommand(entry.id, "remove"))

        # Stop can run while the steering RPC is awaiting its response, and a
        # late rejection must not rearm the message that Stop paused.
        original = ACP.prompt!(cli, "cancelable original")
        request(transport)
        BT.send_message!(m, BT.UserMsg("paused correction"); mode = :next)
        delivery = @async BT.deliver_boundary_message!(m)
        steer = request(transport)
        @test BT.drop_queued_sends!(m) == 1
        respond(transport, steer["id"], Dict("outcome" => "notInjected"))
        wait(delivery)
        @test only(m.pending_sends).status === :paused
        @test !any(x -> x isa BT.UserMsg && x.text == "paused correction", m.msgs_store)
        respond(transport, original.id, Dict("stopReason" => "cancelled"))
        @test ACP.wait_turn!(original)["stopReason"] == "cancelled"
        @test isempty(ACP.open_turns(cli))
    finally
        close(cli)
        close(m)
    end
end
