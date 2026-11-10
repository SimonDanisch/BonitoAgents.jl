# ── An idle compaction, driven by a REAL recording ───────────────────────────
#
# claude-agent-acp 0.101 compacts a session by itself once it has been idle for
# 54 minutes, so the next prompt doesn't rewrite a context of 200k tokens or
# more into the cache. It sends `/compact` as its own prompt: no `session/prompt`
# of ours is open, and nothing on the wire says where that cycle ends. Live
# chats opened a turn of the agent's own at its first frame and stayed busy
# until the user force-closed the connection.
#
# fixtures/claude_idle_compaction_wire.jsonl was captured by `acp_frame_logger`
# from the real adapter under `BonitoAgents.dev_server`: one prompt that brought
# the context to 183759 tokens, then the adapter's `/compact` 20 s later
# (CLAUDE_AGENT_ACP_IDLE_COMPACT_DELAY_MS=20000). Two edits: the prompt's 396 KB
# of source text, and the account's email address. Its tail:
#
#   21  in   RESPONSE stopReason=end_turn        our prompt is over
#   22  in   tool_call "Compact conversation"    the adapter's own /compact
#   23  in   usage_update                        rate limit, no origin
#   24  in   tool_call_update completed
#   25  in   tool_call_update rawOutput.trigger = "idle"
#   26  in   usage_update                        the context after it, no origin
#
# No result tagged with an origin, no answer: nothing ends a turn. So a
# compaction must not open one.
@testset "an idle compaction opens no turn (real captured wire)" begin
    frames = [JSON.parse(l) for l in
              eachline(joinpath(@__DIR__, "fixtures", "claude_idle_compaction_wire.jsonl"))]
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
    answered = findfirst(f -> f["dir"] == "in" && haskey(f["msg"], "result") &&
                              get(method_of_id, get(f["msg"], "id", nothing), "") == "session/prompt",
                         frames)
    notification(f) = f["dir"] == "in" && haskey(f["msg"], "method")
    during = [f["msg"] for f in frames[(asked + 1):(answered - 1)] if notification(f)]
    tail   = [f["msg"] for f in frames[(answered + 1):end] if notification(f)]

    # Guard the FIXTURE: a recapture that loses this shape stops covering it.
    update(m) = get(get(m, "params", Dict()), "update", Dict())
    meta(m)   = get(update(m), "_meta", Dict())
    @test !isempty(tail) && all(m -> m["method"] == "session/update", tail)
    @test update(first(tail))["sessionUpdate"] == "tool_call"
    @test all(m -> get(get(meta(m), "claudeCode", Dict()), "toolName", "") == "compact",
              filter(m -> startswith(update(m)["sessionUpdate"], "tool_call"), tail))
    @test any(m -> get(get(update(m), "rawOutput", Dict()), "trigger", "") == "idle", tail)
    @test !any(m -> haskey(meta(m), "_claude/origin"), tail)
    last_used = update(last(tail))["used"]

    port  = freeport()
    ws_ch = Channel{Any}(1); hold = Channel{Nothing}(0)
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
                # The prompt is answered where it was live: after what streamed
                # during it, and followed by the adapter's own compaction.
                m == "session/prompt" && foreach(n -> emit(cws, JSON.json(n)), during)
                emit(cws, result_frame(id, JSON.json(body)))
                if m == "session/prompt"
                    for n in tail
                        sleep(0.05)
                        emit(cws, JSON.json(n))
                    end
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
        ACP.wait_turn!(ACP.prompt!(client, "replayed"))      # the recorded end_turn
        seen = Any[]
        done() = (while isready(rendered); push!(seen, take!(rendered)); end;
                  any(m -> m isa ACP.UsageUpdate && m.used == last_used, seen))
        @test timedwait(done, 10.0; pollint = 0.05) === :ok
        # The compaction reached the chat, under the compaction's name, finished.
        compaction = findfirst(m -> m isa ACP.GenericTool && m.name == ACP.CONTEXT_COMPACTION_TOOL, seen)
        @test compaction !== nothing && seen[compaction].status == "completed"
        # ...and the session is idle: no turn opened, none left open.
        @test !any(m -> m isa ACP.TurnStarted, seen)
        @test isempty(ACP.open_turns(conn))
    finally
        close(rendered); close(conn)
        close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end
