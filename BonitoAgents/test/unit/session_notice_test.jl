@testitem "unit:session_notice" tags = [:unit] begin
    using BonitoAgents
    const ACP = BonitoAgents.AgentClientProtocol
    record = Dict{String,Any}("id"=>"notice-1", "revision"=>1, "severity"=>"warning",
        "category"=>"unknown", "title"=>"Provider changed transport", "actions"=>[])
    envelope = Dict{String,Any}("sessionUpdate"=>"session_info_update",
        "_meta"=>Dict("jetbrains"=>Dict("air"=>Dict("version"=>1, "sessionFailure"=>record))))
    parsed = ACP.parse_session_update(envelope)
    @test parsed isa ACP.SessionNoticeNotif
    @test parsed.record == record
    @test !ACP.is_agent_work(parsed)
    @test !BonitoAgents.keep_in_history(ACP.SessionNotice(record))

    for text in ("Warning: Falling back from WebSockets to HTTPS transport.",
                 "Warning: this is ordinary assistant prose")
        update = ACP.parse_session_update(Dict("sessionUpdate"=>"agent_message_chunk",
            "content"=>Dict("type"=>"text", "text"=>text), "_meta"=>envelope["_meta"]))
        @test update isa ACP.AgentMessageChunk
        @test update.content.text == text
    end
    @test ACP.parse_session_update(Dict("sessionUpdate"=>"session_info_update")) isa ACP.UnknownUpdate
    for (key, value) in (("severity", "other"), ("revision", "1"), ("id", ""))
        bad = deepcopy(envelope)
        bad["_meta"]["jetbrains"]["air"]["sessionFailure"][key] = value
        @test ACP.parse_session_update(bad) isa ACP.UnknownUpdate
    end
    future = deepcopy(envelope)
    future["_meta"]["jetbrains"]["air"]["version"] = 2
    @test ACP.parse_session_update(future) isa ACP.UnknownUpdate

    # The notice must release a consumer waiting on text deltas immediately.
    out = Channel{ACP.Message}(8)
    st = ACP.TurnState()
    ACP.parse_update!(out, st, ACP.AgentMessageChunk(ACP.TextContent("Before")))
    message = take!(out)
    @test isopen(message.stream)
    ACP.parse_update!(out, st, parsed)
    @test !isopen(message.stream)
    @test take!(out) isa ACP.SessionNotice
    ACP.parse_update!(out, st, ACP.AgentMessageChunk(ACP.TextContent("After")))
    @test ACP.text(take!(out)) == "After"
    close(st.current_message)
end

@testitem "unit:session_notice_lifecycle" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    cwd = mktempdir()
    model() = BT.ChatModel(state, cwd; project_id = "notices",
        agent = BT.WorkerAgent(state, "offline-worker", cwd; project_id = "notices"))
    m = model()
    models = [m]
    notice = Dict{String,Any}("id" => "retry-1", "revision" => 1,
        "severity" => "warning", "category" => "network", "title" => "Reconnecting",
        "details" => "Trying the connection again")
    process(record) = BT.process!(m, ACP.SessionNotice(record))
    dismiss(id) = BT.handle_command!(m, nothing,
        BT.parse_chat_command(Dict("type" => "notice.dismiss", "id" => id)))
    try
        process(notice)
        dismiss("retry-1")
        @test m.session_notice[]["dismissed"]
        process(merge(notice, Dict("revision" => 2, "title" => "Still reconnecting")))
        @test m.session_notice[]["dismissed"]
        @test m.session_notice[]["revision"] == 2
        process(notice)
        @test m.session_notice[]["revision"] == 2

        restored = model()
        push!(models, restored)
        @test restored.session_notice[] == m.session_notice[]
        BT.process!(restored, ACP.SessionNotice(merge(notice, Dict("revision" => 3))))
        @test restored.session_notice[]["dismissed"]

        # Escalation is meaningful new information even within the same incident.
        process(merge(notice, Dict("revision" => 3, "severity" => "error")))
        @test !m.session_notice[]["dismissed"]
        dismiss("retry-1")
        duplicate = merge(notice, Dict("id" => "retry-2", "severity" => "error"))
        process(duplicate)
        @test m.session_notice[]["dismissed"]
        different = merge(duplicate, Dict("id" => "limit-1", "category" => "limit",
            "title" => "Usage limit reached"))
        process(different)
        @test !m.session_notice[]["dismissed"]
        process(notice)
        process(duplicate)
        @test m.session_notice[]["id"] == "limit-1" # replay of retired incidents
        BT.resolve_session_notice!(m; warnings_only = true)
        @test !m.session_notice[]["resolved"] # progress is not proof a quota reset
        dismiss("retry-2") # stale tab cannot hide the new failure
        @test !m.session_notice[]["dismissed"]

        BT.resolve_session_notice!(m)
        @test m.session_notice[]["resolved"]
        process(merge(different, Dict("revision" => 10)))
        @test m.session_notice[]["resolved"]
        recovered = model()
        push!(models, recovered)
        @test recovered.session_notice[]["resolved"]
        BT.process!(recovered, ACP.SessionNotice(different))
        BT.process!(recovered, ACP.SessionNotice(notice))
        @test recovered.session_notice[]["resolved"]

        # A fresh failure after proven recovery must be visible again.
        process(merge(different, Dict("id" => "limit-2")))
        @test !m.session_notice[]["resolved"]
        @test !m.session_notice[]["dismissed"]

        progress = merge(notice, Dict("id" => "retry-progress"))
        process(progress)
        BT.resolve_session_notice!(m; warnings_only = true)
        @test m.session_notice[]["resolved"]
        process(merge(progress, Dict("revision" => 2, "severity" => "error")))
        @test !m.session_notice[]["resolved"] # escalation remains visible
        @test !m.session_notice[]["dismissed"]
    finally
        foreach(close, models)
    end
end

# claude-agent-acp takes any client announcing `_meta.jetbrains.air` for JetBrains
# AIR, and then leaves the `outputFile` out of an async subagent's launch (checked
# against 0.84.0): the card of a background agent could never finish. The
# extension goes only to the agents that use it: codex-acp and the mocks for it.
@testitem "unit:client_meta" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    air(p) = get(BT.client_meta(p), "jetbrains", nothing)
    for p in BT.current_providers()
        name = BT.provider_name(p)
        if name in ("Codex", "MockCode", "MockCode2")
            @test "sessionFailure" in air(p)["air"]["capabilities"]
        else
            @test air(p) === nothing
        end
    end
end
