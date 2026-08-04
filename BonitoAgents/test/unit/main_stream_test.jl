@testitem "unit:main_stream" tags = [:unit] begin

# The session's MAIN THREAD, headless (no worker / browser).
#
# The agent talks inside a prompt and also between prompts: when it detaches a
# background task it resolves the ACP prompt with `end_turn`, and when that task
# finishes it AUTO-WAKES and streams a whole further episode of work — text,
# tools, plans — on the same session with no `session/prompt` wrapping it.
#
# Both are the same voice on one stream, rendered by one consumer. They used to
# be two pipelines, and the second was a degenerate copy of the first: it
# appended every chunk to ONE never-closed bubble and dropped every tool_call and
# plan, so an auto-wake episode collapsed into a single merged blob with the
# tools erased (#23). These tests are that regression, restated against the one
# stream: boundaries hold, tools survive, plans finalize.
#
# Updates are put straight onto the session's raw stream (`client.updates`),
# which is exactly what `Connection.on_main_update` does. What's under test here
# is the rendering, not the addressing — that's `unit:subagent_feed` and the ACP
# dispatcher suite.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# A transport that never speaks. The `Connection` exists so the session has the
# real coalescer + cancel flag behind it; nothing is written to a wire.
mutable struct IdleTransport <: ACP.Transport
    gate::Channel{Nothing}
end
IdleTransport() = IdleTransport(Channel{Nothing}(0))
ACP.send(::IdleTransport, ::AbstractString) = nothing
ACP.recv(t::IdleTransport) = (try take!(t.gate) catch end; "")
ACP.transport_eof(t::IdleTransport) = !isopen(t.gate)
Base.close(t::IdleTransport) = (isopen(t.gate) && close(t.gate); nothing)

# A chat with a live ACP session: a real `Client` (hence a real main stream and
# coalescer) bound to a never-started WorkerAgent, plus the chat's own renderer.
function live_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    model = BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
    conn  = ACP.Connection(IdleTransport(), ACP.DiscardHandler())
    cli   = ACP.Client(conn, "sess", "/p")
    agent.client = cli
    BT.start_main_consumer!(model, cli)
    return model, cli
end

feed!(cli, u) = put!(cli.updates, u)

amc(s) = ACP.AgentMessageChunk(ACP.TextContent(s))
toolnotif(id, title) = ACP.ToolCallNotif(id, title, "execute", "completed",
    [], ACP.ToolCallLocation[], "Bash", Dict{String,Any}(), Dict{String,Any}())
planupd(items) = ACP.PlanUpdate([ACP.PlanEntry(c, "medium", st) for (c, st) in items])
bg_task_call(id) = ACP.TaskCall(id, "other", "Run tests", "in_progress",
    ACP.ToolContent[], Channel{ACP.ToolCall}(4),
    "Run the suite", "go", true, nothing, "")   # run_in_background = true, no outputFile

@testset "text/tool/text keeps boundaries — tool NOT dropped, text NOT merged (#23)" begin
    model, cli = live_model()
    # The exact shape that reproduced #23 on the wire: two text chunks, a tool,
    # then more text. Old between-turn handler → 1 merged bubble, tool gone.
    feed!(cli, amc("First paragraph. "))
    feed!(cli, amc("Still first paragraph."))
    feed!(cli, toolnotif("tool-1", "grep something"))
    feed!(cli, amc("Second paragraph after the tool."))
    BT.flush_main!(model)          # boundary: seal + wait for the render

    store = BT.shared(model).msgs_store
    @test length(store) == 3
    @test store[1] isa BT.AgentMsg
    @test store[1].text == "First paragraph. Still first paragraph."
    @test store[2] isa BT.ToolMsg                       # the tool survived
    @test BT.tool_title(store[2]) == "grep something"
    @test store[3] isa BT.AgentMsg
    @test store[3].text == "Second paragraph after the tool."
    # Both bubbles are finalized (not stuck streaming) after the boundary.
    @test store[1].in_flight == false
    @test store[3].in_flight == false
    close(model)
end

