@testitem "unit:subagent_revive" tags = [:unit] begin

# A background subagent that a SendMessage runs again goes back into the bar, and
# the turn whose prompt started or revived a running one ends at its reply:
# Claude's adapter holds that prompt's answer until the subagent is done
# (`holds_answer`). Also for a subagent from before a server restart, whose card
# comes back from chat.md with the id and transcript its launch result named. On
# 2026-11-11 a revived subagent ran for an hour with nothing in the bar.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# A ChatModel with a never-started WorkerAgent: no worker, so nothing follows
# the transcript and a card in the bar stays as it is put there. A second one on
# the same `state` is the chat after a server restart: it reads the same chat.md.
server_state() = BT.serve(; host = "127.0.0.1", port = 0,
                          state_dir = mktempdir(), working_dir = mktempdir())
headless_model(state = server_state()) =
    BT.ChatModel(state, "/p"; project_id = "proj", agent = BT.WorkerAgent(state, "w1", "/p"))

# The background launch as its result leaves it: completed, with the subagent's
# id and transcript.
launch(id, agent_id) = ACP.TaskCall(id, "think", "helper", "completed",
    ACP.ToolContent[ACP.TextContent("Async agent launched successfully.")],
    ACP.MessageStream{ACP.ToolCall}(), "helper", "work in the background", true, nothing,
    "/tmp/claude/tasks/$(agent_id).output", agent_id)

function send_message(id, agent_id)
    tc = ACP.GenericTool(id, "other", "SendMessage", "completed", ACP.ToolContent[])
    tc.name = "SendMessage"
    tc.resumed_agent = agent_id
    return tc
end

nstore(model) = length(BT.shared(model).msgs_store)

@testset "the launch result names the subagent" begin
    raw = Dict{String,Any}("_meta" => Dict{String,Any}("claudeCode" => Dict{String,Any}(
        "toolResponse" => Dict{String,Any}("agentId" => "a1", "outputFile" => "/t/a1.output",
                                           "status" => "async_launched"))))
    @test ACP.async_agent_id(raw) == "a1"
    @test ACP.async_output_file(raw) == "/t/a1.output"
    resumed = Dict{String,Any}("_meta" => Dict{String,Any}("claudeCode" => Dict{String,Any}(
        "toolResponse" => Dict{String,Any}("success" => true, "resumedAgentId" => "a1"))))
    @test ACP.resumed_agent_id(resumed) == "a1"
    resumed["_meta"]["claudeCode"]["toolResponse"]["success"] = false
    @test ACP.resumed_agent_id(resumed) === nothing
    @test ACP.resumed_agent_id(raw) === nothing
end

@testset "a SendMessage puts the subagent back in the bar" begin
    model = headless_model()
    tc = launch("toolu_launch", "a1")
    m = BT.send!(model, BT.to_message(model, tc))
    BT.update_from_snap!(m, tc)
    @test m isa BT.TaskToolMsg && m.agent_id == "a1"
    @test !BT.in_taskbar(m)                      # its run is over
    turn_start = nstore(model)
    @test !BT.holds_answer(model, turn_start)

    sm = send_message("toolu_send", "a1")
    card = BT.send!(model, BT.to_message(model, sm))
    BT.update_from_snap!(card, sm)
    @test BT.in_taskbar(m)
    @test m.phase isa BT.Executing
    @test m.bg_offset == -1                     # followed from the transcript's end
    @test BT.tool_status(m) == "in_progress"
    # The turn that revived it waits on it; a later turn does not.
    @test BT.holds_answer(model, turn_start)
    @test !BT.holds_answer(model, nstore(model) + 1)

    # A second SendMessage while it works changes nothing.
    offset = m.since_store
    BT.update_from_snap!(card, sm)
    @test m.since_store == offset

    # One that names no subagent of this chat leaves the bar alone.
    BT.update_from_snap!(card, send_message("toolu_other", "zz"))
    @test count(t -> t isa BT.TaskToolMsg, BT.chat_taskbar(model).items[]) == 1
end

@testset "after a restart, the card from chat.md is revived" begin
    state = server_state()
    model = headless_model(state)
    tc = launch("toolu_launch", "a1")
    m = BT.send!(model, BT.to_message(model, tc))
    BT.update_from_snap!(m, tc)
    BT.persist_tool_content!(model.chat_dir, tc)
    close(m)                                     # finished: its block goes to chat.md

    restarted = headless_model(state)
    restored = only(t for t in BT.shared(restarted).msgs_store if t isa BT.TaskToolMsg)
    @test BT.tool_id(restored) == "toolu_launch"
    @test restored.agent_id == "a1"
    @test restored.bg_output_path == "/tmp/claude/tasks/a1.output"
    @test restored.description == "helper"
    @test !BT.in_taskbar(restored)

    turn_start = nstore(restarted)
    sm = send_message("toolu_send", "a1")
    card = BT.send!(restarted, BT.to_message(restarted, sm))
    BT.update_from_snap!(card, sm)
    @test BT.in_taskbar(restored)
    @test BT.holds_answer(restarted, turn_start)
end

end
