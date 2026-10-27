@testitem "unit:wait_input" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    const ACP = BT.AgentClientProtocol
    mutable struct IdleTransport <: ACP.Transport
        gate::Channel{Nothing}
    end
    ACP.send(::IdleTransport, ::AbstractString) = nothing
    ACP.recv(t::IdleTransport) = (isopen(t.gate) && wait(t.gate); "")
    ACP.transport_eof(t::IdleTransport) = !isopen(t.gate)
    Base.close(t::IdleTransport) = (isopen(t.gate) && close(t.gate); nothing)
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    m = BT.ChatModel(state, mktempdir(); project_id = "wait-input",
        agent = BT.WorkerAgent(state, "offline", "/project"))
    state.chat_models[m.project_id] = m
    wait_card(id) = BT.GenericMCPToolMsg(
        BT.Message(id, "other", "", "bt_wait", "pending", "", time(), nothing, m),
        "btworker", "bt_wait")
    input(id = "") = BT.dev_request(state, "wait_input", Dict{String,Any}("tool_id" => id), m.project_id)
    try
        push!(m.msgs_store, wait_card("old-wait"), BT.UserMsg("new original prompt"))
        BT.send_message!(m, BT.UserMsg("new original prompt"))
        entry = only(m.pending_sends)
        entry.status = :sent
        entry.span = (turn = nothing, nstore0 = length(m.msgs_store))
        # Its new card has not rendered yet. The older card must not mistake
        # this turn's original prompt for a correction delivered during a wait.
        @test input() === false
        push!(m.msgs_store, wait_card("current-wait"))
        @test input() === false
        push!(m.msgs_store, BT.UserMsg("correction delivered before MCP connected"))
        @test input() === true
        @test input("current-wait") === true
        @test input("old-wait") === false
        @test input("missing") === false
        BT.send_message!(m, BT.UserMsg("overlapping prompt"))
        newer = last(m.pending_sends)
        newer.status = :sent
        newer.span = (turn=nothing, nstore0=length(m.msgs_store))
        @test input("current-wait") === true
        @test BT.dev_request(state, "wait_input", Dict{String,Any}(), "another-chat") === false
        push!(m.msgs_store, wait_card("later-wait"))
        @test input() === false
    finally
        close(m)
    end

    # "Queue after message" stays selected after a turn ends. A fresh prompt
    # in that mode is the wait's OWN input, not a correction that should wake it.
    fresh = BT.ChatModel(state, mktempdir(); project_id = "wait-initial",
        agent = BT.WorkerAgent(state, "offline", "/project"))
    state.chat_models[fresh.project_id] = fresh
    conn = ACP.Connection(IdleTransport(Channel{Nothing}(0)), ACP.DiscardHandler())
    fresh.agent.client = ACP.Client(conn, "sess", "/project")
    try
        BT.send_message!(fresh, BT.UserMsg("wait for peer"); mode = :next)
        own = only(fresh.pending_sends)
        turn = ACP.prompt_request(conn, Dict())
        @test !BT.has_other_turn(fresh, turn)
        BT.submission_submitted!(fresh, own, turn; text = own.bubble.text, receipt_id = "own")
        @test BT.dev_request(state, "wait_input", Dict{String,Any}(), fresh.project_id) === false

        BT.send_message!(fresh, BT.UserMsg("peer correction"); mode = :next)
        correction = last(fresh.pending_sends)
        next_turn = ACP.prompt_request(conn, Dict())
        @test BT.has_other_turn(fresh, next_turn)
        BT.submission_submitted!(fresh, correction, next_turn; text = correction.bubble.text, receipt_id = "peer")
        @test BT.dev_request(state, "wait_input", Dict{String,Any}(), fresh.project_id) === true
    finally
        close(conn)
        close(fresh)
    end
end
