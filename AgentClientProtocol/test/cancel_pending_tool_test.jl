# ── A Stop while a tool call's input still streams, from a REAL recording ────
#
# claude-agent-acp announces a tool call (`pending`) as soon as Claude starts
# writing it, seconds before the call can run. A Stop in that window answers the
# prompt `cancelled`, but the call that never ran is closed at the turn's end,
# AFTER the result that ends our prompt's reply:
#
#   14  out  session/cancel
#   15  in   usage_update with cost, origin human   the reply is over
#   16  in   tool_call_update failed                "Claude stopped this tool call before it ran."
#   17  in   RESPONSE stopReason=cancelled
#
# Frame 16 counted as work with no prompt left to reply to, so it opened a turn
# of the agent's own. A cancelled answer does not end such a turn, and nothing
# else was coming: the chat stayed busy, every later Stop went to an agent with
# nothing to stop, and only Force stop got out (11-22 to 11-27, 15 force-closes
# on the server, every one of them this shape where the wire was kept).
#
# fixtures/claude_cancel_pending_tool_wire.jsonl was captured by
# `acp_frame_logger` from the real adapter (0.109.1, Claude Code 2.1.330) under
# `BonitoAgents.dev_server`: Stop 1.5 s after the Bash card appeared. 0.107.3
# (Claude Code 2.1.325) sends the same order. Edits: the auth notifications and
# the account's email are gone, and the system prompt appendix, the MCP
# instructions and the slash command list are replaced by placeholders.
@testset "a Stop while a tool call streams ends the turn (real captured wire)" begin
    frames = [JSON.parse(l) for l in
              eachline(joinpath(@__DIR__, "fixtures", "claude_cancel_pending_tool_wire.jsonl"))]
    outbound = [f["msg"] for f in frames if f["dir"] == "out"]
    method_of_id = Dict{Any,String}(m["id"] => m["method"]
                                    for m in outbound if haskey(m, "method") && haskey(m, "id"))
    replies = Dict{String,Vector{Any}}()
    for f in frames
        m = f["msg"]
        (f["dir"] == "in" && !haskey(m, "method")) || continue
        meth = get(method_of_id, get(m, "id", nothing), nothing)
        meth === nothing && continue
        push!(get!(replies, meth, Any[]), get(m, "result", Dict{String,Any}()))
    end
    asked     = findfirst(f -> get(f["msg"], "method", "") == "session/prompt", frames)
    cancelled = findfirst(f -> get(f["msg"], "method", "") == "session/cancel", frames)
    notification(f) = f["dir"] == "in" && haskey(f["msg"], "method")
    during = [f["msg"] for f in frames[(asked + 1):(cancelled - 1)] if notification(f)]
    after  = [f["msg"] for f in frames[(cancelled + 1):end] if notification(f)]
    answer = pop!(replies["session/prompt"])

    # Guard the FIXTURE: a recapture that loses this shape stops covering it.
    update(m) = get(get(m, "params", Dict()), "update", Dict())
    kind(m)   = get(update(m), "sessionUpdate", "")
    @test answer["stopReason"] == "cancelled"
    pending = only(filter(m -> kind(m) == "tool_call", during))
    @test update(pending)["status"] == "pending"
    @test kind.(after) == ["usage_update", "tool_call_update"]
    result, closing = after
    @test haskey(update(result), "cost")
    @test update(result)["_meta"]["_claude/origin"]["kind"] == "human"
    @test update(closing)["toolCallId"] == update(pending)["toolCallId"]
    @test update(closing)["status"] == "failed"

    port  = freeport()
    ws_ch = Channel{Any}(1); hold = Channel{Nothing}(0)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws); try take!(hold) catch e; e isa InvalidStateException || rethrow() end   # closed at teardown
    end
    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            pending_replies = Dict(k => copy(v) for (k, v) in replies)
            prompt_id = nothing
            while true
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                id = req_id(line); m = req_method(line)
                if m == "session/prompt"
                    prompt_id = id
                    foreach(n -> emit(cws, JSON.json(n)), during)
                elseif m == "session/cancel" && prompt_id !== nothing
                    # What the adapter sent once the cancel was in, as recorded.
                    foreach(n -> emit(cws, JSON.json(n)), after)
                    emit(cws, result_frame(prompt_id, JSON.json(answer)))
                    prompt_id = nothing
                elseif id !== nothing && m !== nothing
                    got = get(pending_replies, m, Any[])
                    emit(cws, result_frame(id, JSON.json(isempty(got) ? Dict{String,Any}() : popfirst!(got))))
                end
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "real-wire agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler();
                          agent_turns = true)
    rendered = Channel{Any}(256)
    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        collect_main!(rendered, client)
        turn = ACP.prompt!(client, "replayed")
        seen = Any[]
        drain!() = (while isready(rendered); push!(seen, take!(rendered)); end; seen)
        tool() = (i = findfirst(m -> m isa ACP.ToolCall, drain!()); i === nothing ? nothing : seen[i])
        # Stop once the card is on screen, as the user did.
        @test timedwait(() -> tool() !== nothing, 10.0; pollint = 0.05) === :ok
        @test ACP.cancel!(client) == [turn]
        @test ACP.wait_turn!(turn)["stopReason"] == "cancelled"
        # The call that never ran is closed on the card...
        @test timedwait(() -> tool().status == "failed", 5.0; pollint = 0.05) === :ok
        # ...and nothing is left running: the chat is idle, no turn of the
        # agent's own was opened for that closing frame.
        @test timedwait(() -> isempty(ACP.open_turns(conn)), 5.0; pollint = 0.05) === :ok
        @test !any(m -> m isa ACP.TurnStarted, drain!())
    finally
        close(rendered); close(conn)
        close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end
