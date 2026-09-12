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
    @test isopen(message.updates)
    ACP.parse_update!(out, st, parsed)
    @test !isopen(message.updates)
    @test take!(out) isa ACP.SessionNotice
    ACP.parse_update!(out, st, ACP.AgentMessageChunk(ACP.TextContent("After")))
    @test take!(out).text == "After"
    close(st.current_message)
end
