# After a Stop, what the chat would tell the agent on its own (a background run
# or task that ended) must not start a turn: the user just stopped it. Simon
# kept seeing "Background Julia runs finished …" arrive right after pressing
# Stop and the agent carry on. Such a note is held and goes out with the user's
# next message: shown before it, in the same prompt. `e2e:stop_holds_notes`
# drives the same through a real run and the Stop button.
@testitem "unit:stop_holds_notes" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    state = BT.serve(; host = "127.0.0.1", port = 0, state_dir = mktempdir(), working_dir = mktempdir())
    cwd = mktempdir()
    models = BT.ChatModel[]
    chat() = (m = BT.ChatModel(state, cwd; project_id = "held-notes",
                               agent = BT.WorkerAgent(state, "offline", "/project")); push!(models, m); m)
    auto(text) = (m = BT.UserMsg(text); m.auto = true; m)
    entries(m) = [e for e in m.pending_sends if e isa BT.PendingSend]
    try
        model = chat()
        # A note the chat queued just before the Stop is held too, not paused.
        BT.send_message!(model, auto("Background command \"tail\" finished."))
        BT.handle_command!(model, nothing, BT.CancelCommand())
        @test model.stopped[]
        @test only(entries(model)).status === :held

        @testset "a note after the Stop is held, not sent" begin
            BT.send_message!(model, auto("Background Julia run finished: r3 (proj on Desktop)"))
            @test [e.status for e in entries(model)] == [:held, :held]
            @test all(e -> e.detail == BT.HELD_DETAIL, entries(model))
            @test BT.next_submission(model) === nothing
            @test isempty(model.msgs_store)
            @test [i["status"] for i in BT.queue_event(model)["items"]] == ["held", "held"]
        end

        @testset "held notes and the stop survive the chat being reopened" begin
            fresh = chat()
            @test [e.status for e in entries(fresh)] == [:held, :held]
            @test fresh.stopped[]
        end

        @testset "the user's next message takes the notes along" begin
            fresh = chat()
            BT.send_message!(fresh, BT.UserMsg("carry on"))
            @test !fresh.stopped[]
            e = only(entries(fresh))
            @test e.status === :waiting
            @test e.bubble.text == "carry on" && !e.bubble.auto
            @test [r.text for r in e.riders] == ["Background command \"tail\" finished.",
                                                 "Background Julia run finished: r3 (proj on Desktop)"]
            @test all(r -> r.auto, e.riders)
            # One prompt: the notes, as they happened before it, then the message.
            @test e.message.text == "Background command \"tail\" finished.\n\n" *
                                    "Background Julia run finished: r3 (proj on Desktop)\n\ncarry on"
            # The queue shows what the user wrote.
            @test only(BT.queue_event(fresh)["items"])["text"] == "carry on"

            # Persisted with its riders.
            again = chat()
            e2 = only(entries(again))
            @test e2.bubble.text == "carry on" && length(e2.riders) == 2 && e2.message.text == e.message.text

            # Handed over: the notes enter the transcript before the message.
            BT.submission_sent!(fresh, e, nothing)
            @test [m.text for m in fresh.msgs_store] == [[r.text for r in e.riders]; "carry on"]
            @test [m.auto for m in fresh.msgs_store] == [true, true, false]

            # No longer stopped: the next note goes out on its own again.
            BT.send_message!(fresh, auto("Background Julia run finished: r4 (proj on Desktop)"))
            @test last(entries(fresh)).status === :waiting
        end

        @testset "a held note can be sent now or removed" begin
            m = BT.ChatModel(state, mktempdir(); project_id = "held-actions",
                             agent = BT.WorkerAgent(state, "offline", "/project"))
            push!(models, m)
            BT.handle_command!(m, nothing, BT.CancelCommand())
            BT.send_message!(m, auto("note one"))
            BT.send_message!(m, auto("note two"))
            one, two = entries(m)
            BT.handle_command!(m, nothing, BT.QueueActionCommand(one.id, "send"))
            @test one.status === :waiting
            BT.handle_command!(m, nothing, BT.QueueActionCommand(two.id, "remove"))
            @test entries(m) == [one]
        end
    finally
        foreach(close, models)
        close(state.srv)
    end
end