@testset "an un-prompted plan is finalized into history at the boundary" begin
    model, cli = live_model()
    feed!(cli, amc("Working on it. "))
    feed!(cli, toolnotif("t1", "read file"))
    feed!(cli, planupd([("step a", "completed"), ("step b", "in_progress")]))
    feed!(cli, amc("Now the second part."))
    BT.flush_main!(model)
    BT.finish_live_todo!(model)    # what `begin_turn!` / end-of-turn cleanup does

    store = BT.shared(model).msgs_store
    todos = filter(m -> m isa BT.TodoListMsg, store)
    @test length(todos) == 1
    @test todos[1].finished_at !== nothing                    # finalized, not live
    @test [(e.content, e.status) for e in todos[1].entries] ==
          [("step a", "completed"), ("step b", "in_progress")]
    @test BT.shared(model).live_todo[] === nothing            # live slot cleared
    close(model)
end

@testset "auto-wake renders but does NOT guess a subagent pill's completion" begin
    # The old heuristic ("exactly one running bg task → the auto-wake announcement
    # IS its completion") is gone: a subagent pill leaves the bar ONLY by the
    # deterministic file-based signal (`finished!` off its transcript `outputFile`
    # fd-close), never by counting. So the announcement renders, the pill stays
    # in the bar.
    model, cli = live_model()
    pill = BT.send!(model, BT.to_message(model, bg_task_call("task-BG")))
    push!(BT.chat_taskbar(model), pill)                      # enters the bar (as the tool lifecycle does)
    @test pill isa BT.TaskToolMsg
    @test BT.in_taskbar(pill)                                # live at turn end = in the bar
    feed!(cli, amc("Background suite finished, all green."))
    BT.flush_main!(model)
    @test BT.in_taskbar(pill)                                # NOT guessed done — still in the bar
    ann = last(filter(m -> m isa BT.AgentMsg, BT.shared(model).msgs_store))
    @test ann.text == "Background suite finished, all green."
    # The deterministic signal (the bar's loop off the transcript file's fd-close)
    # is what ends it.
    BT.finished!(pill)
    @test !BT.in_taskbar(pill)
    @test !BT.is_pinned(model, "task-BG")
    close(model)
end

@testset "a tool boundary renders LIVE, before any flush" begin
    model, cli = live_model()
    feed!(cli, amc("Working on it. "))
    feed!(cli, toolnotif("t1", "read file"))
    feed!(cli, amc("Second part."))
    # No flush yet: text1 (closed by the tool) + the tool are already rendered.
    t0 = time()
    while length(BT.shared(model).msgs_store) < 2 && time() - t0 < 5
        sleep(0.05)
    end
    store = BT.shared(model).msgs_store
    @test length(store) >= 2
    @test store[1] isa BT.AgentMsg && store[1].in_flight == false  # sealed by the tool
    @test store[2] isa BT.ToolMsg
    close(model)
end

@testset "the stream survives its boundaries — one renderer, many episodes" begin
    # Each flush is a BOUNDARY, not the end of the stream. The old design tore
    # the whole between-turn pipeline down at every prompt and lazily rebuilt it;
    # here the consumer is the same task from bind to close.
    model, cli = live_model()
    consumer = BT.shared(model).main_consumer[].task
    feed!(cli, amc("First auto-wake episode."))
    BT.flush_main!(model)
    n1 = length(BT.shared(model).msgs_store)
    @test !istaskdone(consumer)

    feed!(cli, amc("A brand new auto-wake episode."))
    BT.flush_main!(model)
    store = BT.shared(model).msgs_store
    @test length(store) == n1 + 1
    @test last(store).text == "A brand new auto-wake episode."
    @test BT.shared(model).main_consumer[].task === consumer   # same renderer throughout
    @test !istaskdone(consumer)
    close(model)
end

@testset "the renderer dies with the SESSION, not with the model" begin
    # `close(model)` deliberately leaves the ACP session alone: the model does
    # not own the client, the agent does. `stop_session!` closes the model and
    # then `stop!(agent; permanent=true)`, and THAT ends the renderer.
    #
    # Having the model close the client looked tidier and was a live bug — a
    # teardown racing a fresh bring-up for the same project closed the stream
    # the new session had just started rendering into, so replies reached
    # `msgs_store` and disk but never the screen.
    model, cli = live_model()
    feed!(cli, amc("Work in progress. "))
    feed!(cli, toolnotif("t1", "some tool"))
    feed!(cli, amc("more streaming text"))
    consumer = BT.shared(model).main_consumer[].task

    close(model)                       # the chat is dead...
    @test !isopen(BT.shared(model).user_messages)   # ... no further turns
    sleep(0.3)
    @test isopen(cli.updates)          # ... but the session is untouched
    @test !istaskdone(consumer)        # ... and its renderer is still alive
    close(model)                       # idempotent

    # Closing the CLIENT is what winds it down, which is what `stop!(agent)` does.
    close(cli)
    t0 = time()
    while !istaskdone(consumer) && time() - t0 < 5
        sleep(0.05)
    end
    @test istaskdone(consumer)
    @test !isopen(cli.updates)
