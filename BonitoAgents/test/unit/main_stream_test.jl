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
# which IS the connection's `main_stream`. What's under test here
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
# The agent runs turns of its own, as Claude does.
function live_model()
    state = BT.serve(; host = "127.0.0.1", port = 0,
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    model = BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
    conn  = ACP.Connection(IdleTransport(), ACP.DiscardHandler(); agent_turns = true)
    cli   = ACP.Client(conn, "sess", "/p")
    agent.client = cli
    BT.start_main_consumer!(model, cli)
    return model, cli
end

# The same chat with a renderer that is ALIVE but never drains `cli.messages`.
# `start_main_consumer!` is deliberately NOT called, so nothing else is reading
# the stream either — a marker put on it can only come back if someone bounds
# the wait. Returns the gate that releases the fake renderer.
function stalled_model()
    state = BT.serve(; host = "127.0.0.1", port = 0,
                     state_dir = mktempdir(), working_dir = mktempdir())
    agent = BT.WorkerAgent(state, "w1", "/p")
    model = BT.ChatModel(state, mktempdir(); project_id = "proj", agent = agent)
    conn  = ACP.Connection(IdleTransport(), ACP.DiscardHandler())
    cli   = ACP.Client(conn, "sess", "/p")
    agent.client = cli
    gate  = Threads.Event()
    task  = Base.errormonitor(@async (wait(gate); nothing))
    lock(BT.shared(model).lock) do
        BT.shared(model).main_consumer[] = (; task, client = cli)
    end
    return model, cli, gate
end

# Put an update on the main stream exactly as the dispatcher does: the same
# function, which also opens and ends the agent's own turns. A harness that put
# straight on the stream would be testing a code path production does not have.
feed!(cli, u) = ACP.main_thread!(cli.conn, u)

# The result of a cycle the agent ran on its own (`kind = "task-notification"`),
# or of the user's turn (`"human"`).
result_usage(origin) = ACP.UsageUpdateNotif(1, 2, nothing, nothing, origin)

# The agent answers prompt `id` of ours, as a response frame on the wire.
answer!(cli, id, stop = "end_turn") = ACP.dispatch_message(cli.conn,
    Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "result" => Dict("stopReason" => stop)))

amc(s) = ACP.AgentMessageChunk(ACP.TextContent(s))
toolnotif(id, title) = ACP.ToolCallNotif(id, title, "execute", "completed",
    [], ACP.ToolCallLocation[], "Bash", Dict{String,Any}(), Dict{String,Any}())
planupd(items) = ACP.PlanUpdate([ACP.PlanEntry(c, "medium", st) for (c, st) in items])
bg_task_call(id) = ACP.TaskCall(id, "other", "Run tests", "in_progress",
    ACP.ToolContent[], ACP.MessageStream{ACP.ToolCall}(),
    "Run the suite", "go", true, nothing, "")   # run_in_background = true, no outputFile

@testset "session EOF interrupts background tasks without a completion marker" begin
    model, cli = live_model()
    pill = BT.send!(model, BT.to_message(model, bg_task_call("interrupted-bg")))
    push!(BT.chat_taskbar(model), pill)
    @test BT.in_taskbar(pill)
    @test !BT.work_done(pill)
    shell = BT.send!(model, BT.to_message(model,
        ACP.BashCall("interrupted-shell", "execute", "sleep 600", "in_progress",
            ACP.ToolContent[], ACP.MessageStream{ACP.ToolCall}(), "sleep 600", true, nothing)))
    push!(BT.chat_taskbar(model), shell)
    done = BT.send!(model, BT.to_message(model, bg_task_call("already-finished")))
    done.phase = BT.AwaitingReport(time())
    push!(BT.chat_taskbar(model), done)
    close(cli)
    consumer = BT.shared(model).main_consumer[].task
    @test timedwait(() -> istaskdone(consumer), 10.0) === :ok
    wait(consumer)
    @test !BT.in_taskbar(pill)
    @test BT.tool_status(pill) == "failed"
    @test occursin("Interrupted", BT.tool_summary(pill))
    @test BT.tool_status(shell) == "failed"
    @test occursin("Interrupted", BT.tool_summary(shell))
    @test BT.tool_status(done) == "completed"
    @test isempty(BT.chat_taskbar(model).items[])
    close(model)
