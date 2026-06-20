# Messages submitted while a turn is in flight render immediately as "queued"
# bubbles rather than being silently buffered on the channel. When `run_turn!`
# picks them up, `promote_queued_user_bubble!` clears the flag FIFO so the
# DOM `bt-queued` class drops in order.
using Test
using BonitoAgents
const BT = BonitoAgents

@testset "queued user messages" begin
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir();
                          transport = BT.MockTransport((o, i) -> nothing))

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
    # we only persist via close() in send_message!, which writes the message
    # text but the load_history reader instantiates UserMsg with queued=false).
    reloaded = BT.load_history(model.chat_session)
    @test all(m.queued == false for m in reloaded if m isa BT.UserMsg)
end
