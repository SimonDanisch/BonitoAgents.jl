@testitem "unit:wait_input" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
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
        @test BT.dev_request(state, "wait_input", Dict{String,Any}(), "another-chat") === false
        push!(m.msgs_store, wait_card("later-wait"))
        @test input() === false
    finally
        close(m)
    end
end
