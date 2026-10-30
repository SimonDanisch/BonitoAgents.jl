@testitem "unit:prompt_receipts" tags=[:unit] begin
    using BonitoAgents, JSON
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    mutable struct ReceiptTransport <: ACP.Transport
        requests::Channel{Any}
        incoming::Channel{String}
    end
    ReceiptTransport() = ReceiptTransport(Channel{Any}(32), Channel{String}(32))
    ACP.send(t::ReceiptTransport, line::AbstractString) = put!(t.requests, JSON.parse(line))
    ACP.recv(t::ReceiptTransport) = take!(t.incoming)
    ACP.transport_eof(t::ReceiptTransport) = !isopen(t.incoming)
    Base.close(t::ReceiptTransport) = close(t.incoming)
    function request(t)
        timedwait(() -> isready(t.requests), 5) === :ok || error("No ACP request")
        take!(t.requests)
    end
    frame(t, d) = put!(t.incoming, JSON.json(d))
    response(t, id, reason) = frame(t, Dict("jsonrpc"=>"2.0", "id"=>id,
        "result"=>Dict("stopReason"=>reason)))
    receipt(t, id; session="session") = frame(t, Dict("jsonrpc"=>"2.0",
        "method"=>"_bonito/prompt_received", "params"=>Dict("sessionId"=>session, "messageId"=>id)))
    state = BT.ServerState(; state_dir=mktempdir(), working_dir=mktempdir())
    m = BT.ChatModel(state, mktempdir(); project_id="receipts",
        agent=BT.WorkerAgent(state, "offline", "/project"))
    transport = ReceiptTransport()
    handler = BT.ChatPermissionHandler(ACP.FSRequestHandler(m.cwd), m)
    cli = ACP.Client(ACP.Connection(transport, handler), "session", "/project",
        Dict{String,Any}("bonitoPromptQueueing"=>true, "bonitoPromptReceipts"=>true))
    m.agent.client = cli
    others = BT.ChatModel[]
    try
        original = ACP.prompt!(cli, "original")
        request(transport)
        BT.send_message!(m, BT.UserMsg("must free automatically"); mode=:next,
            images=[ACP.ImageAttachment(UInt8[1,2,3], "image/png")])
        BT.deliver_boundary_message!(m)
        wire = request(transport)
        @test wire["method"] == "session/prompt"
        token = wire["params"]["_meta"]["bonitoPromptId"]
        entry = only(m.pending_sends)
        @test entry.status === :submitted
        @test isempty(m.msgs_store)
        @test BT.queue_event(m)["items"][1]["status"] == "submitted"
        @test only(JSON.parsefile(BT.pending_path(m)))["text"] == "must free automatically"
        @test wire["params"]["prompt"][2]["type"] == "image"
        @test BT.next_submission(m) === entry
        @test entry.status === :submitted

        # Stop discards the adapter's queued prompt without consuming it.
        @test BT.drop_queued_sends!(m) == 1
        response(transport, original.id, "cancelled")
        response(transport, entry.span.turn.id, "cancelled")
        @test timedwait(() -> ACP.isover(entry.span.turn), 5) === :ok
        BT.settle_submission!(m, entry, nothing)
        @test entry.status === :paused
        @test isempty(m.msgs_store)
        @test entry.span === nothing
        @test BT.next_submission(m) === nothing
        restored = BT.ChatModel(state, m.cwd; project_id=m.project_id,
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(others, restored)
        @test only(restored.pending_sends).status === :paused
        @test only(restored.pending_sends).message.images[1].data == UInt8[1,2,3]

        # Retry has a fresh attempt id. Delayed/wrong-session/duplicate receipts
        # cannot acknowledge another attempt or add duplicate history bubbles.
        BT.handle_command!(m, nothing, BT.QueueActionCommand(entry.id, "send"))
        entry = BT.next_submission(m)
        span = ACP.prompt!(cli, entry.message.text; receipt_id="second-attempt")
        request(transport)
        BT.submission_submitted!(m, entry, span; text=entry.bubble.text, receipt_id="second-attempt")
        receipt(transport, token)
        receipt(transport, "second-attempt"; session="old-session")
        barrier = @async ACP.send_request(cli.conn, "test/barrier", Dict(), 5.0)
        barrier_wire = request(transport)
        response(transport, barrier_wire["id"], "end_turn")
        wait(barrier)
        @test entry.status === :submitted
        @test isempty(m.msgs_store)
        @test BT.drop_queued_sends!(m) == 1
        receipt(transport, "second-attempt")
        @test timedwait(() -> entry.status === :sent, 5) === :ok
        @test count(x -> x isa BT.UserMsg && x.text == "must free automatically", m.msgs_store) == 1
        @test isempty(JSON.parsefile(BT.pending_path(m)))
        receipt(transport, "second-attempt")
        response(transport, span.id, "cancelled")
        @test timedwait(() -> ACP.isover(span), 5) === :ok
        BT.settle_submission!(m, entry, nothing)
        @test isempty(m.pending_sends) # confirmed input is not replayed after Stop
        @test count(x -> x isa BT.UserMsg, m.msgs_store) == 1

        # A crash between write and receipt must not auto-execute unknown work.
        BT.send_message!(m, BT.UserMsg("uncertain after crash"); mode=:next)
        entry = BT.next_submission(m)
        span = ACP.prompt!(cli, entry.message.text; receipt_id="crash-attempt")
        request(transport)
        BT.submission_submitted!(m, entry, span; text=entry.bubble.text, receipt_id="crash-attempt")
        restored = BT.ChatModel(state, m.cwd; project_id=m.project_id,
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(others, restored)
        @test only(restored.pending_sends).status === :paused
        @test occursin("Receipt was not confirmed", only(restored.pending_sends).detail)
        @test BT.next_submission(restored) === nothing

        # Pending receipt prevents an autonomous continuation on a silent end.
        m.yolo[] = true
        response(transport, span.id, "end_turn")
        @test timedwait(() -> isempty(ACP.open_turns(cli)), 5) === :ok
        @test !BT.yolo_ready(m)
        entry.mode = :idle
        BT.drop_idle_sends!(m)
        @test only(m.pending_sends) === entry # already written, still awaiting receipt
        BT.settle_submission!(m, entry, nothing)
        @test isempty(m.pending_sends) # obsolete continuation is never offered for replay
    finally
        close(cli)
        foreach(close, others)
        close(m)
    end
end
