# A finished Edit keeps its diff. claude-agent-acp (0.84.0, captured verbatim
# into AgentClientProtocol/test/fixtures) streams the diff mid-flight and ends
# with only `rawOutput` "The file … has been updated successfully.", which used
# to replace the diff: the card showed that sentence. Announced as a JetBrains
# AIR client the adapter also leaves `old_string`/`new_string` out of the input,
# so the card could not even rebuild the diff from the edit's arguments.
@testitem "unit:claude_edit_keeps_diff" tags = [:unit] begin
    import AgentClientProtocol
    import BonitoAgents
    import JSON
    const ACP = AgentClientProtocol

    fixtures = joinpath(dirname(dirname(pathof(ACP))), "test", "fixtures")
    function replay(lines)
        out = Channel{Any}(256)
        st  = ACP.TurnState()
        for l in lines
            ACP.parse_update!(out, st, ACP.parse_session_update(JSON.parse(l)))
        end
        ACP.close_turn!(out, st); close(out)
        return only(x for x in collect(out) if x isa ACP.ToolCall)
    end

    @testset "$file" for file in ("claude_edit_wire.jsonl", "claude_edit_air_wire.jsonl")
        tc = replay(readlines(joinpath(fixtures, file)))
        @test tc.status == "completed"
        d = only(tc.content)
        @test d isa ACP.DiffContent
        @test (d.old_text, d.new_text) == ("hello foo", "hello bar")
        @test BonitoAgents.replayed_tool_msg(tc) isa BonitoAgents.EditToolMsg
    end

    @testset "a failed edit shows why" begin
        lines = readlines(joinpath(fixtures, "claude_edit_wire.jsonl"))
        lines[end] = JSON.json(Dict("sessionUpdate" => "tool_call_update",
            "toolCallId" => "toolu_01ViULGSbNPrD66Vz3uzVJx3", "status" => "failed",
            "rawOutput" => "String to replace not found in file."))
        tc = replay(lines)
        @test tc.status == "failed"
        @test only(tc.content) isa ACP.TextContent
        @test only(tc.content).text == "String to replace not found in file."
    end
end
