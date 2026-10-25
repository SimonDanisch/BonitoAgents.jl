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

        # "When done" waits for the prompts of ours the agent has not answered,
        # not for a turn the agent runs on its own: a background subagent can
        # keep those coming, and a prompt sent meanwhile is simply folded in.
        agent2 = BT.WorkerAgent(state, "offline", "/project"; project_id="queue-turns")
        busy = BT.ChatModel(state, mktempdir(); project_id="queue-turns", agent = agent2)
        push!(models, busy)
        @test isempty(BT.prompts_ahead(busy))           # no session: nothing ahead
        conn2 = ACP.Connection(IdleTransport(), ACP.DiscardHandler(); agent_turns = true)
        agent2.client = ACP.Client(conn2, "sess", "/project")
        ACP.main_thread!(conn2, ACP.AgentMessageChunk(ACP.TextContent("reporting back")))
        @test only(ACP.open_turns(busy)) isa ACP.AgentTurn
        @test isempty(BT.prompts_ahead(busy))
        ours = ACP.prompt_request(conn2, Dict())
        @test BT.prompts_ahead(busy) == [ours]
        close(conn2)
    finally
        foreach(close, models)
        close(state.srv)
    end
end

@testitem "unit:yolo_queue" tags=[:unit] begin
    using BonitoAgents, JSON
    const BT = BonitoAgents
    state = BT.ServerState(; state_dir=mktempdir(), working_dir=mktempdir())
    cwd = mktempdir()
    model() = BT.ChatModel(state, cwd; project_id="idle-queue",
        agent=BT.WorkerAgent(state, "offline", cwd))
    m = model()
    models = [m]
    function finish_work()
        close(BT.send!(m, BT.AgentMsg(m, "Useful work finished")))
        BT.continue_yolo!(m, BT.TurnOutcome("end_turn", false, "", 0))
    end
    try
        m.yolo[] = true
        finish_work()
        @test only(m.pending_sends).mode === :idle
        @test m.yolo_state.streak == 1
        finish_work() # a second completion cannot stack another continuation
        @test length(m.pending_sends) == 1
        @test m.yolo_state.streak == 1

        stale = BT.next_submission(m) # selected, but not handed to ACP yet
        note = BT.UserMsg(m, "Background Julia run finished: r1")
        note.auto = true
        BT.send_message!(m, note)
        @test stale.status === :superseded
        @test only(m.pending_sends).bubble.text == note.text
        finish_work()
        @test length(m.pending_sends) == 1
        @test m.yolo_state.streak == 0
        @test m.yolo[] # waiting on real work does not disarm the mode

        empty!(m.pending_sends)
        finish_work()
        m.yolo[] = false
        @test isempty(m.pending_sends)
        m.yolo[] = true
        finish_work()
        BT.user_ended!(m)
        BT.drop_queued_sends!(m)
        @test isempty(m.pending_sends) # a stopped nudge cannot become a rider
        finish_work()
        @test isempty(m.pending_sends)

        m.stopped[] = false
        BT.reset!(m.yolo_state)
        finish_work()
        @test only(m.pending_sends).mode === :idle
        restored = model()
        push!(models, restored)
        @test isempty(restored.pending_sends) # obsolete continuation after restart

        # Old versions persisted YOLO as ordinary auto messages. Upgrade drops
        # only the generated nudges, preserving completed-job notifications.
        rows = [Dict("id"=>"legacy-yolo", "text"=>BT.YOLO_CONTINUE_PROMPT,
                     "auto"=>true, "mode"=>"done"),
                Dict("id"=>"legacy-note", "text"=>note.text, "auto"=>true, "mode"=>"done")]
        BT.atomic_write_json(BT.pending_path(m), rows)
        legacy = model()
        push!(models, legacy)
        @test only(legacy.pending_sends).bubble.text == note.text
        @test only(JSON.parsefile(BT.pending_path(m)))["id"] == "legacy-note"

        empty!(m.pending_sends)
        m.yolo[] = true
        BT.reset!(m.yolo_state)
        m.yolo_state.streak = 1
        close(BT.send!(m, BT.AgentMsg(m, BT.YOLO_DONE_SENTINEL)))
        BT.continue_yolo!(m, BT.TurnOutcome("end_turn", false, "", length(m.msgs_store)-1))
        @test m.yolo_state.phase === :confirm
        @test startswith(only(m.pending_sends).message.text, BT.YOLO_CONFIRM_PROMPT)
        BT.send_message!(m, note)
        @test m.yolo_state.phase === :work # it never answered that confirmation
        @test only(m.pending_sends).bubble.text == note.text
        BT.continue_yolo!(m, BT.TurnOutcome("end_turn", true, "Usage limit", 0))
        @test !m.yolo[] # queued work cannot bypass failure protection
        @test only(m.pending_sends).bubble.text == note.text
    finally
        foreach(close, models)
    end
end
