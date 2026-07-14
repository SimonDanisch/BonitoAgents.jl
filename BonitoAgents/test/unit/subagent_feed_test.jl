@testitem "unit:subagent_feed" tags = [:unit] begin

# Subagent visibility, headless server-side contract (no worker / browser):
# `route_subagent_activity!` — the sink `begin_turn!` installs as `prompt!`'s
# `on_subagent` — must feed the parent `TaskToolMsg`'s BOUNDED activity feed
# (coalescing prose chunks, upserting sub-tool status by id), stamp
# `last_activity_at`, ship one `task_activity` wire event per noted entry,
# and DROP events whose parent Task is unknown. `close` leaves a one-line
# "N steps, finished HH:MM" trace in the persisted summary (once, even on a
# double close), and `taskbar_activity` reports the pill's current-activity
# line + the staleness flip once the feed goes quiet.

using Test
using BonitoAgents
using Bonito: on
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# A ChatModel with a never-started WorkerAgent: valid for the message-lifecycle
# paths (send!/route/close only touch msgs_store, comm and chat_dir).
function headless_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    return BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
end

task_call(id) = ACP.TaskCall(id, "other", "Investigate", "in_progress",
    ACP.ToolContent[], Channel{ACP.ToolCall}(4),
    "Investigate the thing", "go do it", true, nothing, "")

act_text(pid, s)              = ACP.SubagentActivity(pid, :text, "", s, "")
act_tool(pid, tid, tl, st)    = ACP.SubagentActivity(pid, :tool, tid, tl, st)

@testset "routing feeds the parent TaskToolMsg" begin
    model = headless_model()
    m = BT.send!(model, BT.to_message(model, task_call("task-1")))
    @test m isa BT.TaskToolMsg

    wire = Dict{String,Any}[]
    on(d -> d["type"] == "task_activity" && push!(wire, copy(d)), model.comm)

    t0 = m.last_activity_at
    # Consecutive prose chunks coalesce into ONE feed entry.
    BT.route_subagent_activity!(model, act_text("task-1", "scanning "))
    BT.route_subagent_activity!(model, act_text("task-1", "the sources"))
    @test length(m.activity) == 1
    @test m.activity[1].kind === :text
    @test m.activity[1].label == "scanning the sources"
    @test m.last_activity_at >= t0

    # A sub-tool announcement opens an entry; its update rewrites it in place.
    BT.route_subagent_activity!(model,
        act_tool("task-1", "sub-1", "Grep parse_update", "in_progress"))
    BT.route_subagent_activity!(model, act_tool("task-1", "sub-1", "", "completed"))
    @test length(m.activity) == 2
    @test m.activity[2].kind === :tool
    @test m.activity[2].label == "Grep parse_update"   # late empty title keeps the old one
    @test m.activity[2].status == "completed"

    # Prose after a tool entry starts a NEW text entry (runs don't merge
    # across tool boundaries).
    BT.route_subagent_activity!(model, act_text("task-1", "done searching"))
    @test length(m.activity) == 3

    # One wire event per noted activity, upserts keyed by eid.
    @test length(wire) == 5
    @test all(d -> d["id"] == "task-1", wire)
    @test wire[1]["entry"]["eid"] == wire[2]["entry"]["eid"]     # coalesced text
    @test wire[3]["entry"]["eid"] == wire[4]["entry"]["eid"]     # tool upsert
    @test wire[4]["entry"]["status"] == "completed"
    @test wire[5]["entry"]["eid"] == 3

    # Unknown parent id → dropped, no wire event, no throw.
    BT.route_subagent_activity!(model, act_text("nope", "INTRUDER"))
    @test length(wire) == 5
    @test all(msg -> !(msg isa BT.AgentMsg), model.msgs_store)   # nothing interleaved

    # Header snapshot carries the feed for remounts.
    d = BT.tool_header_dict(m)
    @test length(d["task_feed"]) == 3
    @test d["task_feed"][3]["label"] == "done searching"

    # Bounded window: 60 more distinct sub-tools keep only the last 50
    # entries, while activity_seq keeps the true total for the close summary.
    for i in 1:60
        BT.route_subagent_activity!(model,
            act_tool("task-1", "flood-$i", "tool $i", "completed"))
    end
    @test length(m.activity) == 50
    @test m.activity_seq == 63
    @test m.activity[end].label == "tool 60"

    # Feed labels are one-line and capped.
    BT.route_subagent_activity!(model, act_text("task-1", "x"^500 * "\nmore"))
    @test length(m.activity[end].label) <= 140
    @test !occursin('\n', m.activity[end].label)
