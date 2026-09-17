@testitem "unit:persistence" tags = [:unit] begin

# Unit tests for chat.md persistence round-tripping.
#
# Regression target: `load_history` used to reconstruct admonition bodies
# from a CommonMark AST, which silently dropped block structure — paragraph
# breaks, headings and tables collapsed into one run-on line (only inline
# `code` survived). The fix parses chat.md by hand and just dedents the
# 4-space-indented body, so the message text round-trips byte-for-byte.

using Test
using Dates
using BonitoAgents

function roundtrip(msgs::Vector)
    mktempdir() do dir
        path    = joinpath(dir, "chat.md")
        session = BonitoAgents.ChatSession("sid-test", dir, now(UTC), path)
        BonitoAgents.write_session_header(session)
        for m in msgs
            if m isa BonitoAgents.UserMsg
                BonitoAgents.append_user(session, m)
            elseif m isa BonitoAgents.AgentMsg
                BonitoAgents.finalize_agent(session, m)
            elseif m isa BonitoAgents.ToolMsg
                BonitoAgents.append_tool(session, m)
            elseif m isa BonitoAgents.TodoListMsg
                BonitoAgents.append_plan(session, m)
            end
        end
        return BonitoAgents.load_history(session)
    end
end

@testset "chat.md persistence round-trip" begin
    @testset "agent message keeps block structure" begin
        # Heading, two paragraphs, a table, inline code, a fenced code block —
        # exactly the shapes the old AST-reconstruction destroyed.
        text = """
        ## Docs build verified

        The full pipeline (`SetupBuildDirectory` → `ExpandTemplates`) completed
        without errors.

        Generated images:

        | File | Size | Example |
        |------|------|---------|
        | a.png | 2.5 MB | Alps |
        | b.png | 1.9 MB | PlotConfig |

        Reproduce with:

        ```julia
        using Documenter
        makedocs()
        ```

        End-to-end works."""
        loaded = roundtrip([BonitoAgents.AgentMsg("a1", text)])
        @test length(loaded) == 1
        @test loaded[1] isa BonitoAgents.AgentMsg
        # The whole point: byte-for-byte identical (modulo outer whitespace).
        @test strip(loaded[1].text) == strip(text)
        # Spell out the structural invariants so a failure is legible.
        body = loaded[1].text
        @test occursin("## Docs build verified", body)        # heading marker kept
        @test occursin("\n\n", body)                          # paragraph breaks kept
        @test occursin("|------|------|---------|", body)      # table rows on own lines
        @test occursin("```julia\n", body)                    # fenced code block kept
        @test count("\n", body) >= 10                         # not collapsed to one line
    end

    @testset "blank lines inside the body survive" begin
        text = "First line.\n\nSecond.\n\n\nThird after a double gap."
        loaded = roundtrip([BonitoAgents.AgentMsg("a1", text)])
        @test strip(loaded[1].text) == strip(text)
    end

    @testset "user message round-trips" begin
        loaded = roundtrip([BonitoAgents.UserMsg("run the docs build\nplease")])
        @test length(loaded) == 1
        @test loaded[1] isa BonitoAgents.UserMsg
        @test strip(loaded[1].text) == "run the docs build\nplease"
    end

    @testset "tool message round-trips (kind/status/id/title/summary)" begin
        loaded = roundtrip([BonitoAgents.GenericToolMsg(
            BonitoAgents.Message("t1", "execute", "", "ls -la", "completed",
                                 "12 files", 0.0, 0.0, nothing))])
        @test length(loaded) == 1
        t = loaded[1]
        @test t isa BonitoAgents.ToolMsg
        @test BonitoAgents.tool_id(t) == "t1"
        @test BonitoAgents.tool_kind(t) == "execute"
        @test BonitoAgents.tool_title(t) == "ls -la"
        @test BonitoAgents.tool_status(t) == "completed"
        @test BonitoAgents.tool_summary(t) == "12 files"
    end

    @testset "a reloaded tool keeps the type that renders it" begin
        # Reload used to rebuild EVERY tool as the generic variant. That is fine
        # for a Bash pill (its body is its text) and wrong for an edit: the body
        # of an edit is its DIFF, rebuilt from the call's own rawInput by the
        # EditToolMsg renderer, so a reopened refactor showed "The file … has
        # been updated successfully" where the diff belonged. The persisted
        # header carries kind + name, which is the same routing the live path
        # uses.
        loaded = roundtrip([
            BonitoAgents.GenericToolMsg(
                BonitoAgents.Message("e1", "edit", "Edit", "Edit src/a.jl",
                                     "completed", "a.jl · +1 line", 0.0, 0.0, nothing)),
            BonitoAgents.GenericToolMsg(
                BonitoAgents.Message("r1", "read", "Read", "Read src/a.jl",
                                     "completed", "19 lines", 0.0, 0.0, nothing)),
            # MCP tools stay generic ON PURPOSE: a restored `bt_julia_eval`
            # would try to mount a live result embed against a RemoteRef that
            # died with its worker.
            BonitoAgents.GenericToolMsg(
                BonitoAgents.Message("m1", "other", "bt_julia_eval", "bt_julia_eval",
                                     "completed", "env /p", 0.0, 0.0, nothing)),
        ])
        @test loaded[1] isa BonitoAgents.EditToolMsg
        @test loaded[2] isa BonitoAgents.ReadToolMsg
        @test loaded[3] isa BonitoAgents.GenericToolMsg
        # …and the header fields still survive the round trip.
        @test BonitoAgents.tool_id(loaded[1]) == "e1"
        @test BonitoAgents.tool_status(loaded[1]) == "completed"
        @test BonitoAgents.tool_summary(loaded[1]) == "a.jl · +1 line"
    end

    @testset "plan message round-trips" begin
        loaded = roundtrip([BonitoAgents.TodoListMsg([
            BonitoAgents.PlanEntry("step one", "", "completed"),
            BonitoAgents.PlanEntry("step two", "", "pending"),
        ])])
        @test length(loaded) == 1
        p = loaded[1]
        @test p isa BonitoAgents.TodoListMsg
        @test [(e.content, e.status) for e in p.entries] ==
              [("step one", "completed"), ("step two", "pending")]
    end

    @testset "mixed conversation preserves order" begin
        loaded = roundtrip([
            BonitoAgents.UserMsg("hi"),
            BonitoAgents.GenericToolMsg(
                BonitoAgents.Message("t1", "execute", "", "ls", "completed", "ok",
                                     0.0, 0.0, nothing)),
            BonitoAgents.AgentMsg("a1", "## Result\n\nAll done."),
        ])
        @test length(loaded) == 3
        @test loaded[1] isa BonitoAgents.UserMsg
        @test loaded[2] isa BonitoAgents.ToolMsg
        @test loaded[3] isa BonitoAgents.AgentMsg
        @test occursin("## Result", loaded[3].text)
        @test occursin("\n\n", loaded[3].text)
    end
end

end
