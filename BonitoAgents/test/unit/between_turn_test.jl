@testitem "unit:between_turn" tags = [:unit] begin

# BETWEEN-TURN (auto-wake) rendering, headless (no worker / browser).
#
# When the agent detaches a background task it resolves the ACP prompt with
# `end_turn`; when that task finishes it auto-wakes and streams a WHOLE turn of
# work — text, tools, plans — on the same session with NO `session/prompt`
# wrapping it. The ACP dispatcher hands those sink-less updates to
# `handle_orphan_update!`, which must give them the SAME sink a live turn gets:
# a `TurnState` coalescer + `process!` consumer. The regression this guards is
# #23 — the old handler only appended agent text to ONE never-closed bubble and
# DROPPED every tool_call / plan, so an auto-wake work session collapsed into a
# single merged bubble with the tools erased.

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

amc(s) = ACP.AgentMessageChunk(ACP.TextContent(s))
toolnotif(id, title) = ACP.ToolCallNotif(id, title, "execute", "completed",
    [], ACP.ToolCallLocation[], "Bash", Dict{String,Any}(), Dict{String,Any}())
planupd(items) = ACP.PlanUpdate([ACP.PlanEntry(c, "medium", st) for (c, st) in items])
bg_task_call(id) = ACP.TaskCall(id, "other", "Run tests", "in_progress",
    ACP.ToolContent[], Channel{ACP.ToolCall}(4),
    "Run the suite", "go", true, nothing, "")   # run_in_background = true, no outputFile

@testset "text/tool/text keeps boundaries — tool NOT dropped, text NOT merged (#23)" begin
    model = headless_model()
    # The exact shape that reproduced #23 on the wire: two text chunks, a tool,
    # then more text. Old handler → 1 merged bubble, tool gone. Fixed → 3 msgs.
    BT.handle_orphan_update!(model, amc("First paragraph. "))
    BT.handle_orphan_update!(model, amc("Still first paragraph."))
    BT.handle_orphan_update!(model, toolnotif("tool-1", "grep something"))
    BT.handle_orphan_update!(model, amc("Second paragraph after the tool."))
    BT.finish_between_turn!(model)   # next-prompt boundary: barrier render + close

    store = BT.shared(model).msgs_store
    @test length(store) == 3
    @test store[1] isa BT.AgentMsg
    @test store[1].text == "First paragraph. Still first paragraph."
    @test store[2] isa BT.ToolMsg                       # the tool survived
    @test BT.tool_title(store[2]) == "grep something"
    @test store[3] isa BT.AgentMsg
    @test store[3].text == "Second paragraph after the tool."
    # Both bubbles are finalized (not stuck streaming) after the barrier.
    @test store[1].in_flight == false
    @test store[3].in_flight == false
    # Sink torn down.
    @test BT.shared(model).between_turn[] === nothing
end

@testset "a between-turn plan is finalized into history at episode end" begin
    model = headless_model()
    BT.handle_orphan_update!(model, amc("Working on it. "))
    BT.handle_orphan_update!(model, toolnotif("t1", "read file"))
    BT.handle_orphan_update!(model, planupd([("step a", "completed"),
                                             ("step b", "in_progress")]))
    BT.handle_orphan_update!(model, amc("Now the second part."))
    BT.finish_between_turn!(model)

    store = BT.shared(model).msgs_store
    todos = filter(m -> m isa BT.TodoListMsg, store)
    @test length(todos) == 1
    @test todos[1].finished_at !== nothing                    # finalized, not live
    @test [(e.content, e.status) for e in todos[1].entries] ==
          [("step a", "completed"), ("step b", "in_progress")]
    @test BT.shared(model).live_todo[] === nothing            # live slot cleared
end

@testset "auto-wake renders but does NOT guess a subagent pill's completion" begin
    # The old heuristic ("exactly one running bg task → the auto-wake announcement
    # IS its completion") is gone: a subagent pill leaves the bar ONLY by the
    # deterministic file-based signal (`finished!` off its transcript `outputFile`
    # fd-close), never by counting. So the announcement renders, the pill stays
    # in the bar.
    model = headless_model()
    pill = BT.send!(model, BT.to_message(model, bg_task_call("task-BG")))
    push!(BT.chat_taskbar(model), pill)                      # enters the bar (as the tool lifecycle does)
    @test pill isa BT.TaskToolMsg
    @test BT.in_taskbar(pill)                                # live at turn end = in the bar
    BT.handle_orphan_update!(model, amc("Background suite finished, all green."))
    BT.finish_between_turn!(model)
    @test BT.in_taskbar(pill)                                # NOT guessed done by the auto-wake — still in the bar
    ann = last(filter(m -> m isa BT.AgentMsg, BT.shared(model).msgs_store))
    @test ann.text == "Background suite finished, all green."
    # The deterministic signal (the bar's loop off the transcript file's fd-close)
    # is what ends it.
    BT.finished!(pill)
    @test !BT.in_taskbar(pill)
    @test !BT.is_pinned(model, "task-BG")
