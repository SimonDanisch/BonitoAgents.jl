@testitem "unit:peer_message_timestamps" tags = [:unit] begin
    using BonitoAgents, Dates, JSON
    const BT = BonitoAgents
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    sender = BT.ProjectInfo("sender", "GPU coordinator", "worker-a", "/source", mktempdir(), now(UTC))
    target = BT.ProjectInfo("receiver", "Receiver", "worker-b", "/target", mktempdir(), now(UTC))
    state.projects[][sender.id] = sender
    state.projects[][target.id] = target
    sender.chat_messaging = target.chat_messaging = true
    model = BT.ChatModel(state, target.server_path; project_id = target.id,
        agent = BT.WorkerAgent(state, target.worker_id, target.worker_path; project_id = target.id))
    state.chat_models[target.id] = model
    models = [model]
    try
        result = BT.dev_request(state, "chat_messaging", Dict("action" => "send",
            "project_id" => target.id, "text" => "GPU is free",
            "sender_id" => "forged", "sent_at" => "yesterday"), sender.id)
        entry = only(model.pending_sends)
        @test entry.mode === :next
        @test entry.origin.project_id == sender.id
        @test entry.origin.worker_id == sender.worker_id
        @test result["message_id"] == entry.id == entry.origin.id
        @test result["sent_at"] == BT.message_timestamp(entry.origin.sent_at)
        queued = only(BT.queue_event(model)["items"])["text"]
        @test occursin("Message from chat \"GPU coordinator\"", queued)
        @test occursin("Sent at (server UTC): " * result["sent_at"], queued)
        @test !occursin("Dispatched at", queued)
        @test endswith(queued, "\n\nGPU is free")

        # Queue persistence keeps the original time/identity, even if the
        # sender is renamed before the receiver becomes available.
        sender.title[] = "Renamed sender"
        restored = BT.ChatModel(state, target.server_path; project_id = target.id,
            agent = BT.WorkerAgent(state, target.worker_id, target.worker_path; project_id = target.id))
        push!(models, restored)
        saved = only(restored.pending_sends)
        @test saved.origin.sent_at == entry.origin.sent_at
        @test saved.origin.title == "GPU coordinator"
        @test saved.id == entry.id
        dispatch = entry.origin.sent_at + Second(125)
        payload = BT.submission_payload(saved; dispatched_at = dispatch)
        @test occursin("Dispatched at (server UTC): " * BT.message_timestamp(dispatch), payload.message.text)
        @test occursin("Queued for: 125.0s", payload.message.text)
        @test occursin("Sent at (server UTC): " * result["sent_at"], payload.message.text)
        @test endswith(payload.message.text, "\n\nGPU is free")
        @test payload.text == payload.message.text
        @test saved.bubble.text == "GPU is free" # retry cannot nest envelopes
        @test BT.submission_payload(saved; dispatched_at = dispatch).message.text == payload.message.text

        # Old queues without origin metadata still load as ordinary messages.
        rows = JSON.parsefile(BT.pending_path(restored))
        delete!(only(rows), "origin")
        open(io -> JSON.print(io, rows), BT.pending_path(restored), "w")
        legacy = BT.ChatModel(state, target.server_path; project_id = target.id,
            agent = BT.WorkerAgent(state, target.worker_id, target.worker_path; project_id = target.id))
        push!(models, legacy)
        @test only(legacy.pending_sends).origin === nothing
        @test BT.submission_payload(only(legacy.pending_sends)).message.text == "GPU is free"
    finally
        foreach(close, models)
    end
end