end

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

@testset "an un-prompted plan is finalized when its stream ends" begin
    model, cli = live_model()
    feed!(cli, amc("Working on it. "))
    feed!(cli, toolnotif("t1", "read file"))
    feed!(cli, planupd([("step a", "completed"), ("step b", "in_progress")]))
    feed!(cli, amc("Now the second part."))
    BT.flush_main!(model)          # a BOUNDARY: the plan must SURVIVE it, like a
    @test BT.shared(model).live_todo[] !== nothing   # long-running tool does

    # Now the stream ENDS. That is what a dead worker looks like from here: no
    # frame announces it, nobody calls a finalize verb. ACP seals the plan in
    # `close_turn!` and the renderer acts on the sealed `Plan` like any other
    # message — which is the whole point of moving this out of our turn edges.
    close(cli)
    cons = lock(() -> BT.shared(model).main_consumer[].task, BT.shared(model).lock)
    @test timedwait(() -> istaskdone(cons), 10.0) === :ok

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

@testset "the busy indicator follows the agent's own turn, and the turn ENDS" begin
    # `busy_active` is derived from the turns, so nothing can leave it on.
    model, cli = live_model()
    s = BT.shared(model)
    @test s.busy_active[] == false

    # A whole turn of the agent's own: prose, a tool, more prose.
    feed!(cli, amc("The background job finished. "))
    feed!(cli, toolnotif("t1", "read the log"))
    feed!(cli, amc("All green."))
    BT.flush_main!(model)

    # It rendered — the work is visible, which is the point...
    @test length(BT.shared(model).msgs_store) == 3
    @test s.turn_in_flight[] == false     # with no prompt of ours open
    # ... and the chat says so.
    @test only(ACP.open_turns(model)) isa ACP.AgentTurn
    @test s.busy_active[] == true

    # The agent's own end-of-cycle result ends it: ACP ends the turn there.
    feed!(cli, result_usage("task-notification"))
    @test isempty(ACP.open_turns(model))
    @test timedwait(() -> !s.busy_active[], 5.0) === :ok
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

    # (2) The agent starts a turn of its own: work with no prompt of ours open.
    @test isempty(ACP.open_turns(model))
    feed!(cli, amc("The background job finished. "))
    BT.flush_main!(model)
    own = only(ACP.open_turns(model))
    @test own isa ACP.AgentTurn
    @test pill.phase isa BT.Reporting
    @test BT.taskbar_activity(pill, time()) == "agent reporting back"
    @test s.busy_active[] == true                         # spinner, bounded this time

    # (3) Its result, tagged with an autonomous origin, ends it. `human` must NOT
    # end it: that is the user's own turn.
    feed!(cli, result_usage("human"))
    @test !ACP.isover(own)
    feed!(cli, result_usage("task-notification"))
    @test ACP.isover(own)
    @test timedwait(() -> pill.phase isa BT.Reported, 5.0) === :ok
    @test timedwait(() -> !s.busy_active[], 5.0) === :ok  # and the spinner stops
    @test BT.isdone(pill) == true                         # the bar retires it next poll
    close(model)
end

@testset "a todo list of the agent's own turn is finalized when the turn ends" begin
    # No end_turn of ours finishes the agent's own list: its turn's end must.
    model, cli = live_model()
    s = BT.shared(model)
    feed!(cli, amc("Picking up where the background job left off. "))
    feed!(cli, planupd([("step a", "in_progress"), ("step b", "pending")]))
    BT.flush_main!(model)

    @test only(ACP.open_turns(model)) isa ACP.AgentTurn
    t = s.live_todo[]
    @test t isa BT.TodoListMsg
    @test BT.in_taskbar(t)                 # live while the turn runs
    @test t.finished_at === nothing

    # The turn's end marker ends it — and the list goes with the turn. Nothing
    # pushes that: `isdone` asks whether a turn is open, and the bar acts.
    feed!(cli, result_usage("task-notification"))
    @test isempty(ACP.open_turns(model))
    @test BT.isdone(t) == true                                # the decision...
    @test timedwait(() -> !BT.in_taskbar(t), 5.0) === :ok     # ...and the bar acts
    @test s.live_todo[] === nothing
    @test t.finished_at !== nothing         # ... into history, not left hanging
    close(model)