end

@testset "tool boundary renders LIVE, before the next-prompt barrier" begin
    model = headless_model()
    BT.handle_orphan_update!(model, amc("Working on it. "))
    BT.handle_orphan_update!(model, toolnotif("t1", "read file"))
    BT.handle_orphan_update!(model, amc("Second part."))
    # No finish yet: text1 (closed by the tool) + the tool are already rendered.
    t0 = time()
    while length(BT.shared(model).msgs_store) < 2 && time() - t0 < 5
        sleep(0.05)
    end
    store = BT.shared(model).msgs_store
    @test length(store) >= 2
    @test store[1] isa BT.AgentMsg && store[1].in_flight == false  # sealed by the tool
    @test store[2] isa BT.ToolMsg
    BT.finish_between_turn!(model)
end

@testset "the next prompt starts a fresh between-turn sink each episode" begin
    model = headless_model()
    BT.handle_orphan_update!(model, amc("First auto-wake episode."))
    BT.finish_between_turn!(model)
    @test BT.shared(model).between_turn[] === nothing
    n1 = length(BT.shared(model).msgs_store)
    BT.handle_orphan_update!(model, amc("A brand new auto-wake episode."))
    BT.finish_between_turn!(model)
    store = BT.shared(model).msgs_store
    @test length(store) == n1 + 1
    @test last(store).text == "A brand new auto-wake episode."
end

@testset "subagent-tagged between-turn updates feed the parent Task (not the transcript)" begin
    model = headless_model()
    parent = BT.send!(model, BT.to_message(model, bg_task_call("task-P")))
    sub = ACP.SubagentUpdate("task-P", amc("subagent scanning the sources"))
    BT.handle_orphan_update!(model, sub)
    # Give the coalescer a beat to route it out-of-band.
    t0 = time()
    while isempty(parent.activity) && time() - t0 < 5
        sleep(0.05)
    end
    @test any(e -> occursin("scanning the sources", e.label), parent.activity)
    # It must NOT have leaked into the main transcript as an agent bubble.
    @test !any(m -> m isa BT.AgentMsg && occursin("scanning", m.text),
               BT.shared(model).msgs_store)
    BT.finish_between_turn!(model)
end

@testset "closing a chat mid-episode winds the sink tasks down (no leak)" begin
    # The old bare-Ref `orphan_agent_msg` couldn't leak; the sink owns a
    # coalescer + a consumer task. If the chat is closed during an auto-wake
    # episode, no next prompt will ever call `finish_between_turn!`, so
    # `Base.close(::ChatModel)` must wind the tasks down itself.
    model = headless_model()
    BT.handle_orphan_update!(model, amc("Auto-wake work in progress. "))
    BT.handle_orphan_update!(model, toolnotif("t1", "some tool"))
    BT.handle_orphan_update!(model, amc("more streaming text"))
    t0 = time()
    while BT.shared(model).between_turn[] === nothing && time() - t0 < 5
        sleep(0.05)
    end
    bt = BT.shared(model).between_turn[]
    @test bt !== nothing
    close(model)                       # closed mid-episode
    t0 = time()
    while (!istaskdone(bt.coalescer) || !istaskdone(bt.consumer)) && time() - t0 < 5
        sleep(0.05)
    end
    @test istaskdone(bt.coalescer)
    @test istaskdone(bt.consumer)
    @test BT.shared(model).between_turn[] === nothing
    close(model)                       # idempotent
end

@testset "a late orphan frame after close is dropped, not resurrected" begin
    # A frame the ACP connection delivers after the chat is closed must NOT spin
    # up a fresh sink — nothing would ever tear it down (it would leak).
    model = headless_model()
    close(model)
    @test BT.handle_orphan_update!(model, amc("late frame after close")) === nothing
    @test BT.shared(model).between_turn[] === nothing
    @test !any(m -> m isa BT.AgentMsg, BT.shared(model).msgs_store)
end

end
