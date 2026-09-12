# The per-tab ChatModel's `busy_active` is a session-scoped CHILD of the shared
# one (parent→child only), so end-of-turn must clear the PARENT. Clearing the
# child left every other tab (and every reload) rendering "working" forever.
# unit:busy simulates the accounting by hand, so it can't catch this — this one
# drives the real `finish_turn!` through a real per-tab copy.
@testitem "unit:busy_shared" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    const BT = BonitoAgents

    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    parent = BT.ChatModel(state, mktempdir(); project_id = "proj",
                          agent = BT.WorkerAgent(state, "w1", "/p"))
    tab = copy(parent, Bonito.Session())
    @test BT.shared(tab) === parent
    @test tab.busy_active !== parent.busy_active     # genuinely a child

    # A turn opens on the shared flag and is drained through the TAB's model.
    # The span is settled before we drain it — `finish_turn!` waits on the
    # response, then on the render barrier, and with no ACP session bound the
    # barrier is a no-op (there is no renderer to wait for).
    const ACP = BT.AgentClientProtocol
    span = ACP.PromptSpan(1)
    put!(span.response, Dict{String,Any}("stopReason" => "end_turn"))
    BT.while_busy(tab) do
        # Claimed through the TAB, but the flag and the spinner are the parent's.
        @test parent.turn_in_flight[] == true
        @test parent.busy_active[] == true
        BT.finish_turn!(tab, span)
    end

    @test parent.turn_in_flight[] == false
    @test parent.busy_active[] == false              # the bug: stayed true
end
