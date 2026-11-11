# ── A held answer, driven by a REAL recording ────────────────────────────────
#
# claude-agent-acp 0.101 holds the answer to a prompt while a background subagent
# that the prompt started (or revived with SendMessage) runs, and answers once the
# subagent ended and the agent reported on it, or when the next prompt comes. The
# reply itself is over at its result. Chats counted the prompt as open until the
# answer: on 2026-11-11 a revived subagent ran for an hour and the chat looked
# busy the whole time, with every message "for when done" queued behind it.
#
# fixtures/claude_bg_subagent_hold_wire.jsonl was captured by `acp_frame_logger`
# from the real adapter under `BonitoAgents.dev_server` (e2e:subagent_resume_real),
# with the account's email address replaced. Its first prompt:
#
#   12  out  session/prompt id=4             start a background subagent
#   20  in   tool_call Agent                 the launch
#   25  in   tool_call_update toolResponse   agentId + outputFile
#   40  in   usage_update cost, origin human the reply is over
#   41  in   tool_call Bash, parent = launch the subagent works
#   45  in   agent_message_chunk             the agent reports on it
#   51  in   usage_update origin task-notification
#   52  in   RESPONSE id=4 end_turn          the held answer
@testset "a held answer: the reply is over at its result (real captured wire)" begin
    frames = [JSON.parse(l) for l in
              eachline(joinpath(@__DIR__, "fixtures", "claude_bg_subagent_hold_wire.jsonl"))]
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
    asked    = findfirst(f -> get(f["msg"], "method", "") == "session/prompt", frames)
    prompt_id = frames[asked]["msg"]["id"]
    answered = findfirst(f -> f["dir"] == "in" && get(f["msg"], "id", nothing) == prompt_id &&
                              haskey(f["msg"], "result"), frames)
    notification(f) = f["dir"] == "in" && haskey(f["msg"], "method")
    during = [f["msg"] for f in frames[(asked + 1):(answered - 1)] if notification(f)]
    update(m) = get(get(m, "params", Dict()), "update", Dict())
    origin(m) = get(get(get(update(m), "_meta", Dict()), "_claude/origin", Dict()), "kind", nothing)
    is_result(m) = get(update(m), "sessionUpdate", "") == "usage_update" && haskey(update(m), "cost")
    reply_end = findfirst(m -> is_result(m) && origin(m) == "human", during)

    # Guard the FIXTURE: a recapture that loses this shape stops covering it.
    @test reply_end !== nothing
    launch = findfirst(m -> get(get(get(update(m), "_meta", Dict()), "claudeCode", Dict()), "toolName", "") == "Agent", during)
    @test launch !== nothing && launch < reply_end
    after = during[(reply_end + 1):end]
    @test any(m -> get(get(get(update(m), "_meta", Dict()), "claudeCode", Dict()), "parentToolUseId", nothing) !== nothing, after)
    @test any(m -> get(update(m), "sessionUpdate", "") == "agent_message_chunk" &&
                   get(get(get(update(m), "_meta", Dict()), "claudeCode", Dict()), "parentToolUseId", nothing) === nothing, after)
    @test origin(last(filter(is_result, after))) == "task-notification"

    port  = freeport()
    ws_ch = Channel{Any}(1); hold = Channel{Nothing}(0)
    go_on = Channel{Nothing}(1)          # the test lets the subagent "finish"
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws); try take!(hold) catch e; e isa InvalidStateException || rethrow() end   # closed at teardown
    end
    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            pending = Dict(k => copy(v) for (k, v) in replies)
            while true
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                id = req_id(line); m = req_method(line)
                (id === nothing || m === nothing) && continue
                got = get(pending, m, Any[])
                body = isempty(got) ? Dict{String,Any}() : popfirst!(got)
                if m == "session/prompt"
                    # The reply, up to its result; then, once the test has looked,
                    # the subagent's work, the agent's report and the answer.
                    foreach(n -> emit(cws, JSON.json(n)), during[1:reply_end])
                    take!(go_on)
                    foreach(n -> emit(cws, JSON.json(n)), after)
                end
                emit(cws, result_frame(id, JSON.json(body)))
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "real-wire agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler();
                          agent_turns = true)
    rendered = Channel{Any}(1024)
    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        collect_main!(rendered, client)
        turn = ACP.prompt!(client, "replayed")
        # The reply is over at its result; the answer is still held.
        ACP.wait_replied(turn)
        @test ACP.isreplied(turn)
        @test !ACP.isover(turn)
        @test isempty(ACP.open_turns(conn))
        put!(go_on, nothing)
        @test ACP.wait_turn!(turn)["stopReason"] == "end_turn"
        seen = Any[]
        done() = (while isready(rendered); push!(seen, take!(rendered)); end;
                  any(m -> m isa ACP.UsageUpdate && m.origin_kind == "task-notification", seen))
        @test timedwait(done, 10.0; pollint = 0.05) === :ok
        # The report on the finished subagent was the agent's own turn, and it is over.
        @test count(m -> m isa ACP.TurnStarted, seen) == 1
        @test isempty(ACP.open_turns(conn))
        @test ACP.isover(turn)
    finally
        close(rendered); close(conn)
        close(hold); close(server); close(go_on)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end