end

@testset "close stamps the one-line feed trace exactly once" begin
    model = headless_model()
    m = BT.send!(model, BT.to_message(model, task_call("task-2")))
    BT.route_subagent_activity!(model, act_text("task-2", "working"))
    BT.route_subagent_activity!(model,
        act_tool("task-2", "s1", "Read foo.jl", "completed"))
    m.status = "completed"
    close(m)
    @test occursin(r"2 steps, finished \d\d:\d\d", m.summary)
    close(m)                                            # double close (stop + drain finally)
    @test length(collect(eachmatch(r"steps, finished", m.summary))) == 1

    # No activity → no note.
    m2 = BT.send!(model, BT.to_message(model, task_call("task-3")))
    m2.status = "completed"
    close(m2)
    @test !occursin("steps, finished", m2.summary)
end

@testset "taskbar_activity: the feed's current one-liner (a fact, no staleness)" begin
    model = headless_model()
    m = BT.send!(model, BT.to_message(model, task_call("task-4")))

    # Fresh task, no activity yet: nothing to show.
    @test BT.taskbar_activity(m, time()) === nothing

    BT.route_subagent_activity!(model, act_text("task-4", "compiling shaders"))
    @test BT.taskbar_activity(m, time()) == "compiling shaders"

    # A quiet feed does NOT flip anything — no staleness guess, no timeout. The
    # line stays the latest fact off the wire (backdating changes nothing).
    m.last_activity_at = time() - 200.0
    @test BT.taskbar_activity(m, time()) == "compiling shaders"

    # Finished task: no activity affordance at all. This `m` was never pushed
    # into the bar (foreground path), so `close(m)` (terminal status +
    # finished_at) makes `is_live` false and the affordance disappears. A
    # background subagent instead leaves via `finished!` (fd-close / ⊗ stop);
    # membership IS liveness, there is no `task_running` flag to clear.
    m.status = "completed"
    close(m)
    @test BT.taskbar_activity(m, time()) === nothing
end

@testset "activity arriving BEFORE its parent Task is held, then replayed" begin
    # The foreground-subagent race: claude tags the subagent's chunks with
    # `parentToolUseId` and streams them the instant the Task launches, but the
    # parent Task tool_call is still queued in the async message consumer, so
    # NO parent TaskToolMsg exists in msgs_store yet. Subagent activity is
    # delivered out of band (the consumer parks draining the parent Task's own
    # update channel for the whole run), so it can precede the parent's commit.
    # Dropping here lost the whole feed — the "subagents don't show up" bug.
    model = headless_model()
    wire = Dict{String,Any}[]
    on(d -> d["type"] == "task_activity" && push!(wire, copy(d)), model.comm)

    BT.route_subagent_activity!(model, act_text("task-race", "scanning "))
    BT.route_subagent_activity!(model, act_text("task-race", "the repo"))
    BT.route_subagent_activity!(model,
        act_tool("task-race", "s1", "Grep parse_update", "in_progress"))
    # Held, not dropped: nothing interleaved into the transcript, no wire event
    # yet (there is nothing to attach to).
    @test all(msg -> !(msg isa BT.AgentMsg), model.msgs_store)
    @test isempty(wire)

    # The parent Task tool_call finally drains through the consumer.
    m = BT.send!(model, BT.to_message(model, task_call("task-race")))
    @test m isa BT.TaskToolMsg

    # The held activity replays into the feed IN ORDER: the two prose chunks
    # coalesce into one text entry, the sub-tool keeps its own entry. One wire
    # event per replayed activity (matching the live path).
    @test length(m.activity) == 2
    @test m.activity[1].kind === :text
    @test m.activity[1].label == "scanning the repo"
    @test m.activity[2].kind === :tool
    @test m.activity[2].label == "Grep parse_update"
    @test length(wire) == 3

    # A parent id that NEVER lands is still harmless: held, never emitted,
    # never interleaved.
    BT.route_subagent_activity!(model, act_text("ghost", "INTRUDER"))
    @test length(wire) == 3
    @test all(msg -> !(msg isa BT.AgentMsg), model.msgs_store)
end

end
