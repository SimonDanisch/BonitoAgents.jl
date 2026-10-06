@testitem "unit:message_queue" tags=[:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
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
    finally
        foreach(close, models)
        close(state.srv)
    end
end
