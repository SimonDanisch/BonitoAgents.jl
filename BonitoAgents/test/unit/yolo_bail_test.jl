# The bail signal used to be inferred from the reply's leading word, which
# cannot work: "No, everything is done." must stop the loop and "no, here's
# more" must not, and both begin with `no`. Whichever way the rule went, one of
# them was wrong — and the implementation and yolo_mode_test.jl disagreed about
# which. The loop now asks for a SENTINEL the agent has to opt into emitting, so
# "am I finished" is a fact instead of a reading.
@testitem "unit:yolo_bail" tags = [:unit] begin
    B  = BonitoAgents.yolo_bail
    R  = BonitoAgents.yolo_stop_reason
    N  = BonitoAgents.yolo_norm
    S  = BonitoAgents.YOLO_DONE_SENTINEL
    MX = BonitoAgents.YOLO_MAX_STREAK

    @testset "the S ALONE stops the loop" begin
        # Whitespace and markdown decoration around it are fine — the agent may
        # bold it or quote it — but the line has to be the entire answer.
        for reply in (S, "  $S  ", "$S.", "**$S**", "> $S", "`$S`", "\n$S\n")
            @test B(reply)
        end
    end

    @testset "a reply that also says anything else keeps the loop running" begin
        # THE point of the rule. Stopping has to be a clean answer to "is there
        # more you could do", not something a work message carries along at the
        # end. An agent that writes up next steps and appends the S used
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
        @test !B("The S is $S, but I am still working.")
    end

    @testset "normalisation folds case and whitespace" begin
        @test N("  I'll   Continue\n now ") == N("i'll continue now")
        @test N("") == ""
    end

    # `yolo_stop_reason` is pure (reply, produced, streak, last) so the whole
    # rule is checkable here without standing up a chat.
    @testset "stop reasons" begin
        # Declared: stop, and SAY so. It was silent on the theory that the
        # agent's message already reads as "done" — but an agent that ends a
        # report of next steps with the S leaves the loop stopping for no
        # visible reason, which is what we hit in practice.
        #
        # `streak >= 1` because the S only counts as an ANSWER — see the
        # "only counts once we have asked" testset below.
        @test R(S, true, 1, "")               == "the agent signalled it was finished"
        @test R("working", false, 0, "")      != nothing      # produced nothing
        @test R("working", true, 0, "")       === nothing     # ordinary progress
        # Repeat = spinning.
        @test R("I'll continue.", true, 3, N("I'll continue.")) !== nothing
        @test occursin("repeated", R("I'll continue.", true, 3, N("i'll   continue.")))
        # A turn ending on a tool call has no reply; two in a row is normal work,
        # not a repeat, so an empty reply must never trip the repeat check.
        @test R("", true, 3, "") === nothing
        # Backstop: bounded even if every turn looks new.
        @test R("fresh text $(MX)", true, MX - 1, "") !== nothing
        @test occursin(string(MX), R("fresh", true, MX - 1, ""))
        @test R("fresh", true, MX - 2, "") === nothing
    end
# The sentinel is an ANSWER, never a way for the agent to end its own turn.
#
# Reported live: the agent finished a turn by writing `YOLO-COMPLETE` at the
# bottom of a report that still listed open work, and the loop stopped without
# ever having asked. The shape is always: turn ends → we ask → the keyword
# answers. `streak` is the count of questions asked, so 0 means nobody asked.
@testset "the sentinel only counts once we have asked" begin
    # Turn 0 — the one that STARTED the loop. Nothing has been asked, so the
    # agent cannot leave by writing the keyword itself.
    @test R(S, true, 0, "") === nothing
    @test R("all done here.\n\n$(S)", true, 0, "") === nothing
    # ...and ordinary progress keeps going, as before.
    @test R("did some work", true, 0, "") === nothing

    # Once we HAVE asked, the same reply ends it.
    @test R(S, true, 1, "") == "the agent signalled it was finished"
    @test R(S, true, 3, "") == "the agent signalled it was finished"

    # The other stops are about the loop's health, not about answering, so they
    # apply whether or not a question was asked.
    @test R("", false, 0, "") == "the turn ended without any output"
    @test R("same", true, 1, N("same")) == "the agent repeated itself — it looks stuck"
end

end
