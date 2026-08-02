# ── Cancelling agent work that isn't wrapped in a session/prompt ──────────────
#
# The agent does not do all its work inside a request. After it backgrounds a
# subagent it resolves the prompt with `end_turn`, and when that finishes it
# auto-wakes and streams a WHOLE further turn — tool calls AND prose — with no
# `session/prompt` around it. `Connection` routes those through
# `on_orphan_update`, and BonitoAgents renders them as a normal turn.
#
# Shape taken from the real capture in
# BonitoAgents/test/fixtures/bg_subagent_wire.jsonl:
#
#   frame  4  t= 0.94  →  session/prompt id=3
#   frame 19  t= 6.74  ←  RESPONSE id=3 stopReason=end_turn   (active_turns empties)
#   frame 21  t= 8.30  ←  tool_call                           ┐
#   frame 22  t=14.88  ←  tool_call_update                    │ 27 s of agent work
#   frame 25  t=19.17  ←  agent_message_chunk                 ┘ with no open request
#   frame 30  t=33.60  →  session/prompt id=4
#
# For 27 seconds the agent is visibly running tools and answering. Pressing stop
# anywhere in that window must reach the agent — from the user's side nothing
# distinguishes it from any other moment the agent is working.
#
# The agent side is driven inline here rather than through `run_scenario`,
# because the assertion IS "did a session/cancel frame arrive", so the test has
# to be the one reading the wire.

# Defined at FILE scope on purpose. `on_orphan_update` is assigned after the
# Connection's dispatcher task already exists, and a closure whose method is
# defined in a newer world than that task cannot be called from it — the
# dispatcher swallows the MethodError as "on_orphan_update threw" and every
# orphan update vanishes. Building the closure from a method that predates the
# task avoids it. (Production is fine: there the closure's method is compiled
# with `start_chat_client!`, long before any task runs.)
orphan_recorder(ch) = u -> (isopen(ch) && put!(ch, u); nothing)

@testset "cancel reaches the agent during un-prompted work" begin
    port  = freeport()
    ws_ch = Channel{Any}(1)
    hold  = Channel{Nothing}(0)

    # Every client→agent method, in order, as the agent sees it.
    seen  = Channel{String}(64)
    # Closed once the orphan updates are on the wire, so the test cancels inside
    # the window rather than racing it.
    orphaning = Channel{Nothing}(1)

    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws)
        try take!(hold) catch end
    end

    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            answer_setup(cws) || return
            # Wait for the prompt that opens the turn.
            prompt_id = nothing
            while prompt_id === nothing
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                req_method(line) == "session/prompt" && (prompt_id = req_id(line))
            end
            emit(cws, text_update("working on it"))
            emit(cws, prompt_done(prompt_id))     # ← active_turns empties HERE

            # Un-prompted work: the agent runs a tool and answers, exactly as in
            # frames 21-27 of the capture.
            emit(cws, tool_call_update("bg-1", "in_progress"))
            emit(cws, text_update("still going"))
            put!(orphaning, nothing)

            # Record what the client sends from here on. A working stop shows up
            # as `session/cancel`; today nothing arrives and this drains empty.
            while true
                line = recv_frame(cws); line === nothing && break
                isempty(line) && continue
                m = req_method(line)
                m === nothing || (isopen(seen) && put!(seen, m))
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "orphan-cancel agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    orphans   = Channel{Any}(64)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler())
    conn.on_orphan_update = orphan_recorder(orphans)

    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())

        # `prompt!` hands back the turn's message channel; draining it blocks
        # until the turn resolves (end_turn), which is what empties active_turns.
        for _ in ACP.prompt!(client, "go"); end

        # Now in the window: no request open, agent still working.
        take!(orphaning)
        @test timedwait(() -> isready(orphans), 5.0) === :ok   # orphan work is live
        @test isempty(conn.active_turns)                       # ...and unregistered

        ACP.cancel!(client)

        # THE ASSERTION: the user pressed stop, so session/cancel must be on the
        # wire. Fails today — cancel! returns early on `isempty(active_turns)`,
        # so the stop button is a no-op for the whole window.
        got = String[]
        ok = timedwait(5.0; pollint = 0.05) do
            while isready(seen); push!(got, take!(seen)); end
            "session/cancel" in got
        end
        @test ok === :ok
        @test "session/cancel" in got
    finally
        close(orphans); close(seen)
        close(conn)
        close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end

# ── Same property, driven by a REAL recording ────────────────────────────────
#
# The testset above hand-writes the agent's frames. This one replays
# fixtures/real_stop_orphan_wire.jsonl — captured by `acp_frame_logger` from a
# live claude-agent-acp session (BonitoAgents dev server, one Task subagent) at
# the moment stop was pressed. Its tail is the whole bug:
#
#   37  in   RESPONSE stopReason=end_turn        active_turns empties
#   38  in   session/update session_info_update  agent still streaming, no turn
#   39  out  session/cancel                      what the fix makes happen
#
# Frame 39 is absent from any recording made before `Connection.orphan_work`
# existed, because `cancel!` returned early on `isempty(active_turns)`.
#
# The agent side replays the recorded INBOUND frames in order, answering each
# request with the recorded response (re-stamped with the id our Connection
# actually used, since ids are per-connection).
@testset "cancel during un-prompted work (real captured wire)" begin
    frames = [JSON.parse(l) for l in
              eachline(joinpath(@__DIR__, "fixtures", "real_stop_orphan_wire.jsonl"))]
    inbound = [f["msg"] for f in frames if f["dir"] == "in"]
    # Recorded responses, in order, to be matched against our outbound requests.
    responses = [m for m in inbound if !haskey(m, "method")]
    notifs    = [m for m in inbound if haskey(m, "method")]
    @test !isempty(responses)
    # The recording must actually contain the orphan-window cancel, or this test
    # is pinning the wrong capture.
    @test any(f -> f["dir"] == "out" && get(f["msg"], "method", "") == "session/cancel", frames)

    port  = freeport()
    ws_ch = Channel{Any}(1)
    hold  = Channel{Nothing}(0)
    seen  = Channel{String}(64)
    ready = Channel{Nothing}(1)

    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws); try take!(hold) catch end
    end

    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            ri = 1
            # Answer initialize + session/new + prompt from the recording.
            while ri <= 3
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                id = req_id(line); id === nothing && continue
                body = JSON.json(get(responses[ri], "result", Dict{String,Any}()))
                emit(cws, result_frame(id, body))
                ri += 1
                # After the prompt's request is answered we are past setup; stream
                # the recorded notifications, then the prompt response.
            end
            for n in notifs
                emit(cws, JSON.json(n))
            end
            put!(ready, nothing)
            while true
                line = recv_frame(cws); line === nothing && break
                isempty(line) && continue
                m = req_method(line)
                m === nothing || (isopen(seen) && put!(seen, m))
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "real-wire agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    orphans = Channel{Any}(64)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler())
    conn.on_orphan_update = orphan_recorder(orphans)

    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        # The recorded prompt response resolves this turn; drain to its end.
        for _ in ACP.prompt!(client, "replayed"); end
        take!(ready)
        @test timedwait(() -> isready(orphans), 10.0) === :ok
        @test isempty(conn.active_turns)

        ACP.cancel!(client)
        got = String[]
        ok = timedwait(10.0; pollint = 0.05) do
            while isready(seen); push!(got, take!(seen)); end
            "session/cancel" in got
        end
        @test ok === :ok
        @test "session/cancel" in got
    finally
        close(orphans); close(seen); close(conn)
        close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end
