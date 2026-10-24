@testitem "unit:cancel_command" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    state = BT.serve(; host = "127.0.0.1", port = 0,
        state_dir = mktempdir(), working_dir = mktempdir())
    model = BT.ChatModel(state, mktempdir(); project_id = "cancel-scope",
        agent = BT.WorkerAgent(state, "offline", "/project"))
    try
        model.turn_seq[] = 12
        BT.send_message!(model, BT.UserMsg("a correction for the new turn"))
        entry = only(model.pending_sends)
        # A Force stop from an older pane cannot stop the new turn, pause its
        # queue, or suppress its future background notes and crash recovery.
        stale = BT.parse_chat_command(Dict("type" => "cancel", "seq" => 11, "force" => true))
        BT.handle_command!(model, nothing, stale)
        @test !model.stopped[]
        @test entry.status === :waiting
        @test !BT.cancel_state(model)["stopping"]
        @test BT.cancel_state(model)["seq"] == 12

        current = BT.parse_chat_command(Dict("type" => "cancel", "seq" => 12))
        @test !current.force
        BT.handle_command!(model, nothing, current)
        @test model.stopped[]
        @test entry.status === :paused
        @test !BT.cancel_state(model)["stopping"]  # no agent bound to wait for
    finally
        close(model)
        close(state.srv)
    end
end
