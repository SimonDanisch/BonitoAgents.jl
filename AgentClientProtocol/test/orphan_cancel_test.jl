# ── Cancelling agent work that isn't wrapped in a session/prompt ──────────────
#
# The agent does not do all its work inside a request. After it backgrounds a
# subagent it resolves the prompt with `end_turn`, and when that finishes it
# auto-wakes and streams a WHOLE further turn — tool calls AND prose — with no
# `session/prompt` around it. That work is the session's MAIN THREAD talking, so
# it comes down the same stream as everything else the main thread says, and
# BonitoAgents renders it the same way. A prompt is a span over that stream, not
# a container for it.
#
# Shape taken from the real capture in
# BonitoAgents/test/fixtures/bg_subagent_wire.jsonl:
#
#   frame  4  t= 0.94  →  session/prompt id=3
#   frame 19  t= 6.74  ←  RESPONSE id=3 stopReason=end_turn   (the span closes)
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

# Drain a Client's main stream into `sink`, answering flush markers so a
# `flush_main!` never hangs. Ends when the stream closes.
function collect_main!(sink::Channel, client)
    task = @async begin
        for m in client.messages
            if m isa ACP.StreamFlush
                ACP.signal_rendered!(m)
            elseif isopen(sink)
                put!(sink, m)
            end
        end
    end
    return Base.errormonitor(task)
end

@testset "cancel reaches the agent during un-prompted work" begin
    port  = freeport()
    ws_ch = Channel{Any}(1)
    hold  = Channel{Nothing}(0)

    # Every client→agent method, in order, as the agent sees it.
    seen  = Channel{String}(64)
    # Closed once the un-prompted updates are on the wire, so the test cancels
    # inside the window rather than racing it.
    working = Channel{Nothing}(1)

    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws)
        try take!(hold) catch end
    end

    agent = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            answer_setup(cws) || return
            # Wait for the prompt that opens the span.
            prompt_id = nothing
            while prompt_id === nothing
                line = recv_frame(cws); line === nothing && return
                isempty(line) && continue
                req_method(line) == "session/prompt" && (prompt_id = req_id(line))
            end
            emit(cws, text_update("working on it"))
            emit(cws, prompt_done(prompt_id))     # ← the span closes HERE

            # Un-prompted work: the agent runs a tool and answers, exactly as in
            # frames 21-27 of the capture.
            emit(cws, tool_call_update("bg-1", "in_progress"))
            emit(cws, text_update("still going"))
            put!(working, nothing)

            # Record what the client sends from here on. A working stop shows up
            # as `session/cancel`; a broken one drains empty.
            while true
                line = recv_frame(cws); line === nothing && break
                isempty(line) && continue
                m = req_method(line)
                m === nothing || (isopen(seen) && put!(seen, m))
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "un-prompted-cancel agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler())
    rendered = Channel{Any}(64)

    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        collect_main!(rendered, client)

        ACP.wait_turn!(ACP.prompt!(client, "go"))   # settles on the recorded end_turn

        # Now in the window: no prompt open, agent still working.
        take!(working)
        @test timedwait(() -> ACP.session_activity(conn) isa ACP.Unprompted, 5.0) === :ok
        @test isempty(conn.active_prompts)          # ...and nothing is registered

        # The un-prompted work is RENDERED, not dropped: it is the main thread
        # talking, and the same stream carries it.
        @test timedwait(() -> Base.n_avail(rendered) >= 2, 5.0) === :ok

        ACP.cancel!(client)

        # THE ASSERTION: the user pressed stop, so session/cancel must be on the
        # wire. Asking "is a prompt open" instead of "is the agent working" made
        # the stop button a no-op for the whole window.
        got = String[]
        ok = timedwait(5.0; pollint = 0.05) do
            while isready(seen); push!(got, take!(seen)); end
            "session/cancel" in got
        end
        @test ok === :ok
        @test "session/cancel" in got
    finally
        close(rendered); close(seen)
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
#   26  in   RESPONSE stopReason=end_turn          the span closes
#   27  in   session/update session_info_update    metadata — must NOT count
#   28  in   session/update usage_update           metadata — must NOT count
#   29  in   session/update tool_call              REAL WORK — goes Unprompted
#   30  out  session/cancel                        fires, and only now
#
# Both halves matter. An earlier capture had the cancel firing on frame 27's
# metadata alone, which is what 05c12b8 removed: a session that has merely
# reported its own state is idle, and a stop there is a no-op the UI should read
# as "my spinner is stale" rather than as something to act on.
@testset "cancel during un-prompted work (real captured wire)" begin
    frames = [JSON.parse(l) for l in
              eachline(joinpath(@__DIR__, "fixtures", "real_stop_orphan_wire.jsonl"))]
    inbound  = [f["msg"] for f in frames if f["dir"] == "in"]
    outbound = [f["msg"] for f in frames if f["dir"] == "out"]

    # Pair each recorded response with the METHOD it answered, so the replay can
    # answer by method rather than by position. Answering positionally handed the
    # prompt a `set_config_option` result, so the turn resolved early and every
    # remaining frame arrived un-prompted — the test passed, but not via the
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
          findfirst(==("tool_call"), tail)          # metadata first, and does not count

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
            # answered — that response is the recorded end_turn, so the span
            # closes exactly where it did live.
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
            # metadata first (must not count), then the tool_call (must).
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
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler())
    rendered = Channel{Any}(64)

    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        collect_main!(rendered, client)
        ACP.wait_turn!(ACP.prompt!(client, "replayed"))   # the RECORDED end_turn
        take!(ready)
        @test timedwait(() -> ACP.session_activity(conn) isa ACP.Unprompted, 10.0) === :ok
        @test isempty(conn.active_prompts)

        ACP.cancel!(client)
        got = String[]
        ok = timedwait(10.0; pollint = 0.05) do
            while isready(seen); push!(got, take!(seen)); end
            "session/cancel" in got
        end
        @test ok === :ok
        @test "session/cancel" in got
    finally
        close(rendered); close(seen); close(conn)
        close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end