end

@testset "a live list is NOT retired while a turn is still in flight" begin
    # The other side of the same coin, and the risk in asking a status instead of
    # counting: get it wrong and a list gets retired out from under an agent that
    # is still working it. Under steering a prompt is open while an earlier
    # episode's list is live, and the list belongs to the work still running.
    model, cli = live_model()
    s = BT.shared(model)
    feed!(cli, planupd([("step a", "in_progress"), ("step b", "pending")]))
    BT.flush_main!(model)
    t = s.live_todo[]
    @test t isa BT.TodoListMsg
    @test BT.in_taskbar(t)

    ACP.prompt_request(cli.conn, Dict())     # a prompt opens and is never answered
    @test any(t -> t isa ACP.PromptTurn, ACP.open_turns(model))
    @test BT.isdone(t) == false
    sleep(1.5)                               # let the bar poll at least once
    @test BT.in_taskbar(t)                   # ... and leave it alone
    @test s.live_todo[] === t
    close(model)
end

@testset "a sealed todo card leaves the bar, it is not stranded" begin
    # Sealing used to stamp `finished_at` and walk away. That makes the card
    # un-live while it is still PINNED, so the next todo update builds a fresh
    # list and reassigns `live_todo` — and the old card is then owned by nobody:
    # this path only finalizes `live_todo`, and `isdone` cannot fire on entries
    # that were never completed. It sat in the bar forever showing e.g. 0/2.
    model, cli = live_model()
    s = BT.shared(model)
    feed!(cli, planupd([("step a", "in_progress"), ("step b", "pending")]))
    BT.flush_main!(model)
    old = s.live_todo[]
    @test old isa BT.TodoListMsg
    @test BT.in_taskbar(old)

    # The verb the sealed `Plan` drives. (There is no orphan-sweep arm for todos
    # any more — the sweep inferred death from "still has open entries", which is
    # the guess this whole rebuild removed.)
    BT.seal_live_todo!(model)
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
        ACP.ToolContent[], ACP.MessageStream{ACP.ToolCall}(), "grep -r foo", false, nothing))
    bg_bash = mk(ACP.BashCall("b2", "execute", "sleep 600", "in_progress",
        ACP.ToolContent[], ACP.MessageStream{ACP.ToolCall}(), "sleep 600", true, nothing))
    fg_task = mk(ACP.TaskCall("t1", "other", "Investigate", "in_progress",
        ACP.ToolContent[], ACP.MessageStream{ACP.ToolCall}(), "Investigate", "go", false, nothing, ""))
    bg_task = mk(bg_task_call("t2"))
    reader  = mk(ACP.GenericTool("r1", "read", "Read /a/very/big/file.jl",
        "in_progress", ACP.ToolContent[], ACP.MessageStream{ACP.ToolCall}(),
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

    # A task that IS being reported on is NOT on that clock — the agent's turn
    # governs it, however long the agent talks.
    pill2 = BT.send!(model, BT.to_message(model, bg_task_call("task-TALKING")))
    push!(BT.chat_taskbar(model), pill2)
    pill2.phase = BT.Reporting(time() - 10 * BT.REPORT_WAIT_SECONDS)
    @test BT.isdone(pill2) == false
    close(model)
end

@testset "the agent's own turn is over at the answer to our next prompt" begin
    # The agent runs one model turn at a time, so it answers a prompt of ours
    # only once a turn of its own is done: the answer ends that turn too, end
    # marker or not. A CANCELLED answer does not (a prompt still queued behind
    # the turn is answered `cancelled` at once).
    model, cli = live_model()
    s = BT.shared(model)
    pill = BT.send!(model, BT.to_message(model, bg_task_call("task-NOEND")))
    push!(BT.chat_taskbar(model), pill)
    pill.phase = BT.AwaitingReport(time())

    feed!(cli, amc("reporting, with no end marker coming"))
    BT.flush_main!(model)
    own = only(ACP.open_turns(model))
    @test pill.phase isa BT.Reporting

    queued = ACP.prompt_request(cli.conn, Dict())
    answer!(cli, queued.id, "cancelled")
    @test ACP.isover(queued) && !ACP.isover(own)

    p = ACP.prompt_request(cli.conn, Dict())
    answer!(cli, p.id)
    @test ACP.isover(p) && ACP.isover(own)
    @test timedwait(() -> pill.phase isa BT.Reported, 5.0) === :ok
    @test timedwait(() -> !s.busy_active[], 5.0) === :ok
    close(model)
end

@testset "a tool the agent never resolves is finished by the stream, not a sweep" begin
    # The one thing the deleted end-of-turn orphan sweep DID do: force-fail a tool
    # left non-terminal. If nothing does that now, an unresolved tool card pulses
    # forever — the exact bug shape this whole rebuild removed, one type over.
    # ACP owns it: `close_turn!` force-fails every live tool when the stream ends.
    model, cli = live_model()
    live = ACP.ToolCallNotif("t-live", "grep something", "search", "in_progress",
        ACP.ToolContent[], ACP.ToolCallLocation[], "Grep",
        Dict{String,Any}(), Dict{String,Any}())
    feed!(cli, live)
    tool = nothing
    @test timedwait(5.0) do
        tool = lock(() -> findfirst(m -> m isa BT.ToolMsg,
                                    BT.shared(model).msgs_store), BT.shared(model).lock)
        tool !== nothing
    end === :ok
    b = lock(() -> BT.shared(model).msgs_store[tool], BT.shared(model).lock)
    @test BT.tool_status(b) == "in_progress"      # live, and nothing has ended it

    # The stream ends — a worker dying, a session closing, a cancel. ACP flips the
    # tool terminal and closes its channel, which is what lets the renderer's
    # `for snap in m.stream` return and run its `finally`.
    close(cli)
    cons = lock(() -> BT.shared(model).main_consumer[].task, BT.shared(model).lock)
    @test timedwait(() -> istaskdone(cons), 10.0) === :ok
    @test BT.tool_status(b) == "failed"           # ...not left pulsing
    @test BT.is_live(b) == false                  # the card stops, timer frozen
    @test BT.tool_finished_at(b) !== nothing      # and it is stamped, so it persists
    close(model)
end

@testset "a flush waits for the render, it does not just seal" begin
    # The barrier end-of-turn cleanup depends on: after `flush_main!` returns,
    # everything ahead of the marker is IN the store — so empty-turn detection
    # and Yolo's "what did it reply" read a settled state.
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

# `begin_turn` waits on this barrier before it does ANYTHING else, and the chat
# has ONE serial `run_chat!` consumer. So an unbounded wait here is not a slow
# turn — it is a chat that can never start another turn: every message queues
# behind it, the spinner never clears, and stop cannot reach an agent that isn't
# running. `bind` only covers a renderer that DIED; this covers one that is alive
# and not draining. Seen live as a 53-minute wedge over an idle agent.
@testset "the render barrier is bounded when the renderer stalls" begin
    model, cli, gate = stalled_model()
    marker = ACP.flush_main!(cli)
    @test marker !== nothing
    t0 = time()
    BT.wait_rendered!(model, marker)          # must return, not hang
    waited = time() - t0
    @test waited >= BT.RENDER_BARRIER_SECONDS
    @test waited < BT.RENDER_BARRIER_SECONDS + 5
    notify(gate)
    close(model)

    # …and a renderer that IS draining is not slowed down by the bound.
    healthy, hcli = live_model()
    t1 = time()
    BT.flush_main!(healthy)
    @test time() - t1 < 2.0
    close(healthy)
end

# A "when done" message waits only for prompts of ours, and the answer to one
# ends the agent's own turn: no turn of the agent's can hold the composer (a
# 53-minute wedge, observed live). Stop still pauses unsent text.
@testset "the agent's own turn holds the spinner, never the composer" begin
    model, cli = live_model()
    s = BT.shared(model)
    feed!(cli, amc("background task finished, here's the report"))
    BT.flush_main!(model)
    @test only(ACP.open_turns(model)) isa ACP.AgentTurn
    @test s.busy_active[] == true
    @test isempty(BT.prompts_ahead(model))    # nothing a "when done" message waits for

    # With no consumer in this unit harness, the submission stays in the
    # outbox. It must not appear in history before being handed to the agent.
    BT.send_message!(model, BT.UserMsg("is it actually still running?"))
    @test timedwait(() -> Base.n_avail(s.user_messages) == 1, 5.0) === :ok
    @test !any(m -> m isa BT.UserMsg, s.msgs_store)
    @test only(s.pending_sends).status == :waiting

    # Stop pauses unsent text.
    BT.handle_command!(model, nothing, BT.CancelCommand())
    @test only(s.pending_sends).status == :paused
    @test BT.next_submission(model) === nothing
    close(model)
end

# A message typed right after a stop must NOT be handed over mid-cancel.
#
# claude-agent-acp's `cancel` settles queued turns that have not started yet —
# "they have no in-flight SDK work to interrupt" — so a prompt arriving while it
# is interrupting is resolved on the spot WITHOUT RUNNING. Seen live: a Write was
# stopped, the correction was typed immediately, and it came back as an empty
# turn with the instruction silently dropped. The agent never saw it.
@testset "a prompt waits for a cancel to settle instead of being swallowed" begin
    model, cli = live_model()
    s = BT.shared(model)

    # A real turn, then a stop: the prompt waits until that turn is over.
    span = ACP.prompt_request(cli.conn, Dict())
    BT.handle_command!(model, nothing, BT.CancelCommand())
    @test s.cancelled_turns[] == [span]
    @test BT.cancelling(model)

    # begin_turn must not hand the prompt over yet.
    held = @async BT.await_cancel_settled!(model)
    sleep(0.5)
    @test !istaskdone(held)

    # The agent answers the cancelled turn → the wait releases.
    answer!(cli, span.id, "cancelled")
    @test timedwait(() -> istaskdone(held), 5.0) === :ok
    @test !BT.cancelling(model)

    # And with nothing cancelling, it is a straight no-op.
    t0 = time(); BT.await_cancel_settled!(model)
    @test time() - t0 < 0.5
    close(model)
end

# The other half: when the agent IS working, stop keeps its old teeth.
@testset "stop cancels live work and pauses the outbox" begin
    model, cli = live_model()
    s = BT.shared(model)
    # A real turn of the agent's own, opened the way the dispatcher opens it.
    feed!(cli, amc("still working on the background job"))
    BT.flush_main!(model)
    own = only(ACP.open_turns(model))
    @test s.busy_active[] == true
    BT.send_message!(model, BT.UserMsg("stop for real"))
    @test timedwait(() -> Base.n_avail(s.user_messages) == 1, 5.0) === :ok

    BT.handle_command!(model, nothing, BT.CancelCommand())
    # The cancel went out for the agent's turn, which is over when the agent
    # says so: its result, also after a cancel.
    @test s.cancelled_turns[] == [own]
    @test BT.cancelling(model)
    feed!(cli, result_usage("task-notification"))
    @test ACP.isover(own) && !BT.cancelling(model)
    @test only(s.pending_sends).status == :paused
    @test BT.next_submission(model) === nothing
    # ...and the session is NOT muted by any of it. Asserted on the STORE, not
    # on `cli.messages`: the renderer this harness starts drains that channel,
    # so its depth is 0 whether frames flow or not.
    feed!(cli, amc("the subagent is still going"))
    BT.flush_main!(model)
    @test any(m -> m isa BT.AgentMsg && occursin("still going", m.text), s.msgs_store)
    close(model)
end

end
