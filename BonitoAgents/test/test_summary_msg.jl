# `/compact` session summaries are NOT user messages. They land as a separate
# centered separator (`SummaryMsg`) on every entry path: live ACP `to_message`,
# replay reconcile, `chat.md` reload. claude-agent-acp drops Claude Code's
# `isCompactSummary` flag over ACP, so we route on the verbatim opening text.
#
# TestKit migration. The deleted `MockTransport` scaffolding is gone. The
# routing / `to_message` dispatch / persistence round-trip are all agent-free
# pure functions on a `ChatModel` — they stay DIRECT unit tests, with the only
# change being the fixture (`agent = BT.MockAgent([])`, an un-started no-op
# agent, replaces the deleted `transport = MockTransport(...)` kwarg). The one
# genuinely user-visible claim — that a summary renders as a CENTERED
# `.bt-summary-msg` separator (not a user/agent bubble) — is now a small TestKit
# DOM e2e driven by `BT.send!(model, SummaryMsg)` + `close` over the real stack.
using Test
using Markdown
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

@testset "summary message routing + round-trip" begin

    # ── Pure unit: routing, to_message dispatch, chat.md round-trip ──────────
    @testset "routing + to_message + persistence (pure)" begin
        # Detection prefix matches the verbatim Claude Code text.
        @test BT.is_summary_text(BT.SUMMARY_PREFIX * " The summary below…") == true
        @test BT.is_summary_text("Hi, can you help me?") == false

        # Live to_message routing: a UserMessage with the summary prefix becomes a
        # SummaryMsg (centered separator), not a UserMsg. A no-op MockAgent gives
        # the model a real `comm`/persistence without spawning anything.
        state = BT.ServerState(; state_dir = mktempdir(),
                                  working_dir = mktempdir(), worker_secret = "x")
        model = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
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

    # ── DOM e2e: the summary renders as a centered separator, not a bubble ────
    # Driven over the REAL stack (real dev_server + worker + ACP wire + Electron);
    # `BT.send!(chat, sm)` + `close(sm)` injects the summary the way the live
    # `to_message` path does, then we assert the `.bt-summary-msg` / `.bt-summary-body`
    # the JS renderer (`case 'summary'` / `onSummaryFinal`) builds.
    @testset "summary renders as a centered .bt-summary-msg (DOM)" begin
        s = TK.dev_server()
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
            TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
            chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

            sm = BT.SummaryMsg(chat, BT.SUMMARY_PREFIX * " The conversation was compacted.")
            BT.send!(chat, sm)   # pushes + emits the centered placeholder
            close(sm)            # finalizes: ships summary_final with rendered html

            @test TK.wait_for(s, "summary separator appears",
                "document.querySelectorAll('.bt-summary-msg').length >= 1"; timeout = 15) == true
            # The body got the rendered html (NOT empty) — and it is a summary
            # separator, never a user/agent bubble.
            @test TK.wait_for(s, "summary body carries html",
                "((document.querySelector('.bt-summary-body')||{}).innerHTML||'').length > 0"; timeout = 10) == true
            @test TK.eval_js(s,
                "document.querySelectorAll('.bt-summary-msg .bt-user-msg, .bt-summary-msg .bt-agent-msg').length") == 0

            errs = TK.eval_js(s, "window.__errs || []")
            @test isempty(errs)
        finally
            close(s)
        end
    end

end
