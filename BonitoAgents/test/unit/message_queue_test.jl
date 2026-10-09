@testitem "unit:message_queue" tags=[:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    # A transport that never speaks: the Connection only has to exist, and close.
    mutable struct IdleTransport <: ACP.Transport
        gate::Channel{Nothing}
    end
    IdleTransport() = IdleTransport(Channel{Nothing}(0))
    ACP.send(::IdleTransport, ::AbstractString) = nothing
    ACP.recv(t::IdleTransport) = (isopen(t.gate) && wait(t.gate); "")
    ACP.transport_eof(t::IdleTransport) = !isopen(t.gate)
    Base.close(t::IdleTransport) = (isopen(t.gate) && close(t.gate); nothing)

    # "When done" waits for our own turn and for a cancel winding one down, not
    # for work the agent does on its own: an auto-wake episode or a background
    # subagent has no announced end, and the next prompt is what ends it.
    @test BT.waits_for_turn(ACP.Prompted())
    @test BT.waits_for_turn(ACP.Cancelling())
    @test !BT.waits_for_turn(ACP.Unprompted())
    @test !BT.waits_for_turn(ACP.Idle())

    state = BT.serve(; host="127.0.0.1", port=0, state_dir=mktempdir(), working_dir=mktempdir())
    models = BT.ChatModel[]
    try
        model = BT.ChatModel(state, mktempdir(); project_id="queue-test",
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(models, model)
        BT.send_message!(model, BT.UserMsg("waiting one"))
        BT.send_message!(model, BT.UserMsg("waiting two"); mode=:next,
            images=[ACP.ImageAttachment(UInt8[1, 2, 3], "image/png")])
        @test isempty(model.msgs_store)
        @test length(BT.queue_event(model)["items"]) == 2
        @test all(e -> e.status == :waiting, model.pending_sends)
        @test BT.drop_queued_sends!(model) == 2
        @test BT.next_submission(model) === nothing
        @test all(e -> e.status == :paused, model.pending_sends)
        @test isempty(model.msgs_store)

        # Recover independently from persisted outbox state. In-flight delivery
        # is never replayed automatically after a process restart.
        fresh = BT.ChatModel(state, model.cwd; project_id="queue-test",
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(models, fresh)
        @test length(fresh.pending_sends) == 2
        @test fresh.pending_sends[2].message.images[1].data == UInt8[1, 2, 3]
        @test fresh.pending_sends[2].message.images[1].mime == "image/png"
        @test all(e -> e.status == :paused, fresh.pending_sends)
        @test isempty(fresh.msgs_store)
        first_id = fresh.pending_sends[1].id
        BT.handle_command!(fresh, nothing, BT.QueueActionCommand(first_id, "send"))
        entry = BT.next_submission(fresh)
        @test entry.id == first_id
        @test entry.status == :sending
        # Stop racing a lazy connection must still prevent the handoff.
        @test BT.drop_queued_sends!(fresh) == 1
        @test entry.status == :paused
        BT.handle_command!(fresh, nothing, BT.QueueActionCommand(first_id, "remove"))
        @test length(fresh.pending_sends) == 1
        @test only(fresh.pending_sends).id != first_id
        @test isempty(fresh.msgs_store)

        # A crash mid-turn is recognized while the message being answered is
        # still in the outbox (status :sent until its turn ends); only a message
        # not delivered yet, queued behind it, carries the chat on instead.
        midturn = BT.ChatModel(state, mktempdir(); project_id="queue-midturn",
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(models, midturn)
        BT.send_message!(midturn, BT.UserMsg("long task"))
        only(midturn.pending_sends).status = :sent
        midturn.turn_in_flight[] = true
        @test BT.interrupted_turn(midturn) !== nothing
        BT.send_message!(midturn, BT.UserMsg("queued behind"))
        @test BT.interrupted_turn(midturn) === nothing
        midturn.turn_in_flight[] = false

        # Only what the user paused stays paused across a restart. A message
        # that was merely waiting was never handed over, so it goes out once
        # the chat's consumer runs: the reload leaves it waiting and wakes it.
        queued = BT.ChatModel(state, mktempdir(); project_id="queue-reload",
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(models, queued)
        BT.send_message!(queued, BT.UserMsg("still to send"))
        reloaded = BT.ChatModel(state, queued.cwd; project_id="queue-reload",
            agent=BT.WorkerAgent(state, "offline", "/project"))
        push!(models, reloaded)
        @test only(reloaded.pending_sends).status == :waiting
        @test isready(reloaded.user_messages)
        @test BT.next_submission(reloaded).message.text == "still to send"

        # The send path checks the session itself. A client whose connection
        # closed (the agent exited) is restarted, not reused; when no session
        # can be brought up, the message is held as :offline with the reason,
        # never paused, and the consumer stops instead of retrying in a loop.
        agent = BT.WorkerAgent(state, "offline", "/project"; project_id="queue-dead")
        dead = BT.ChatModel(state, mktempdir(); project_id="queue-dead", agent)
        push!(models, dead)
        conn = ACP.Connection(IdleTransport(), ACP.DiscardHandler())
        agent.client = ACP.Client(conn, "sess", "/project")
        @test isopen(agent)
        close(conn)
        @test !isopen(agent)
        BT.send_message!(dead, BT.UserMsg("after the crash"))
        entry = BT.next_submission(dead)
        @test BT.run_submission!(dead, entry) == false
        @test entry.status == :offline
        @test occursin("not reachable", entry.detail)
        @test occursin("not connected", entry.detail)
        @test BT.client(agent) === nothing          # the dead client was torn down
        @test !BT.shared(dead).session_alive[]
        @test isempty(dead.msgs_store)
        # Held, not dropped: the next look at the outbox takes it again.
        @test BT.next_submission(dead) === entry
        @test entry.status == :sending
        # Stop still pauses it, like any message not yet handed over.
        @test BT.drop_queued_sends!(dead) == 1
        @test entry.status == :paused
    finally
        foreach(close, models)
        close(state.srv)
    end
end