end

@testset "re-binding the same client does not kill its renderer" begin
    # `start!` is idempotent and hands the existing client back, so
    # `start_chat_client!` reaches `start_main_consumer!` more than once for ONE
    # client (a bring-up, then the first turn's lazy bind). Reaping the "old"
    # consumer there would close `cli.updates` — the very stream the new one is
    # about to read — and it would exit on its first iteration, leaving a dead
    # renderer on a live connection.
    model, cli = live_model()
    first = BT.shared(model).main_consumer[].task

    BT.start_main_consumer!(model, cli)          # same client, again
    @test BT.shared(model).main_consumer[].task === first
    @test !istaskdone(first)
    @test isopen(cli.updates)

    # ... and it still renders.
    feed!(cli, amc("still here"))
    BT.flush_main!(model)
    @test any(m -> m isa BT.AgentMsg && m.text == "still here",
              BT.shared(model).msgs_store)
    close(model)
end

@testset "a frame after the session closes is dropped, not rendered" begin
    # Once the SESSION is closed a frame the connection delivers has nowhere to
    # go — and nothing to resurrect. `deliver_update!` sees the closed channel
    # and returns.
    model, cli = live_model()
    close(model)
    close(cli)
    consumer = BT.shared(model).main_consumer[].task
    t0 = time()
    while !istaskdone(consumer) && time() - t0 < 5
        sleep(0.05)
    end
    @test ACP.deliver_update!(cli.conn, cli.updates, amc("late frame after close")) === nothing
    @test !any(m -> m isa BT.AgentMsg, BT.shared(model).msgs_store)
    # And the render barrier is a no-op rather than a hang.
    @test BT.flush_main!(model) === nothing
end

@testset "the busy indicator follows the episode, and the episode ENDS" begin
    # `busy_active` may be set from arriving frames — but ONLY as an auto-wake
    # episode, which has an end marker. Setting it unconditionally was a latch
    # with no key: nothing could turn it off again, so the spinner span forever
    # over an idle chat and `note_bound!` (which skips busy chats) stopped being
    # able to evict anything.
    model, cli = live_model()
    s = BT.shared(model)
    @test s.busy_active[] == false

    # A whole episode of un-prompted work: prose, a tool, more prose.
    feed!(cli, amc("The background job finished. "))
    feed!(cli, toolnotif("t1", "read the log"))
    feed!(cli, amc("All green."))
    BT.flush_main!(model)

    # It rendered — the work is visible, which is the point...
    @test length(BT.shared(model).msgs_store) == 3
    @test s.turns_active[] == 0          # with no prompt of ours open
    # ... and the chat says so, because it can take it back.
    @test s.autowake[] == true
    @test s.busy_active[] == true

    # The end marker takes it back. THIS is what the old code had no way to do.
    BT.process!(model, ACP.UsageUpdate(1, 2, nothing, nothing, "task-notification"))
    @test s.autowake[] == false
    @test s.busy_active[] == false
    close(model)
end

