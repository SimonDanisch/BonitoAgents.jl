# The bail signal used to be inferred from the reply's leading word, which
# cannot work: "No, everything is done." must stop the loop and "no, here's
# more" must not, and both begin with `no`. Whichever way the rule went, one of
# them was wrong — and the implementation and yolo_mode_test.jl disagreed about
# which. The loop now asks for a SENTINEL the agent has to opt into emitting, so
# "am I finished" is a fact instead of a reading.
#
# The sentinel alone was still not enough: agents write it to END A TURN rather
# than to claim the work is done (a live chat produced one mid-investigation of
# a bug it was actively debugging). So it now only ASKS to stop — the loop puts
# "are you really done?" back to the agent and ends on the answer to THAT.
@testitem "unit:yolo_bail" tags = [:unit] begin
    using BonitoAgents

    B  = BonitoAgents.yolo_bail
    N  = BonitoAgents.yolo_norm
    S  = BonitoAgents.YOLO_DONE_SENTINEL
    P  = BonitoAgents.yolo_repeating
    Y  = BonitoAgents.YoloState
    T  = BonitoAgents.YoloTurn
    D  = BonitoAgents.yolo_decide

    # One turn through the loop: decide, then fold the decision back into the
    # state exactly as `continue_yolo!` does, so a testset can drive several
    # turns in a row and watch the protocol move.
    function step!(y, reply; worked = false, produced = true,
                   errored = false, stop = "end_turn")
        t = T(reply, produced, worked, errored, stop)
        d = D(y, t)
        BonitoAgents.yolo_apply!(y, d, t)
        return d
    end

    @testset "the sentinel ALONE is the bail signal" begin
        # Whitespace and markdown decoration around it are fine — the agent may
        # bold it or quote it — but the line has to be the entire answer.
        for reply in (S, "  $S  ", "$S.", "**$S**", "> $S", "`$S`", "\n$S\n")
            @test B(reply)
        end
    end

    @testset "a reply that also says anything else is not the signal" begin
        # THE point of the rule. Stopping has to be a clean answer to "is there
        # more you could do", not something a work message carries along at the
        # end. An agent that writes up next steps and appends the sentinel used
        # to stop the loop — while its own message was the clearest evidence
        # there was more to do.
        for reply in ("Everything is green and pushed.\n\n$S",
                      "done\n$S\n",
                      "$S\n\nNext: wire up the dashboard.",
                      "## Next steps\n1. tests\n2. docs\n\n$S")
            @test !B(reply)
        end
    end

    @testset "prose never stops the loop on its own" begin
        # The two that made a leading-word rule impossible. Neither bails now,
        # because neither says so — and that is the point: the agent decides
        # explicitly rather than us guessing from phrasing.
        @test !B("No, everything is done.")
        @test !B("no, here's more")
        for reply in ("no", "No.", "**No**", "NO!", "Not quite — I'll keep going.",
                      "I still need to update the docs.", "yes", "")
            @test !B(reply)
        end
    end

    @testset "a mention is not a declaration" begin
        # Mid-sentence, or talked ABOUT, must not end the loop — otherwise the
        # agent explaining the protocol would silently stop it.
        @test !B("I will print $S when I am finished.")
        @test !B("The sentinel is $S, but I am still working.")
    end

    @testset "normalisation folds case and whitespace" begin
        @test N("  I'll   Continue\n now ") == N("i'll continue now")
        @test N("") == ""
    end

    # `yolo_decide` is pure (state, turn) → decision, so the whole protocol is
    # checkable here without standing up a chat.
    @testset "ordinary progress keeps the loop running" begin
        y = Y()
        d = step!(y, "did some work"; worked = true)
        @test d.action === :continue
        @test y.streak == 1 && y.phase === :work

        # There is NO turn limit. The loop runs until the agent says it is done;
        # a count is not evidence of anything, and stopping mid-job because we
        # counted to 25 defeats the point of running unattended.
        y.streak = 10_000
        @test step!(y, "still plenty to do"; worked = true).action === :continue
    end

    @testset "a turn with no output at all stops the loop" begin
        y = Y()
        d = step!(y, ""; produced = false)
        @test d.action === :stop
        @test d.reason == "the turn ended without any output"
        # Nothing was produced, so nothing is known about WHY — don't disarm on
        # a symptom that a restart usually clears.
        @test !d.disarm
        @test y.streak == 0 && y.phase === :work   # stopping resets everything
    end

    # The sentinel is a REQUEST to stop, never the stop itself, and never a way
    # to end your own turn.
    @testset "the sentinel only asks — the confirm answer decides" begin
        y = Y()
        # Turn 0 — the one that STARTED the loop. Nothing has been asked, so the
        # agent cannot leave by writing the keyword itself.
        @test step!(y, S).action === :continue
        @test y.phase === :work

        # Once we HAVE asked, the same reply asks the CONFIRM question. It does
        # not stop: this is the turn the agent used to escape from.
        d = step!(y, S)
        @test d.action === :confirm
        @test y.phase === :confirm

        # Answering the confirm question with the sentinel, and nothing else, is
        # the one thing that ends the loop — silently, since the agent's own
        # message already says it.
        d = step!(y, S)
        @test d.action === :stop
        @test d.reason == ""
        @test !d.disarm
        @test y.phase === :work && y.streak == 0
    end

    @testset "a work turn that ends with the sentinel still has to confirm" begin
        # The live report, exactly: the agent spent the turn debugging a bug,
        # then closed it with the sentinel alone and the loop stopped. Work in
        # the turn does not change what the sentinel is — a request, answered by
        # the confirm question.
        y = Y()
        step!(y, "measured three hypotheses"; worked = true)
        d = step!(y, S; worked = true)
        @test d.action === :confirm
        @test y.phase === :confirm
    end

    @testset "work in the confirm turn means NOT done, whatever it writes" begin
        # The whole point: "YOLO-COMPLETE" must not be a way out of work. An
        # agent that runs a tool in the confirm turn answered "no" by doing more,
        # so the loop carries on regardless of how the turn ends.
        y = Y()
        step!(y, "working")            # streak 1 → the sentinel now counts
        @test step!(y, S).action === :confirm
        @test step!(y, S; worked = true).action === :continue
        @test y.phase === :work        # back to ordinary auto-continue

        # Prose in the confirm turn is not an answer either — it keeps going.
        step!(y, "working again")
        @test step!(y, S).action === :confirm
        @test step!(y, "Yes, I believe I am done.").action === :continue
        @test y.phase === :work
    end

    # Going in circles is something to TELL the agent — until it is clear the
    # agent cannot work at all, which is a runaway loop.
    @testset "repeating is detected, and bounded" begin
        @test P("I'll continue.", N("I'll continue."))
        @test P("I'll continue.", N("i'll   continue."))   # normalised
        @test !P("something new", N("I'll continue."))
        # A turn ending on a tool call has no reply; two in a row is ordinary
        # work, so an empty reply must never count as repeating.
        @test !P("", "")
        @test !P("", N("I'll continue."))

        # First repeat: keep going, but say so in the next nudge.
        y = Y()
        step!(y, "I'll continue.")
        d = step!(y, "I'll continue.")
        @test d.action === :continue && d.repeated && d.repeats == 1

        # Third identical answer with no work in between — the live shape was a
        # provider answering every prompt with "You've hit your weekly limit".
        d = step!(y, "I'll continue.")
        @test d.action === :stop
        @test occursin("same answer 3 times", d.reason)
        @test d.disarm          # must not resume on the user's next message
    end

    @testset "work resets the repeat count" begin
        # An identical closing line between real turns of work is a writing
        # habit, not a spin — the guard is about an agent that cannot work.
        y = Y()
        for _ in 1:6
            d = step!(y, "Done with this step."; worked = true)
            @test d.action === :continue
            @test y.repeats == 0
        end
    end

    @testset "an agent that never runs a tool stops the loop" begin
        # The repeat guard only catches a provider that says the same thing
        # every time. Codex's rate-limit message carries a countdown, so each
        # copy is "new" text and only this guard sees it. Four tool-free turns in
        # a row, whatever they say, is the loop going nowhere.
        y = Y()
        for n in 1:(BonitoAgents.YOLO_IDLE_LIMIT - 1)
            d = step!(y, "Rate limited, try again in $(n) minutes")
            @test d.action === :continue
            @test y.idle == n
        end
        d = step!(y, "Rate limited, try again in 5 minutes")
        @test d.action === :stop
        @test occursin("without running a single tool", d.reason)
        @test d.disarm

        # One tool call is enough to clear it — the guard is about an agent that
        # does nothing, not about how chatty it is.
        y2 = Y()
        for _ in 1:20
            step!(y2, "still on it"; worked = true)
            @test y2.idle == 0
            step!(y2, "and some more prose")
            @test y2.idle == 1
        end
    end

    @testset "a correct confirm answer outranks the health guards" begin
        # An agent answering the confirm question has by definition run no tool
        # in that turn; the idle guard must not steal the quiet finish (and
        # report a worse reason for the same stop).
        y = Y()
        y.streak = 3
        y.idle = BonitoAgents.YOLO_IDLE_LIMIT - 1
        @test step!(y, S).action === :confirm      # idle now at the limit
        @test y.idle == BonitoAgents.YOLO_IDLE_LIMIT
        d = step!(y, S)
        @test d.action === :stop
        @test d.reason == "" && !d.disarm
    end

    @testset "a failed turn stops the loop and switches Yolo off" begin
        # Whatever broke — transport, credits, a model the account cannot use —
        # the next nudge hits the same wall. Leaving Yolo armed would walk the
        # user's next message straight back into the same loop.
        y = Y()
        step!(y, "working")
        d = step!(y, ""; produced = false, errored = true)
        @test d.action === :stop
        @test d.reason == "the turn failed"
        @test d.disarm
        @test y.streak == 0

        # An error outranks everything, including a reply that looks like a bail.
        y2 = Y()
        step!(y2, "working")
        @test step!(y2, S; errored = true).action === :stop
        @test step!(y2, S; errored = true).disarm
    end

    @testset "a refused turn stops the loop and switches Yolo off" begin
        y = Y()
        step!(y, "working")
        d = step!(y, "I can't help with that."; stop = "refusal")
        @test d.action === :stop
        @test d.reason == "the agent refused the turn"
        @test d.disarm
    end

    @testset "reset! clears every guard" begin
        y = Y()
        step!(y, "working")
        step!(y, S)
        @test y.phase === :confirm && y.streak == 2
        BonitoAgents.reset!(y)
        @test y.streak == 0 && y.last == "" && y.repeats == 0 && y.idle == 0 &&
              y.phase === :work
    end
end
