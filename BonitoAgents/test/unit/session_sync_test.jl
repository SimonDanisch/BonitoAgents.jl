# The reconcile planner: how a resumed session's replay merges into the stored
# history. Pure function (store snapshot × replay candidates × pending-send
# count → plan), so every ordering rule the chat depends on is pinned here:
#
#   • prefix fast-path: our history is a prefix of the replay → adopt the tail.
#   • suffix anchor: the replay diverges at the FRONT (claude compacted — it
#     now starts with a summary), but our LAST messages appear as a run inside
#     it → adopt only what follows that run. No duplicates, ever.
#   • pending sends: user bubbles the agent hasn't seen stay at the END; the
#     anchor never matches them and adopted messages land BEFORE them.
#   • full divergence: nothing anchors → :diverged (caller rebuilds from the
#     replay behind a backup + separator).
@testitem "unit:session_sync_planner" tags = [:unit] begin
    import BonitoAgents as BA
    import AgentClientProtocol as ACP

    u(t)  = BA.UserMsg(t)                     # stored user bubble
    a(t)  = BA.AgentMsg(string(BA.uuid4()), t) # stored agent bubble
    RU(t) = ACP.UserMessage(t)                 # replayed user turn
    RA(t) = ACP.AgentMessage(t)                # replayed agent turn

    @testset "empty store adopts everything" begin
        plan = BA.plan_reconcile(BA.ChatMsg[], [RU("hi"), RA("hello")], 0)
        @test plan.mode == :append
        @test length(plan.adopt) == 2
    end

    @testset "prefix fast-path adopts only the tail" begin
        existing = BA.ChatMsg[u("hi"), a("hello")]
        replay   = [RU("hi"), RA("hello"), RU("more"), RA("sure")]
        plan = BA.plan_reconcile(existing, replay, 0)
        @test plan.mode == :append
        @test [m.text for m in plan.adopt] == ["more", "sure"]
    end

    @testset "identical store and replay is a no-op" begin
        existing = BA.ChatMsg[u("hi"), a("hello")]
        plan = BA.plan_reconcile(existing, [RU("hi"), RA("hello")], 0)
        @test plan.mode == :noop
    end

    @testset "compaction: suffix anchor skips the summary, no duplicates" begin
        # Store: the full old conversation. Replay: claude compacted — it now
        # STARTS with a summary we never stored, then repeats our recent tail,
        # then continues with new turns. Prefix matching fails; the suffix
        # anchor (our last messages found as a run in the replay) must adopt
        # exactly the new turns.
        existing = BA.ChatMsg[u("old 1"), a("old reply 1"), u("recent"), a("recent reply")]
        replay = [RU("This session is being continued from a previous conversation. Summary: …"),
                  RU("recent"), RA("recent reply"),
                  RU("new question"), RA("new answer")]
        plan = BA.plan_reconcile(existing, replay, 0)
        @test plan.mode == :append
        @test [m.text for m in plan.adopt] == ["new question", "new answer"]
    end

    @testset "pending sends never anchor; adoption lands before them" begin
        # The last stored message is a FRESH user bubble the agent hasn't seen
        # (pending = 1). The anchor must come from the messages before it, and
        # the plan must say "insert before the pending tail".
        existing = BA.ChatMsg[u("hi"), a("hello"), u("my fresh unseen message")]
        replay   = [RU("hi"), RA("hello"), RU("outside turn"), RA("outside reply")]
        plan = BA.plan_reconcile(existing, replay, 1)
        @test plan.mode == :append
        @test [m.text for m in plan.adopt] == ["outside turn", "outside reply"]
        # splice position: after the known history, before the pending bubble.
        @test plan.insert_at == 2
    end

    @testset "pending-only store adopts everything in front" begin
        existing = BA.ChatMsg[u("typed into a stale chat")]
        replay   = [RU("hi"), RA("hello")]
        plan = BA.plan_reconcile(existing, replay, 1)
        @test plan.mode == :append
        @test length(plan.adopt) == 2
        @test plan.insert_at == 0
    end

    @testset "full divergence is flagged, never merged" begin
        existing = BA.ChatMsg[u("completely"), a("different"), u("history")]
        replay   = [RU("nothing"), RA("in common")]
        plan = BA.plan_reconcile(existing, replay, 0)
        @test plan.mode == :diverged
    end

    @testset "replay shorter than store (claude lost history) is not a merge" begin
        # Our store has MORE than the replay and the replay is a strict prefix
        # of it — claude knows less than we do (e.g. session forked). Nothing
        # to adopt; must not truncate or duplicate.
        existing = BA.ChatMsg[u("hi"), a("hello"), u("more"), a("sure")]
        plan = BA.plan_reconcile(existing, [RU("hi"), RA("hello")], 0)
        @test plan.mode == :noop
    end
end
