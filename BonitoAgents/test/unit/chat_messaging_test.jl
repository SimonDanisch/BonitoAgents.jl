@testitem "unit:chat_messaging" tags = [:unit] begin
    using BonitoAgents, BonitoMCP, Dates, JSON
    const B = BonitoAgents
    state = B.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    function project(id, owner)
        p = B.ProjectInfo(id, id, "worker", mktempdir(), mktempdir(), now(UTC))
        p.owner = owner
        state.projects[][id] = p
        return p
    end
    source = project("source", "alice")
    target = project("target", "alice")
    foreign = project("foreign", "bob")
    model = B.ChatModel(state, target.server_path; project_id = target.id,
        agent = B.WorkerAgent(state, "worker", target.worker_path; project_id = target.id))
    state.chat_models[target.id] = model
    models = [model]
    request(action; kw...) = B.dev_request(state, "chat_messaging",
        Dict{String,Any}("action" => action, (String(k) => v for (k,v) in kw)...), source.id)
    sendargs = Dict("op" => "send_message", "project_id" => target.id, "text" => "legacy peer")
    try
        @test !source.chat_messaging && !target.chat_messaging
        session = B.Session()
        try
            other_user = copy(state, session, B.User("bob", "", "Bob", String[]))
            @test_throws r"not available" B.set_chat_messaging!(other_user, source.id, true)
        finally
            close(session)
        end
        @test !request("list")["enabled"]
        @test isempty(request("list")["chats"])
        @test_throws r"Chat messaging is off" request("send"; project_id = target.id, text = "blocked")
        B.set_dev_mode!(state, source.id, true)
        @test_throws r"Chat messaging is off" B.dev_request(state, "control", sendargs, source.id)
        @test !source.chat_messaging
        B.set_chat_messaging!(state, source.id, true)
        @test_throws r"receiving chat" request("send"; project_id = target.id, text = "blocked")
        B.set_chat_messaging!(state, target.id, true)
        B.set_chat_messaging!(state, foreign.id, true)
        @test [p["project_id"] for p in request("list")["chats"]] == [target.id]
        @test_throws r"not available" request("send"; project_id = foreign.id, text = "blocked")
        @test_throws r"not available" request("send"; project_id = "missing", text = "blocked")
        B.set_dev_mode!(state, source.id, false)
        @test source.chat_messaging
        @test_throws r"Dev mode is off" B.dev_request(state, "control", sendargs, source.id)
        result = request("send"; project_id = target.id, text = "allowed", sender_id = foreign.id)
        @test result["status"] == "queued"
        @test occursin("does not confirm", result["detail"])
        @test only(model.pending_sends).origin.project_id == source.id
        B.send_message!(model, "ordinary user input")
        B.set_chat_messaging!(state, source.id, false)
        peer, user = model.pending_sends
        @test peer.status == :paused
        @test occursin("Chat messaging", peer.detail)
        @test user.status == :waiting
        B.set_chat_messaging!(state, source.id, true)
        @test peer.status == :paused
        peer.status = :waiting
        B.pause_disallowed_peer_sends!(model; revoked_project = source.id)
        @test peer.status == :paused # a later grant cannot undo in-flight revocation
        B.handle_command!(model, nothing, B.QueueActionCommand(peer.id, "send"))
        B.set_chat_messaging!(state, target.id, false)
        @test peer.status == :paused
        B.set_chat_messaging!(state, target.id, true)
        B.set_dev_mode!(state, source.id, true)
        @test B.dev_request(state, "control", sendargs, source.id)["status"] == "queued"
        @test length(model.pending_sends) == 3

        # A closed chat's outbox also stays paused through revoke/re-enable.
        delete!(state.chat_models, target.id)
        B.set_chat_messaging!(state, source.id, false)
        B.set_chat_messaging!(state, source.id, true)
        restored = B.ChatModel(state, target.server_path; project_id = target.id,
            agent = B.WorkerAgent(state, "worker", target.worker_path; project_id = target.id))
        push!(models, restored)
        @test all(e -> e.status == :paused, filter(e -> e.origin !== nothing, restored.pending_sends))
        @test only(filter(e -> e.origin === nothing, restored.pending_sends)).status == :waiting
        state.chat_models[target.id] = restored
        # Dispatch checks current permission even if a caller manually requeues.
        B.set_chat_messaging!(state, source.id, false)
        e = first(restored.pending_sends)
        e.status = :waiting
        B.next_submission(restored)
        @test e.status == :paused

        fresh = B.ServerState(; state_dir = state.state_dir, working_dir = state.working_dir)
        B.load_projects!(fresh)
        @test !fresh.projects[][source.id].chat_messaging
        @test fresh.projects[][target.id].chat_messaging
        @test fresh.projects[][source.id].dev_mode
        rows = JSON.parsefile(B.projects_file(state))
        foreach(p -> delete!(p, "chat_messaging"), rows)
        B.atomic_write_json(B.projects_file(state), rows)
        legacy = B.ServerState(; state_dir = state.state_dir, working_dir = state.working_dir)
        B.load_projects!(legacy)
        @test all(p -> !p.chat_messaging, values(legacy.projects[]))
        withenv("BONITOAGENTS_DEV_TOOLS" => nothing) do
            @test any(t -> t.name == "bt_chat", BonitoMCP.available_tools())
            @test !any(t -> t.name == "bt_dev_control", BonitoMCP.available_tools())
        end
    finally
        foreach(close, models)
    end
end
