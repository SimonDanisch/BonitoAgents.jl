using Test
using DemoBriefing
using Bonito
using Observables
import BonitoMCP: Apps

# The whole point of the App interface: a full run with no server, no worker,
# no agent process and no tokens.
@testset "DemoBriefing offline run" begin
    ctx = DemoBriefing.replay_context()
    board, chat = Apps.run(Briefing(), ctx)

    @testset "one subagent per item" begin
        triage = [p for p in Apps.calls(ctx)
                  if p.first === :agent && startswith(p.second.label, "triage-")]
        @test length(triage) == length(board.items)
        @test allunique(c.second.label for c in triage)
        # Triage must ask for structured output; parsing prose is the failure
        # mode this schema exists to prevent.
        @test all(c -> c.second.schema === DemoBriefing.TRIAGE_SCHEMA, triage)
        @test all(c -> c.second.tools === :read_only, triage)
    end

    @testset "verdicts drive the order" begin
        ranks = [DemoBriefing.bucket_rank(board.verdicts[i.number]["bucket"])
                 for i in board.items]
        @test issorted(ranks)
        @test board.items[1].number == 4830   # act_now, and the older of the two
        @test last(board.items).number == 4788  # ignore
    end

    @testset "the app composed one chat" begin
        msgs = Apps.sent(chat)
        # note (progress) → live dashboard → note (summary)
        @test length(msgs) == 3
        @test msgs[1] isa Apps.Note && occursin("Triaging 6", msgs[1].markdown)
        @test msgs[3] isa Apps.Note && occursin("2 act now", msgs[3].markdown)

        # The dashboard goes over as a live value, pinned, not as code.
        eval_msg = only(filter(m -> m isa Apps.BtJuliaEval, msgs))
        @test eval_msg.pin
        @test eval_msg.value isa Bonito.App

        @test Apps.state(ctx)["last_run_count"] == length(board.items)
    end

    # The agent never sees these messages otherwise: they are injected into the
    # store server-side and never pass through the ACP session.
    @testset "every message tells the agent something" begin
        sends = [p.second for p in Apps.calls(ctx) if p.first === :send]
        @test all(s -> s.to_agent isa String && !isempty(s.to_agent), sends)

        # A Note defaults to its own markdown; the board needs app-authored text
        # because there is no useful generic summary of a Bonito.App.
        note_send = first(sends)
        @test note_send.to_agent == note_send.msg.markdown
        eval_send = only(filter(s -> s.msg isa Apps.BtJuliaEval, sends))
        @test occursin("2 act now", eval_send.to_agent)

        # Trust boundary: this text lands in a user turn, so it must be the
        # app's own words, not a paste of attacker-controlled issue content.
        titles = [i.title for i in board.items]
        @test !any(t -> occursin(t, eval_send.to_agent), titles)
    end
end

# The interactions the dashboard's buttons drive. Calling the handlers'
# underlying verbs directly keeps this a unit test; the browser path is
# covered by the e2e suite.
@testset "draft fills the field" begin
    ctx = DemoBriefing.replay_context()
    board, chat = Apps.run(Briefing(), ctx)
    item = first(board.items)

    @test board.drafts[item.number][] == ""
    board.drafts[item.number][] =
        Apps.agent(ctx, DemoBriefing.draft_prompt(item); label = "draft-#$(item.number)")
    @test occursin("tick-placement", board.drafts[item.number][])
end

@testset "work-on-it opens a chat for the item" begin
    ctx = DemoBriefing.replay_context()
    board, chat = Apps.run(Briefing(), ctx)
    pr = only(filter(i -> i.is_pr && i.number == 4822, board.items))
    Apps.open_chat(ctx; title = "pr", github = DemoBriefing.url(pr))
    opened = [p.second for p in Apps.calls(ctx) if p.first === :open_chat]
    @test length(opened) == 2                    # the briefing, then this one
    @test last(opened).github == "https://github.com/MakieOrg/Makie.jl/pull/4822"
end

# A ReplayContext must never let an unscripted path pass silently. Assert on the
# message, not the type: the throw happens inside `map_agents`, so `asyncmap`
# hands it back wrapped in a CapturedException.
@testset "unscripted agent call throws" begin
    ctx = Apps.ReplayContext(; config = (; repos = "a/b"))
    err = try
        Apps.run(Briefing(), ctx)
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("no canned reply for agent label", sprint(showerror, err))
end