@testset "a background task's pill tells the whole three-phase story" begin
    # The pill used to vanish the moment the task itself finished — which is
    # exactly when the interesting part starts, because the agent then auto-wakes
    # to say what happened and none of that was visible. Now the same slot
    # carries it through: running → finished, waiting for the agent → agent
    # reporting back → gone. Every transition is a real signal.
    model, cli = live_model()
    s = BT.shared(model)
    pill = BT.send!(model, BT.to_message(model, bg_task_call("task-P3")))
    push!(BT.chat_taskbar(model), pill)
    @test pill.phase isa BT.Executing
    @test BT.taskbar_activity(pill, time()) === nothing   # nothing to say yet

    # (1) The task's own deterministic finish. `work_done` is what the bar polls;
    # with no transcript path there is no done-signal, so drive the phase the way
    # the poll would once there is one.
    @test BT.work_done(pill) == false                     # no outputFile ⇒ not done
    pill.phase = BT.AwaitingReport(time())
    @test BT.taskbar_activity(pill, time()) == "finished — waiting for the agent"
    @test BT.in_taskbar(pill)                             # still on screen
    @test BT.isdone(pill) == false                        # ... and not retired

    # (2) The agent auto-wakes: un-prompted work on the main thread.
    @test s.autowake[] == false
    feed!(cli, amc("The background job finished. "))
    BT.flush_main!(model)
    @test s.autowake[] == true
    @test pill.phase isa BT.Reporting
    @test BT.taskbar_activity(pill, time()) == "agent reporting back"
    @test s.busy_active[] == true                         # spinner, bounded this time

    # (3) The episode's own end marker — an autonomous-origin usage_update.
    # `human` must NOT end it: that is the user's own turn.
    BT.process!(model, ACP.UsageUpdate(10, 100, nothing, nothing, "human"))
    @test s.autowake[] == true
    BT.process!(model, ACP.UsageUpdate(10, 100, nothing, nothing, "task-notification"))
    @test s.autowake[] == false
    @test pill.phase isa BT.Reported
    @test s.busy_active[] == false                        # and the spinner stops
    @test BT.isdone(pill) == true                         # the bar retires it next poll
    close(model)
end

@testset "an episode's todo list is finalized when the episode ends" begin
    # An auto-wake episode builds its own todo list, and there is no end_turn to
    # finish it. The old between-turn consumer finalized it at episode end; the
    # one-stream refactor deleted that consumer and lost the behaviour, so the
    # card sat in the bar frozen at whatever it reached until some LATER turn
    # happened to end (observed live: `Todos 0/2` still pinned long after).
    model, cli = live_model()
    s = BT.shared(model)
    feed!(cli, amc("Picking up where the background job left off. "))
    feed!(cli, planupd([("step a", "in_progress"), ("step b", "pending")]))
    BT.flush_main!(model)

    @test s.autowake[] == true
    t = s.live_todo[]
    @test t isa BT.TodoListMsg
    @test BT.in_taskbar(t)                 # live while the episode runs
    @test t.finished_at === nothing

    # The episode's own end marker finalizes it, exactly as a turn's end would.
    BT.process!(model, ACP.UsageUpdate(1, 2, nothing, nothing, "task-notification"))
    @test s.autowake[] == false
    @test s.live_todo[] === nothing
    @test !BT.in_taskbar(t)
    @test t.finished_at !== nothing         # ... into history, not left hanging
    close(model)
end

@testset "an orphan-swept todo card leaves the bar, it is not stranded" begin
    # The sweep (a cancelled turn, an error, a restart) used to stamp
    # `finished_at` and walk away. That makes the card un-live while it is still
    # PINNED, so the next todo update builds a fresh list and reassigns
    # `live_todo` — and the old card is then owned by nobody: `finish_live_todo!`
    # only finalizes `live_todo`, and `isdone` cannot fire on entries that were
    # never completed. It sat in the bar forever showing e.g. 0/2.
    model, cli = live_model()
    s = BT.shared(model)
    feed!(cli, planupd([("step a", "in_progress"), ("step b", "pending")]))
    BT.flush_main!(model)
    old = s.live_todo[]
    @test old isa BT.TodoListMsg
    @test BT.in_taskbar(old)

    BT.finalize_orphan!(old)
    @test old.finished_at !== nothing
    @test !BT.in_taskbar(old)              # the bit that was missing
    @test BT.is_live(old) == false
    @test s.live_todo[] === nothing        # and it gave up ownership

    # The agent moves on with a brand new list: the old card is not still there.
    feed!(cli, planupd([("step c", "in_progress")]))
    BT.flush_main!(model)
    fresh = s.live_todo[]
    @test fresh isa BT.TodoListMsg && fresh !== old
    @test BT.in_taskbar(fresh)
    @test !any(t -> t === old, BT.chat_taskbar(model).items[])
    close(model)
end

