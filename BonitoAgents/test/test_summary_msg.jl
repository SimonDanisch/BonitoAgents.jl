# `/compact` session summaries are NOT user messages. They land as a separate
# centered separator (`SummaryMsg`) on every entry path: live ACP `to_message`,
# replay reconcile, `chat.md` reload. claude-agent-acp drops Claude Code's
# `isCompactSummary` flag over ACP, so we route on the verbatim opening text.
using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

@testset "summary message routing + round-trip" begin
    # Detection prefix matches the verbatim Claude Code text.
    @test BT.is_summary_text(BT.SUMMARY_PREFIX * " The summary below…") == true
    @test BT.is_summary_text("Hi, can you help me?") == false

    # Live to_message routing: a UserMessage with the summary prefix becomes a
    # SummaryMsg (centered separator), not a UserMsg.
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir();
                          transport = BT.MockTransport((o, i) -> nothing))
    @test BT.to_message(model, ACP.UserMessage(BT.SUMMARY_PREFIX * " context.")) isa BT.SummaryMsg
    @test BT.to_message(model, ACP.UserMessage("real question?")) isa BT.UserMsg

    # Reconcile routing: an ACP.UserMessage carrying a summary lands as a
    # SummaryMsg in msgs_store; a normal user message stays a UserMsg.
    BT.reconcile_replay!(model, ACP.Message[
        ACP.UserMessage(BT.SUMMARY_PREFIX * " context."),
        ACP.UserMessage("real question?"),
    ])
    types = string.(nameof.(typeof.(model.msgs_store)))
    @test types == ["SummaryMsg", "UserMsg"]

    # chat.md round-trip: persistence + load_history reload as SummaryMsg.
    reloaded = BT.load_history(model.chat_session)
    @test reloaded[1] isa BT.SummaryMsg && BT.is_summary_text(reloaded[1].text)
    @test reloaded[2] isa BT.UserMsg

    # Wire shape for the browser: summary kind + cached html.
    d = BT.msg_to_dict(reloaded[1])
    @test d["type"] == "summary"
    @test !isempty(d["html"])
end
