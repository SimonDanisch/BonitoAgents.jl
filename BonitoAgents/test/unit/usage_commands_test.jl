@testitem "unit:usage_commands" tags = [:unit] begin

# `usage_update` (context/cost telemetry) and `available_commands_update`
# (slash commands) — both verified against claude-agent-acp v0.44.0 source +
# real acp.jsonl logs. They used to fall through to `UnknownUpdate` and were
# silently dropped; now they parse into typed notifs, coalesce into metadata
# Messages, and land on ChatModel observables (header context meter, composer
# autocomplete).

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

function headless_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    return BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
end

@testset "usage_update parses (with and without cost / origin)" begin
    # Old wire shape (pre-0.44, from a real log): no cost, no meta.
    u = ACP.parse_session_update_kind(Dict(
        "sessionUpdate" => "usage_update", "used" => 21784, "size" => 200000))
    @test u isa ACP.UsageUpdateNotif
    @test u.used == 21784 && u.size == 200000
    @test u.cost_amount === nothing && u.origin_kind === nothing
    # v0.44 shape: cost + origin meta.
    u = ACP.parse_session_update_kind(Dict(
        "sessionUpdate" => "usage_update", "used" => 1000, "size" => 200000,
        "cost" => Dict("amount" => 0.42, "currency" => "USD"),
        "_meta" => Dict("_claude/origin" => Dict("kind" => "task-notification"))))
    @test u.cost_amount == 0.42
    @test u.cost_currency == "USD"
    @test u.origin_kind == "task-notification"
end

@testset "available_commands_update parses (hint flattened, junk skipped)" begin
    u = ACP.parse_session_update_kind(Dict(
        "sessionUpdate" => "available_commands_update",
        "availableCommands" => Any[
            Dict("name" => "compact", "description" => "Compact the chat",
                 "input" => nothing),
            Dict("name" => "review", "description" => "Review a PR",
                 "input" => Dict("hint" => "[pr number]")),
            "not-a-dict",
        ]))
    @test u isa ACP.AvailableCommandsUpdateNotif
    @test length(u.commands) == 2
    @test u.commands[1].name == "compact" && u.commands[1].hint === nothing
    @test u.commands[2].hint == "[pr number]"
end

@testset "process! lands usage + commands on the chat observables" begin
    model = headless_model()
    s = BT.shared(model)
    @test s.usage[] === nothing

    BT.process!(model, ACP.UsageUpdate(21784, 200000, nothing, nothing, nothing))
    @test s.usage[] == (used = 21784, size = 200000, cost = nothing, origin = nothing)
    BT.process!(model, ACP.UsageUpdate(50000, 200000, 1.5, "USD", nothing))
    @test s.usage[].cost == 1.5

    cmds = [ACP.CommandInfo("compact", "Compact the chat", nothing),
            ACP.CommandInfo("review", "Review a PR", "[pr number]")]
    BT.process!(model, ACP.CommandsUpdate(cmds))
    @test s.available_commands[] == cmds
    # The comm event JS autocomplete consumes rode along.
    ev = s.comm[]
    @test ev["type"] == "commands"
    @test ev["items"] == [
        Dict{String,Any}("name" => "compact", "description" => "Compact the chat", "hint" => ""),
        Dict{String,Any}("name" => "review", "description" => "Review a PR", "hint" => "[pr number]")]

    # Metadata messages stay out of replay history (and, regression: the
    # config/mode kinds finally have explicit policies too — a replayed
    # metadata message used to MethodError the reconciler's filter).
    @test !BT.keep_in_history(ACP.UsageUpdate(1, 2, nothing, nothing, nothing))
    @test !BT.keep_in_history(ACP.CommandsUpdate(ACP.CommandInfo[]))
    @test !BT.keep_in_history(ACP.ConfigUpdate(ACP.ConfigOption[]))
    @test !BT.keep_in_history(ACP.ModeUpdate("default"))
end

@testset "usage_label formatting" begin
    @test BT.usage_label(nothing) == ""
    @test BT.usage_label((used = 21784, size = 200000, cost = nothing, origin = nothing)) ==
          "21.8k/200k · 11%"
    @test BT.usage_label((used = 21784, size = 200000, cost = 0.421, origin = nothing)) ==
          "21.8k/200k · 11% · \$0.42"
    @test BT.usage_label((used = 1_500_000, size = 2_000_000, cost = nothing, origin = nothing)) ==
          "1.5M/2M · 75%"
    @test BT.usage_label((used = 999, size = 0, cost = nothing, origin = nothing)) == "999/0"
end

end
