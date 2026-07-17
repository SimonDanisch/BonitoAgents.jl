@testitem "unit:todo_carryover" tags = [:unit] begin

# Claude keeps ONE cumulative todo list per session: every `plan` update
# re-sends the full list, crossed-off items included, forever (verified on
# real acp.jsonl logs — a session's list only ever grows). Left unfiltered,
# each NEW task's list opened pre-filled with the whole session's finished
# history. `process_todo!` therefore strips finished carry-over when a fresh
# list starts (entries completed now AND completed in the most recent
# finalized bubble), remembers them in `TodoListMsg.hidden` so the absorb
# path keeps stripping, and un-hides an item that resurfaces as open work.
# A resend that strips to nothing never creates a list (subsumes the old
# exact-equality "all-done resend" dedup, including the dropped-leftover
# case where equality wouldn't fire).

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

entries(items) = [ACP.PlanEntry(c, "medium", st) for (c, st) in items]
todos(model)   = BT.shared(model).live_todo[]
bubbles(model) = filter(m -> m isa BT.TodoListMsg, BT.shared(model).msgs_store)
contents(t)    = [(e.content, e.status) for e in t.entries]

# The TaskBar's own 1 Hz loop finalizes an all-done list — poll for it like
# the app does instead of finalizing by hand.
function waitfor(f; timeout = 6.0)
    deadline = time() + timeout
    while time() < deadline
        f() && return true
        sleep(0.05)
    end
    return f()
end

@testset "fresh list strips finished carry-over from the previous bubble" begin
    model = headless_model()

    # Task A: two items, worked to completion (absorbed in place).
    BT.process_todo!(model, entries([("a1", "in_progress"), ("a2", "pending")]))
    t = todos(model)
    @test t isa BT.TodoListMsg
    @test contents(t) == [("a1", "in_progress"), ("a2", "pending")]
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "in_progress")]))
    @test contents(t) == [("a1", "completed"), ("a2", "in_progress")]
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "completed")]))
    # All done → the bar loop finalizes into ONE history bubble.
    @test waitfor(() -> todos(model) === nothing)
    @test length(bubbles(model)) == 1

    # Claude re-sends the final all-done list — no new card, no new bubble;
    # same when it dropped a leftover so exact equality wouldn't fire.
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "completed")]))
    @test todos(model) === nothing
    BT.process_todo!(model, entries([("a1", "completed")]))
    @test todos(model) === nothing
    @test length(bubbles(model)) == 1

    # Task B starts: claude's cumulative list re-sends a1/a2 crossed off.
    # The fresh card shows ONLY the new work.
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "completed"),
                                     ("b1", "in_progress"), ("b2", "pending")]))
    t = todos(model)
    @test t isa BT.TodoListMsg
    @test contents(t) == [("b1", "in_progress"), ("b2", "pending")]
    @test t.hidden == Set(["a1", "a2"])

    # Absorb keeps stripping across updates (the carry-over is in EVERY one).
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "completed"),
                                     ("b1", "completed"), ("b2", "in_progress")]))
    @test contents(t) == [("b1", "completed"), ("b2", "in_progress")]

    # A hidden item genuinely REOPENED resurfaces — and its later completion
    # shows (it is this task's progress now).
    BT.process_todo!(model, entries([("a1", "in_progress"), ("a2", "completed"),
                                     ("b1", "completed"), ("b2", "completed")]))
    @test contents(t) == [("a1", "in_progress"), ("b1", "completed"),
                          ("b2", "completed")]
    @test t.hidden == Set(["a2"])
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "completed"),
                                     ("b1", "completed"), ("b2", "completed")]))
    @test contents(t) == [("a1", "completed"), ("b1", "completed"),
                          ("b2", "completed")]
    # All done again → finalizes; the task-B bubble holds only its own story.
    @test waitfor(() -> todos(model) === nothing)
    bs = bubbles(model)
    @test length(bs) == 2
    @test contents(bs[end]) == [("a1", "completed"), ("b1", "completed"),
                                ("b2", "completed")]

    # Task C: the cumulative wire list STILL carries every a- and b-item.
    # Bubble B is stripped to its own story (no a2), so a one-bubble-back
    # lookup would let a2 leak back in here — the strip scope must be the
    # union over ALL finalized bubbles.
    BT.process_todo!(model, entries([("a1", "completed"), ("a2", "completed"),
                                     ("b1", "completed"), ("b2", "completed"),
                                     ("c1", "in_progress")]))
    t = todos(model)
    @test contents(t) == [("c1", "in_progress")]
    @test t.hidden == Set(["a1", "a2", "b1", "b2"])
end

@testset "plan_entries_compatible: replay matching tolerates strip + status loss" begin
    pe(items) = entries(items)
    # Stored bubble stripped of carry-over still matches claude's full
    # cumulative replay (ordered content subsequence, statuses ignored).
    @test BT.plan_entries_compatible(
        pe([("b1", "completed"), ("b2", "completed")]),
        pe([("a1", "completed"), ("a2", "completed"),
            ("b1", "completed"), ("b2", "completed")]))
    # chat.md round-trip maps in_progress → pending: statuses must not matter.
    @test BT.plan_entries_compatible(
        pe([("x", "pending")]), pe([("x", "in_progress")]))
    # Identity still matches; disjoint and out-of-order do not.
    @test BT.plan_entries_compatible(pe([("x", "completed")]), pe([("x", "completed")]))
    @test !BT.plan_entries_compatible(pe([("x", "completed")]), pe([("y", "completed")]))
    @test !BT.plan_entries_compatible(
        pe([("b", "pending"), ("a", "pending")]),
        pe([("a", "pending"), ("b", "pending")]))
end

end