# ── Cancelling a turn must not silence work the user did not cancel ──────────
#
# Two separate ways this used to go wrong, both asserted here:
#
#   1. A SUBAGENT running in the background is not part of any turn. Its updates
#      are addressed to it by `parentToolUseId` and reach their owner directly,
#      so stopping the main thread cannot make a subagent go quiet. (It used to:
#      subagent updates went through the same gate as the turn's own.)
#   2. A cancel used to MUTE the main thread — the dispatcher dropped updates so
#      it could skip a cancelled turn's backlog and reach its `cancelled`
#      response. The mute was cleared only by that response, so cancelling
#      un-prompted work (which has no response coming) silenced the session
#      until the user reloaded. Nothing is dropped now; `Cancelling` is a state,
#      not a gate.
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
            # A background subagent the user never cancelled, streaming while
            # the main thread's cancel is still in flight.
            emit(cws, subagent_text_update("task-1", "subagent still going"))
            emit(cws, prompt_done(pid, "cancelled"))
            put!(settled, nothing)
            # ... and the main thread auto-waking afterwards.
            sleep(0.3)
            emit(cws, text_update("auto-wake after the stop"))
            drain_until_close(cws)
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "bg-after-cancel agent failed" exception = (e, catch_backtrace())
    end

    server_ws = take!(ws_ch)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), ACP.DiscardHandler())
    owned = Channel{Any}(64)
    conn.on_owner_update = (owner, u) -> (isopen(owned) && put!(owned, owner => u); nothing)
    rendered = Channel{Any}(64)
    try
        session_id = do_setup(conn)
        client = ACP.Client(conn, session_id, pwd(), Dict{String,Any}())
        collect_main!(rendered, client)
        turn = ACP.prompt!(client, "go")
        ACP.cancel!(client)
        @test ACP.session_activity(conn) isa ACP.Cancelling

        # (1) The subagent streamed WHILE the cancel was in flight, and arrived.
        @test timedwait(() -> isready(owned), 5.0) === :ok
        @test first(take!(owned)) == "task-1"

        take!(settled)
        @test ACP.wait_turn!(turn)["stopReason"] == "cancelled"

        # (2) Settled: `Cancelling` ends with the turn it cancelled, so the main
        # thread's next burst lands. Measured as GROWTH past whatever the
        # cancelled turn had already rendered — the point is that the stream did
        # not go dead, not how much got through before the stop.
        @test timedwait(() -> !(ACP.session_activity(conn) isa ACP.Cancelling), 5.0) === :ok
        base = Base.n_avail(rendered)
        @test timedwait(() -> Base.n_avail(rendered) > base, 5.0) === :ok
    finally
        close(owned); close(rendered); close(conn); close(hold); close(server)
        timedwait(() -> istaskdone(agent), 5.0)
    end
end
