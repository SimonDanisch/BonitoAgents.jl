# Messages submitted while a turn is in flight render immediately as "queued"
# bubbles rather than being silently buffered on the channel. When `run_turn!`
# picks them up, `promote_queued_user_bubble!` clears the flag FIFO so the
# DOM `bt-queued` class drops in order.
#
# TestKit migration. The deleted `MockTransport` is gone; the model fixture now
# binds a no-op `MockAgent([])` (un-started, never spawns) instead of the
# deleted `transport=` kwarg. The split follows the rule:
#   * The queued-flag bookkeeping (set on send-while-busy, FIFO promotion,
#     persisted-as-false) is pure `ChatModel` state — DIRECT unit tests.
#   * The user-visible part — a queued bubble actually wearing the `bt-queued`
#     class and FIFO promotion dropping it oldest-first in the DOM — is a TestKit
#     e2e over the REAL stack, driven server-side with `send!` + the live
#     `promote_queued_user_bubble!` (the documented way to drive non-stream
#     events). We inject the bubbles via `send!` rather than a real busy turn:
#     the real consumer drains the default mock agent's turn instantly, so a
#     "force busy then send_message!" approach races the consumer; `send!` of a
#     pre-marked bubble emits the same `wire_new(queued=true)` the busy path does
#     without enqueuing a turn, making the DOM assertion deterministic.
using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents

@testset "queued user messages" begin

    # ── Pure unit: queued flag + FIFO promotion + persist-as-false ───────────
    @testset "queued flag + FIFO promotion + persistence (pure)" begin
        state = BT.ServerState(; state_dir = mktempdir(),
                                  working_dir = mktempdir(), worker_secret = "x")
        model = BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))

        # Idle send: no turn in flight, bubble lands NOT queued.
        BT.send_message!(model, BT.UserMsg("hello"))
        @test length(model.msgs_store) == 1
        @test model.msgs_store[1] isa BT.UserMsg
        @test model.msgs_store[1].queued == false

        # Simulate a turn in flight, then two more sends — they should both
        # appear immediately, marked queued.
        model.busy_active[] = true
        BT.send_message!(model, BT.UserMsg("queued 1"))
        BT.send_message!(model, BT.UserMsg("queued 2"))
        @test length(model.msgs_store) == 3
        @test model.msgs_store[2].queued == true
        @test model.msgs_store[3].queued == true

        # Promotion clears the OLDEST queued bubble (FIFO).
        BT.promote_queued_user_bubble!(model)
        @test model.msgs_store[2].queued == false
        @test model.msgs_store[3].queued == true

        BT.promote_queued_user_bubble!(model)
        @test model.msgs_store[3].queued == false

        # No-op when nothing is queued.
        BT.promote_queued_user_bubble!(model)
        @test all(!m.queued for m in model.msgs_store if m isa BT.UserMsg)

        # Persisted bubbles round-trip queued=false (the queued flag is transient —
        # the load_history reader always instantiates UserMsg with queued=false).
        reloaded = BT.load_history(model.chat_session)
        @test all(m.queued == false for m in reloaded if m isa BT.UserMsg)
    end

    # ── DOM e2e: the queued bubbles wear `bt-queued`, FIFO promotion clears ───
    @testset "queued bubble wears bt-queued; FIFO promotion clears (DOM)" begin
        s = TK.dev_server()
        try
            TK.open_browser(s; width = 1280, height = 820)
            pid = TK.new_chat(s)
            TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
            TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
            chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

            # Two bubbles injected the way a busy turn would render them
            # (wire_new carries queued=true). `send!` emits + pushes without
            # enqueuing a turn, so the live consumer can't race us.
            b1 = BT.UserMsg(chat, "queued 1"); b1.queued = true
            b2 = BT.UserMsg(chat, "queued 2"); b2.queued = true
            BT.send!(chat, b1); BT.send!(chat, b2)

            @test TK.wait_for(s, "two queued bubbles",
                "document.querySelectorAll('.bt-user-msg.bt-queued').length === 2"; timeout = 10) == true

            # FIFO: the first promotion clears the OLDEST bubble; "queued 2" stays.
            BT.promote_queued_user_bubble!(chat)
            @test TK.wait_for(s, "one queued left",
                "document.querySelectorAll('.bt-user-msg.bt-queued').length === 1"; timeout = 10) == true
            @test TK.eval_js(s,
                "[...document.querySelectorAll('.bt-user-msg.bt-queued')].map(e=>e.textContent)") == Any["queued 2"]

            # The second promotion clears the rest.
            BT.promote_queued_user_bubble!(chat)
            @test TK.wait_for(s, "no queued left",
                "document.querySelectorAll('.bt-user-msg.bt-queued').length === 0"; timeout = 10) == true

            errs = TK.eval_js(s, "window.__errs || []")
            @test isempty(errs)
        finally
            close(s)
        end
    end

end
