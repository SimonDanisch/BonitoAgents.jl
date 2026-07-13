@testitem "unit:subagent_wire_replay" tags = [:unit] begin

# GROUND TRUTH, not a hand-built mock: replay the REAL captured background-subagent
# ACP wire (`fixtures/bg_subagent_wire.jsonl`, recorded from a live claude-agent-acp
# session) through the actual parser (`parse_session_update` → `parse_update!`) and
# BonitoAgents's real `process_update!`, then assert the subagent enters the taskbar.
#
# The real sequence for ONE run_in_background Agent tool (see the fixture):
#   1. tool_call            status=pending    rawInput={}                       (nothing to detect)
#   2. tool_call_update     status=—          rawInput={run_in_background:true} (the flag, LATE)
#   3. tool_call_update     status=—          _meta…toolResponse.outputFile=…   (the async file, LATER)
#   4. tool_call_update     status=completed                                    (the launch-ack lie)
# claude-agent-acp STREAMS input, so the flag+outputFile never ride the initial
# tool_call — the bug the TK.tool mocks (flag in the INITIAL rawInput) never hit.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
import JSON

function headless_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    return BT.ChatModel(state, mktempdir(); project_id = "proj",
                        agent = BT.WorkerAgent(state, "w1", "/p"))
end

# The `update` param dicts for one tool, in wire order, straight from the fixture.
function tool_frames(path, tool_id)
    frames = Dict{String,Any}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        rec = JSON.parse(line)
        get(rec, "dir", "") == "in" || continue
        msg = get(rec, "msg", Dict()); get(msg, "method", "") == "session/update" || continue
        u = get(get(msg, "params", Dict()), "update", nothing)
        u isa AbstractDict || continue
        get(u, "toolCallId", "") == tool_id || continue
        push!(frames, u)
    end
    return frames
end

@testset "the REAL run_in_background Agent wire pins the subagent" begin
    fixture = joinpath(@__DIR__, "..", "fixtures", "bg_subagent_wire.jsonl")
    @test isfile(fixture)
    frames = tool_frames(fixture, "toolu_01ShZ2sn3y8zxXLMeR7PvWBN")
    @test [get(f, "sessionUpdate", "") for f in frames] ==
          ["tool_call", "tool_call_update", "tool_call_update", "tool_call_update"]

    chat = headless_model()
    st   = ACP.TurnState()
    out  = Channel{Any}(64)

    # Frame 1 — the initial tool_call. Build the message + render it, exactly as
    # the consumer does. At this point NOTHING marks it background yet.
    ACP.parse_update!(out, st, ACP.parse_session_update(frames[1]))
    tc  = take!(out)
    msg = BT.send!(chat, BT.to_message(chat, tc))
    @test msg isa BT.TaskToolMsg
    @test msg.is_background == false
    @test BT.in_taskbar(msg) == false

    # Frames 2..4 stream in as tool_call_updates while `process_update!` drains
    # the tool's snapshot channel — the real concurrent shape.
    drain = Base.errormonitor(@async BT.process_update!(msg, tc))
    for f in frames[2:end]
        ACP.parse_update!(out, st, ACP.parse_session_update(f))
        sleep(0.05)
    end
    wait(drain)

    # The fix: the late `run_in_background` / `outputFile` flip `is_background` and
    # `process_update!` re-pins. The subagent is now IN THE TASKBAR with its poll
    # target captured — NOT finalized by the launch-ack `completed`.
    @test msg.is_background == true
    @test !isempty(msg.bg_output_path)               # captured the transcript outputFile
    @test BT.in_taskbar(msg) == true                 # pinned = a live pill
    @test BT.is_pinned(chat, "toolu_01ShZ2sn3y8zxXLMeR7PvWBN")
end

end
