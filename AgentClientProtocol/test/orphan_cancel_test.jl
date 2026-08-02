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
# fixtures/real_stop_orphan_wire.jsonl was captured by `acp_frame_logger` from a
# live claude-agent-acp session: a backgrounded shell task, the turn ended
# immediately, then the agent auto-woke when it finished. Its tail is why
# liveness is narrowed to `is_agent_work`:
#
#   26  in   RESPONSE stopReason=end_turn          active_turns empties
#   27  in   session/update session_info_update    metadata — must NOT arm
#   28  in   session/update usage_update           metadata — must NOT arm
#   29  in   session/update tool_call              REAL WORK — arms orphan_work
#   30  out  session/cancel                        fires, and only now
#
# Both halves matter. An earlier capture had the cancel firing on frame 27's
# metadata alone, which is what 05c12b8 removed: a session that has merely
# reported its own state is idle, and cancelling there would latch `cancelling`
# over an idle gap and swallow the agent's next burst of background work.
@testset "cancel during un-prompted work (real captured wire)" begin
    frames = [JSON.parse(l) for l in
              eachline(joinpath(@__DIR__, "fixtures", "real_stop_orphan_wire.jsonl"))]
    inbound  = [f["msg"] for f in frames if f["dir"] == "in"]
    outbound = [f["msg"] for f in frames if f["dir"] == "out"]

    # Pair each recorded response with the METHOD it answered, so the replay can
    # answer by method rather than by position. Answering positionally handed the
    # prompt a `set_config_option` result, so the turn resolved early and every
    # remaining frame became an orphan — the test passed, but not via the
    # structure it claimed to reproduce.
    method_of_id = Dict{Any,String}(m["id"] => m["method"]
                                  for m in outbound if haskey(m, "method") && haskey(m, "id"))
    replies = Dict{String,Vector{Any}}()
    for m in inbound
        haskey(m, "method") && continue
        meth = get(method_of_id, get(m, "id", nothing), nothing)
        meth === nothing && continue
        push!(get!(replies, meth, Any[]), get(m, "result", Dict{String,Any}()))
    end
    @test haskey(replies, "session/prompt")

    # Guard the FIXTURE itself: if a recapture loses this ordering the test would
    # silently stop covering what it documents.
    su(m) = get(get(get(m, "params", Dict()), "update", Dict()), "sessionUpdate", "")
    endi  = findlast(m -> !haskey(m, "method") &&
                          get(get(m, "result", Dict()), "stopReason", "") != "", inbound)
    # Notifications AFTER the last end_turn, in recorded order. Sliced out of
    # `inbound` (where `endi` is an index) and not out of the pre-filtered
    # `notifs`, whose indices do not line up with it.
    tail_notifs = [m for m in inbound[(endi+1):end] if haskey(m, "method")]
    tail  = [su(m) for m in tail_notifs]
    @test "tool_call" in tail                       # real work after end_turn
    @test findfirst(==("session_info_update"), tail) <
          findfirst(==("tool_call"), tail)          # metadata comes first, and does not arm

    port  = freeport()
    ws_ch = Channel{Any}(1); hold = Channel{Nothing}(0)
    seen  = Channel{String}(64); ready = Channel{Nothing}(1)

    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws); try take!(hold) catch end
    end

    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            pending = Dict(k => copy(v) for (k, v) in replies)
            # Answer requests from the recording, by method, until the prompt is
            # answered — that response is the recorded end_turn, so the turn
            # resolves exactly where it did live.
            while true
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                id = req_id(line); m = req_method(line)
                (id === nothing || m === nothing) && continue
                got = get(pending, m, Any[])
                body = isempty(got) ? Dict{String,Any}() : popfirst!(got)
                emit(cws, result_frame(id, JSON.json(body)))
                m == "session/prompt" && break
            end
            # Everything the agent streamed AFTER end_turn, in recorded order:
            # metadata first (must not arm), then the tool_call (must).
            for n in tail_notifs
                emit(cws, JSON.json(n))
                sleep(0.05)
            end
            put!(ready, nothing)
            while true
                line = recv_frame(cws); line === nothing && break
                isempty(line) && continue
                mm = req_method(line)
                mm === nothing || (isopen(seen) && put!(seen, mm))
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
        for _ in ACP.prompt!(client, "replayed"); end   # resolves on the RECORDED end_turn
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

# ── Cancelling a turn must not silence unrelated background work ─────────────
#
# `cancelling` gates the orphan branch so the dispatcher can skip a cancelled
# turn's backlog and reach its `cancelled` response. But it was only cleared by
# the NEXT `request_updates`, so between the cancel and the user's next message
# every orphan update was dropped — a background subagent nobody cancelled kept
# running with its output thrown away. Stopping one turn should stop that turn.
@testset "cancel does not silence later background work" begin
    port  = freeport()
    ws_ch = Channel{Any}(1); hold = Channel{Nothing}(0)
    settled = Channel{Nothing}(1)

    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws); try take!(hold) catch end
    end

    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            answer_setup(cws) || return
            pid = nothing
            while pid === nothing
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                req_method(line) == "session/prompt" && (pid = req_id(line))
            end
            emit(cws, text_update("streaming"))
            # Wait for the cancel, then settle the turn — the real sequence.
            while true
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                req_method(line) == "session/cancel" && break
            end
            emit(cws, prompt_done(pid, "cancelled"))
            put!(settled, nothing)
            # A background subagent the user never cancelled, still working.
            sleep(0.3)
            emit(cws, text_update("background subagent still going"))
            drain_until_close(cws)
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "bg-after-cancel agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    orphans = Channel{Any}(64)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler())
    conn.on_orphan_update = orphan_recorder(orphans)
    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        turn = ACP.prompt!(client, "go")
        streamer = @async (for _ in turn; end)
        timedwait(() -> (@atomic conn.cancelling) || true, 1.0)
        ACP.cancel!(client)
        @test (@atomic conn.cancelling)            # latched for the cancelled turn
        take!(settled)
        timedwait(() -> istaskdone(streamer), 5.0)

        # Settled: the latch must be gone, so later background work still lands.
        @test timedwait(() -> !(@atomic conn.cancelling), 5.0) === :ok
        @test timedwait(() -> isready(orphans), 5.0) === :ok
    finally
        close(orphans); close(conn); close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end