@testset "the task bar admits background work, and nothing else" begin
    # Membership is a FACT about the tool — `run_in_background`, or a todo list —
    # never a judgement about how long it has been running. The old policy
    # admitted any tool still alive after 3 seconds, which put a slow foreground
    # `Read` in the bar (seen live at 98 minutes) and cost the bar its meaning.
    model, _ = live_model()
    mk(call) = BT.to_message(model, call)

    fg_bash = mk(ACP.BashCall("b1", "execute", "grep -r foo", "in_progress",
        ACP.ToolContent[], Channel{ACP.ToolCall}(4), "grep -r foo", false, nothing))
    bg_bash = mk(ACP.BashCall("b2", "execute", "sleep 600", "in_progress",
        ACP.ToolContent[], Channel{ACP.ToolCall}(4), "sleep 600", true, nothing))
    fg_task = mk(ACP.TaskCall("t1", "other", "Investigate", "in_progress",
        ACP.ToolContent[], Channel{ACP.ToolCall}(4), "Investigate", "go", false, nothing, ""))
    bg_task = mk(bg_task_call("t2"))
    reader  = mk(ACP.GenericTool("r1", "read", "Read /a/very/big/file.jl",
        "in_progress", ACP.ToolContent[], Channel{ACP.ToolCall}(4),
        "Read", Dict{String,Any}()))

    @test BT.is_taskbar_item(bg_bash) == true    # detached work: yes
    @test BT.is_taskbar_item(bg_task) == true
    @test BT.is_taskbar_item(fg_bash) == false   # same tool, foreground: no
    @test BT.is_taskbar_item(fg_task) == false
    @test BT.is_taskbar_item(reader)  == false   # slow or not, a Read is not background

    # `pin_tool!` is the only door, and it asks exactly that question.
    for m in (fg_bash, fg_task, reader)
        BT.pin_tool!(model, m)
        @test !BT.in_taskbar(m)
    end
    close(model)
end

@testset "a finished task nobody mentions gives its slot back" begin
    # The three-phase pill introduced a latch of its own: a task that finished
    # while the agent had nothing to say about it, on a chat that then goes idle,
    # waited on an event that never came — the slot sat there indefinitely
    # (observed live at 98 minutes). `REPORT_WAIT_SECONDS` bounds the WAIT; it
    # has no say in whether the work is done.
    model, cli = live_model()
    pill = BT.send!(model, BT.to_message(model, bg_task_call("task-QUIET")))
    push!(BT.chat_taskbar(model), pill)

    # Its work finished a moment ago: still waiting, still on screen.
    pill.phase = BT.AwaitingReport(time())
    @test BT.isdone(pill) == false
    @test BT.taskbar_activity(pill, time()) == "finished — waiting for the agent"

    # Past the window with nobody having mentioned it: retire.
    pill.phase = BT.AwaitingReport(time() - BT.REPORT_WAIT_SECONDS - 1)
    @test BT.isdone(pill) == true
    @test pill.phase isa BT.Reported

    # A task that IS being reported on is NOT on that clock — the episode's own
    # end marker governs it, however long the agent talks.
    pill2 = BT.send!(model, BT.to_message(model, bg_task_call("task-TALKING")))
    push!(BT.chat_taskbar(model), pill2)
    pill2.phase = BT.Reporting(time() - 10 * BT.REPORT_WAIT_SECONDS)
    @test BT.isdone(pill2) == false
    close(model)
end

@testset "an episode with no end marker is closed by the next turn" begin
    # A provider that never tags an autonomous result would otherwise leave the
    # episode — and the pill, and the spinner — open forever. The turn boundary
    # is a signal the agent cannot omit.
    model, cli = live_model()
    s = BT.shared(model)
    pill = BT.send!(model, BT.to_message(model, bg_task_call("task-NOEND")))
    push!(BT.chat_taskbar(model), pill)
    pill.phase = BT.AwaitingReport(time())

    feed!(cli, amc("reporting with no end marker"))
    BT.flush_main!(model)
    @test s.autowake[] == true
    @test pill.phase isa BT.Reporting

    BT.end_autowake!(model)          # what `begin_turn!` calls at the boundary
    @test s.autowake[] == false
    @test pill.phase isa BT.Reported
    @test s.busy_active[] == false
    close(model)
end

@testset "a flush waits for the render, it does not just seal" begin
    # The barrier end-of-turn cleanup depends on: after `flush_main!` returns,
    # everything ahead of the marker is IN the store — so empty-turn detection,
    # Yolo's "what did it reply", and the orphan sweep all read a settled state.
    model, cli = live_model()
    for i in 1:50
        feed!(cli, amc("chunk $i "))
        feed!(cli, toolnotif("t$i", "tool $i"))
    end
    BT.flush_main!(model)
    store = BT.shared(model).msgs_store
    @test count(m -> m isa BT.ToolMsg, store) == 50
    @test count(m -> m isa BT.AgentMsg, store) == 50
    close(model)
end

end
