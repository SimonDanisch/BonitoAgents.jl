# The SAME MCP tool must produce the SAME typed card no matter which agent ran
# it. Only claude-agent-acp states the tool's name outright; the others label it
# their own way, and before `resolve_mcp_tool` that made `bt_julia_eval` render
# as a bare generic card — no code preview, the eval descriptor leaking through
# as raw text — depending purely on the backend.
#
# Driven by frames captured VERBATIM from the real binaries driving the real
# btworker MCP server (AgentClientProtocol/test/fixtures/*.jsonl), because this
# is exactly the class of bug a hand-written mock hides: every agent's shape
# here was a surprise.
@testitem "unit:agent_tool_naming" tags = [:unit] begin
    import AgentClientProtocol
    import JSON
    const ACP = AgentClientProtocol

    fixtures = joinpath(dirname(dirname(pathof(ACP))), "test", "fixtures")

    # Replay one captured turn through the real parser and return its tool call.
    function replay_tool(file)
        out = Channel{Any}(256)
        st  = ACP.TurnState()
        for l in eachline(joinpath(fixtures, file))
            ACP.parse_update!(out, st, ACP.parse_session_update(JSON.parse(l)))
        end
        ACP.close_turn!(out, st); close(out)
        return only([x for x in collect(out) if x isa ACP.ToolCall])
    end

    @testset "$agent renders bt_julia_eval as the typed eval card" for (agent, file) in (
            ("kimi",     "kimi_mcp_tool_call.jsonl"),
            ("opencode", "opencode_mcp_tool_call.jsonl"))
        tc = replay_tool(file)
        m  = BonitoAgents.replayed_tool_msg(tc)
        @test m isa BonitoAgents.JuliaEvalToolMsg
        @test BonitoAgents.tool_key(m) == "bt_julia_eval"
        @test m.server == "btworker"
        # The code preview is filled — the user-visible symptom was an empty one.
        @test m.code == "1+1"
        @test !isempty(m.env_path)
        # Only the tool's real result reaches the body; no argument JSON.
        @test [c.text for c in tc.content if c isa ACP.TextContent] == ["2"]
    end

    # Kimi's NATIVE tools. Two independent things have to line up: the name has
    # to survive (it is only in the opening title), and the argument keys differ
    # from claude's (`path` vs `file_path`), each of which alone leaves the card
    # blank.
    @testset "kimi native tools render with their arguments" begin
        cards = Dict{DataType,Vector{Any}}()
        for file in ("kimi_native_tools.jsonl", "kimi_native_edit_search.jsonl")
            out = Channel{Any}(2048)
            st  = ACP.TurnState()
            for l in eachline(joinpath(fixtures, file))
                ACP.parse_update!(out, st, ACP.parse_session_update(JSON.parse(l)))
            end
            ACP.close_turn!(out, st); close(out)
            for tc in collect(out)
                tc isa ACP.ToolCall || continue
                m = BonitoAgents.replayed_tool_msg(tc)
                push!(get!(cards, typeof(m), Any[]), m)
            end
        end

        reads = get(cards, BonitoAgents.ReadToolMsg, Any[])
        @test length(reads) == 2                          # one per capture
        @test all(r -> !isempty(r.file_path), reads)      # `path`, not `file_path`

        edits = get(cards, BonitoAgents.EditToolMsg, Any[])
        @test length(edits) == 2                          # Write + Edit
        @test Set(basename.(getfield.(edits, :file_path))) == Set(["fresh.md", "notes.txt"])
        @test any(e -> e.new_string == "BETA", edits)     # the diff still resolves

        # kimi tags Grep/Glob as kind "read"; only the NAME makes them searches.
        searches = get(cards, BonitoAgents.SearchToolMsg, Any[])
        @test length(searches) == 2
        @test Set(getfield.(searches, :pattern)) == Set(["beta", "*.txt"])
        # A pattern must never masquerade as a path — `tool_path_hint` opens files.
        @test all(s -> isempty(s.path), searches)
        @test all(s -> BonitoAgents.tool_path_hint(s) === nothing, searches)

        @test length(get(cards, BonitoAgents.BashToolMsg, Any[])) == 1
        @test only(cards[BonitoAgents.BashToolMsg]).command == "echo NATIVEPROBE"
        @test length(get(cards, BonitoAgents.TaskToolMsg, Any[])) == 1
    end

    @testset "builtin_msg_type: name refines kind" begin
        B = BonitoAgents.builtin_msg_type
        # kimi's coarse kind would give a Read card for a search.
        @test B("read") == BonitoAgents.ReadToolMsg
        @test B("read", "Grep") == BonitoAgents.SearchToolMsg
        @test B("read", "Glob") == BonitoAgents.SearchToolMsg
        @test B("edit", "Write") == BonitoAgents.EditToolMsg
        # Claude already agrees, so nothing changes for it.
        @test B("search", "Grep") == BonitoAgents.SearchToolMsg
        @test B("edit", "Edit") == BonitoAgents.EditToolMsg
        # An unknown name falls back to the kind, never to a wrong card.
        @test B("read", "SomeThirdPartyTool") == BonitoAgents.ReadToolMsg
        @test B("other", "") == BonitoAgents.GenericToolMsg
    end

    @testset "resolve_mcp_tool" begin
        R = BonitoAgents.resolve_mcp_tool
        @test R("mcp__btworker__bt_julia_eval") == ("btworker", "bt_julia_eval")  # claude, kimi
        @test R("btworker_bt_julia_eval")       == ("btworker", "bt_julia_eval")  # opencode
        @test R("btworker__bt_julia_eval")      == ("btworker", "bt_julia_eval")
        @test R("bt_julia_eval")                == ("", "bt_julia_eval")          # bare
        @test R("mcp__other__bt_show")          == ("other", "bt_show")
        # Nothing we can render ⇒ unchanged behaviour, not a wrong card.
        @test R("Read") === nothing
        @test R("mcp__playwright__browser_click") === nothing
        @test R("") === nothing
        @test R("_bt_julia_eval") === nothing   # no server segment
    end
end
