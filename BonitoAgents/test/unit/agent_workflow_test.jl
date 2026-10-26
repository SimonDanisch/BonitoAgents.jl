@testitem "unit:agent_workflow" tags = [:unit] begin
    using BonitoAgents, BonitoMCP, JSON
    const BT = BonitoAgents
    const MCP = BonitoMCP

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    p = BT.ProjectInfo("workflow", "project", "worker", "/server/project", "/worker/project", BT.now(BT.UTC))
    state.projects[][p.id] = p
    BT.set_global_agents_md!(state, "Keep render outputs in ./renders.")
    env = BT.mcp_env(state, p.id)
    briefing = env["BONITOAGENTS_INSTRUCTIONS"]
    @test briefing == BT.agents_prompt_appendix(state, p.id)
    @test occursin("Keep render outputs in ./renders.", briefing)
    @test occursin("[source](./src/app.jl)", briefing)
    @test occursin("BonitoProgress.progress", briefing)
    @test occursin("bt_julia_wait", briefing)

    # The standard MCP handshake and the discoverable tool carry the same
    # current chat briefing, without any provider-specific session metadata.
    withenv("BONITOAGENTS_INSTRUCTIONS" => briefing) do
        out = IOBuffer()
        MCP.dispatch!(out, Dict("id" => 1, "method" => "initialize"))
        reply = JSON.parse(String(take!(out)))
        @test reply["result"]["instructions"] == briefing
        MCP.dispatch!(out, Dict("id" => 2, "method" => "tools/call",
            "params" => Dict("name" => "bt_help", "arguments" => Dict())))
        reply = JSON.parse(String(take!(out)))
        @test reply["result"]["content"][1]["text"] == briefing
    end
    withenv("BONITOAGENTS_INSTRUCTIONS" => nothing) do
        @test MCP.workflow_instructions() == MCP.AGENT_WORKFLOW
        @test any(t -> t.name == "bt_help", MCP.available_tools())
    end

    # A later session receives edited instructions, rather than a stale copy.
    BT.set_global_agents_md!(state, "Keep render outputs in ./new-renders.")
    @test occursin("./new-renders", BT.mcp_env(state, p.id)["BONITOAGENTS_INSTRUCTIONS"])
    @test !haskey(env, "BONITOAGENTS_DEV_TOOLS")
end
