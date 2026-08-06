using AgentClientProtocol
using Test
import HTTP
import Sockets
import JSON

const ACP = AgentClientProtocol

# ── Real-WebSocket mock agent ─────────────────────────────────────────────────
# The ONLY fake here is the AGENT's behavior: an in-process task that speaks ACP
# JSON-RPC over a loopback WebSocket (test/mocks/acp_mock_agent.jl). There is NO
# fake Transport — every testset drives the genuine `ACP.WorkerTransport` /
# `ACP.Connection` (real reader_loop/dispatcher) over a real WS, exactly as
# production does (the worker dial-back socket). The old stdio `SubprocessTransport`
# is gone, so the mock is a WS *peer*, not a subprocess; its behavior is selected
# per-test by scenario name. See the script for the scenario list.
include(joinpath(@__DIR__, "mocks", "acp_mock_agent.jl"))

# A running mock: the live `Connection` under test, the in-process agent task, a
# handle on the agent's peer socket (to sever it mid-session), and the loopback
# server to reap. `peer_alive` replaces the old `process_running(proc)`;
# `kill_peer!` replaces `kill(proc, SIGKILL)` (both simulate agent death, now as a
# dropped WS instead of a killed subprocess).
struct Mock
    conn    :: ACP.Connection
    task    :: Task
    peer_ws :: Ref{Any}      # the agent-side socket (set once the mock connects)
    server  :: Any           # HTTP.WebSockets server (loopback relay)
    hold    :: Channel{Nothing}
end

peer_alive(m::Mock) = !istaskdone(m.task)
kill_peer!(m::Mock) = (w = m.peer_ws[]; w === nothing || (try close(w) catch end); nothing)
# Release the loopback server handler + close the server. Idempotent. Every test
# calls this once it's done with the mock (the old subprocess mock had no server
# to reap; the WS relay does).
function relay_close!(m::Mock)
    isopen(m.hold) && close(m.hold)
    try close(m.server) catch end
    return nothing
end

# A free loopback port (opened + closed so `listen!` can bind it).
freeport() = (s = Sockets.listen(Sockets.localhost, 0);
              p = Sockets.getsockname(s)[2]; close(s); Int(p))

# Stand up a loopback WS relay, launch the scenario as the WS-client agent, and
# wrap the server-side socket in a real `WorkerTransport`/`Connection`. `n` is an
# integer knob a scenario reads (e.g. flood count). The caller MUST `close(conn)`
# (transport teardown) and `relay_close!` in a `finally` — closing the connection
# closes the server socket, so the agent's `recv` hits EOF and its task ends;
# `relay_close!` frees the loopback server.
function spawn_mock(scenario::AbstractString; n::Integer = 0,
                    handler::ACP.Handler = ACP.DiscardHandler())
    port    = freeport()
    ws_ch   = Channel{Any}(1)         # delivers the server-side socket
    hold    = Channel{Nothing}(0)     # closed at teardown to release the handler
    peer_ws = Ref{Any}(nothing)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(ws_ch, ws)
        try take!(hold) catch end     # keep the handler (and ws) alive until teardown
    end
    task = @async try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do cws
            peer_ws[] = cws
            run_scenario(cws, scenario, n)
        end
    catch e
        # A WS error on teardown (client severed the socket) is expected; anything
        # else is a genuine scenario bug worth surfacing.
        e isa HTTP.WebSockets.WebSocketError ||
            @warn "mock scenario failed" scenario exception = (e, catch_backtrace())
    end
    server_ws = take!(ws_ch)
    conn = ACP.Connection(ACP.WorkerTransport(Ref{Any}(server_ws)), handler)
    return Mock(conn, task, peer_ws, server, hold)
end

# Run the standard ACP setup handshake over a fresh Connection (initialize +
# session/new), returning the sessionId. Bounded timeout so a misbehaving mock
# can never hang the suite.
function do_setup(conn; timeout = 10.0)
    ACP.send_request(conn, "initialize",
                     Dict("protocolVersion" => 1), timeout)
    res = ACP.send_request(conn, "session/new",
                           Dict("cwd" => pwd(), "mcpServers" => []), timeout)
    return res["sessionId"]
end

# Collect the text of agent_message_chunk updates from a turn's update stream.
function drain_text(ch)
    texts = String[]
    for u in ch
        u isa ACP.AgentMessageChunk && u.content isa ACP.TextContent &&
            push!(texts, u.content.text)
    end
    return texts
end

@testset "AgentClientProtocol stability" begin

    # ── A1: concurrent register/respond never drops a pending entry ──────────
    # Many tasks each fire a send_request concurrently against a REAL agent that
    # echoes every id; with the lock around `pending`, every caller gets its
    # reply (an unlocked dict would drop entries under contention → take! hangs).
    @testset "A1 concurrent register/respond loses nothing" begin
        m = spawn_mock("echo_requests"); conn = m.conn
        try
            N = 200
            results = Vector{Any}(undef, N)
            @sync for i in 1:N
                @async begin
                    r = ACP.send_request(conn, "ping", Dict("n" => i))
                    results[i] = r["ok"]
                end
            end
            @test sort(Int.(results)) == collect(0:N-1)   # ids 0..N-1, none lost
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── A2: requests after teardown throw ConnectionClosed, never hang ───────
    @testset "A2 send_request after close throws ConnectionClosed" begin
        m = spawn_mock("setup_then_idle"); conn = m.conn
        try
            do_setup(conn)
            close(conn)
            @test timedwait(() -> conn.closed, 2.0) === :ok
            @test_throws ACP.ConnectionClosed ACP.send_request(conn, "ping", Dict())
            @test_throws ACP.ConnectionClosed ACP.request_updates(conn, "session/load", Dict())
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── A2/teardown: a pending request in flight is failed with ConnectionClosed
    @testset "A2 in-flight request fails with ConnectionClosed on teardown" begin
        # The agent completes setup, then SWALLOWS further requests (never
        # answers). A `ping` left in flight must be failed by teardown.
        m = spawn_mock("setup_then_swallow"); conn = m.conn
        try
            do_setup(conn)
            fut = @async ACP.send_request(conn, "ping", Dict())
            sleep(0.2)          # ensure it registered + the frame went out
            close(conn)
            cause = try
                fetch(fut); nothing
            catch e
                e isa TaskFailedException ? e.task.exception : e
            end
            @test cause isa ACP.ConnectionClosed
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── Concurrent prompts share ONE main stream ─────────────────────────────
    # claude-agent-acp supports a second `session/prompt` while one runs
    # (steering): it injects the new message into the live turn and, when the SDK
    # replays it, resolves the FIRST prompt and hands the stream to the second.
    #
    # There is nothing to route. Both prompts are spans over the session's main
    # thread, so everything the agent says arrives in wire order on one stream
    # and each response settles its own span. The mock streams a chunk for turn
    # 1, resolves turn 1, streams a chunk for turn 2, resolves turn 2 — over the
    # real wire — and we assert BOTH chunks land, in order, on the one stream.
    @testset "concurrent prompts share one main stream; each response settles" begin
        m = spawn_mock("concurrent_turns"); conn = m.conn
        try
            sid = do_setup(conn)
            client = ACP.Client(conn, sid, pwd())
            s1 = ACP.prompt_request(conn, Dict())
            s2 = ACP.prompt_request(conn, Dict())

            @test ACP.wait_turn!(s1)["stopReason"] == "end_turn"
            @test ACP.wait_turn!(s2)["stopReason"] == "end_turn"
            @test isempty(conn.active_prompts)

            # Both turns' text is on the ONE stream, in wire order — and as TWO
            # bubbles, because each span's end marker (stamped by the dispatcher
            # at its response frame) sealed the one before it. A single merged
            # bubble here would mean the boundary was drawn late.
            stop = ACP.flush_main!(client)          # our own marker: drain up to here
            texts = String[]
            drainer = @async for msg in client.messages
                if msg isa ACP.StreamFlush
                    ACP.signal_rendered!(msg)
                    msg === stop && break
                elseif msg isa ACP.AgentMessage
                    push!(texts, msg.text * join(collect(msg.updates)))
                end
            end
            @test timedwait(() -> istaskdone(drainer), 10.0) === :ok
            @test texts == ["for-turn-1", "for-turn-2"]
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    @testset "teardown fails every in-flight prompt" begin
        # The mock opens (reads) both prompts but never resolves them; teardown
        # must fail both responses and drop both spans.
        m = spawn_mock("two_turns_hang"); conn = m.conn
        try
            do_setup(conn)
            s1 = ACP.prompt_request(conn, Dict())
            s2 = ACP.prompt_request(conn, Dict())
            sleep(0.1)
            @test length(conn.active_prompts) == 2
            close(conn)
            @test take!(s1.response) isa ACP.ConnectionClosed
            @test take!(s2.response) isa ACP.ConnectionClosed
            @test isempty(conn.active_prompts)
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── A7: the update stream backpressures and never DROPS a distinct update ──
    # The mock floods 1000 DISTINCT text chunks ("u1".."u1000") through the turn
    # over the real wire while a consumer drains. Dropping any used to discard a
    # message and deadlock its consumer; with backpressure EVERY chunk arrives,
    # in order, none lost.
    @testset "A7 update stream backpressures, never drops" begin
        m = spawn_mock("flood_text"; n = 1000); conn = m.conn
        try
            do_setup(conn)
            u, r = ACP.request_updates(conn, "session/prompt", Dict())
            cons = @async drain_text(u)
            @test timedwait(() -> istaskdone(cons), 30.0) === :ok
            got = fetch(cons)
            @test length(got) == 1000                            # nothing dropped
            @test got == ["u$i" for i in 1:1000]                 # in order
            @test take!(r)["stopReason"] == "end_turn"
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)

        # deliver_update! robustness unit-checks (no transport involved — bare
        # channels against the now-closed `conn`):
        #   * a full channel BACKPRESSURES and loses nothing, cancel or not. It
        #     used to bail while a cancel was in flight so the dispatcher could
        #     reach the `cancelled` response without waiting for a slow browser;
        #     the skipped frames were discarded unparsed, which is how a stop
        #     could make the agent's output disappear for good.
        #   * a closed channel is a no-op, not an error.
        mk(i) = ACP.UnknownUpdate("u$i", Dict{String,Any}())
        full = Channel{ACP.SessionUpdate}(2)
        put!(full, mk(1)); put!(full, mk(2))          # full, no consumer
        blocked = @async ACP.deliver_update!(conn, full, mk(3))
        sleep(0.3)
        @test !istaskdone(blocked)                    # waits, does not discard
        @test Base.n_avail(full) == 2
        take!(full)                                   # make room
        @test timedwait(() -> istaskdone(blocked), 2.0) === :ok
        @test Base.n_avail(full) == 2                 # ...and mk(3) went in

        closed = Channel{ACP.SessionUpdate}(1); close(closed)
        @test ACP.deliver_update!(conn, closed, mk(1)) === nothing
    end

    # ── A7: tool-call snapshots — drop-oldest / latest-wins / never wedge ─────
    # BEHAVIORAL rewrite (no white-box `Base.n_avail`): the mock opens ONE tool
    # then floods N `tool_call_update`s mutating that SAME tool, ending with a
    # terminal `completed`. The session's main-stream coalescer folds these onto
    # one ToolCall whose per-message `updates` is the drop-oldest snapshot
    # channel. A deliberately SLOW consumer must (a) never wedge, and (b) still
    # observe the LATEST snapshot (status == "completed") — latest-wins, no
    # block, no deadlock.
    @testset "A7 tool snapshots: drop-oldest, latest-wins, never wedge" begin
        handler = ACP.FSRequestHandler(pwd())
        m = spawn_mock("flood_snapshots"; n = 2000, handler); conn = m.conn
        try
            sid = do_setup(conn)
            client = ACP.Client(conn, sid, pwd())

            final_status = Ref{String}("")
            tools_seen   = Ref(0)
            cons = @async for msg in client.messages
                if msg isa ACP.ToolCall
                    tools_seen[] += 1
                    last_status = msg.status
                    for snap in msg.updates
                        last_status = snap.status
                        sleep(0.0005)        # slow consumer → producer must drop-oldest
                    end
                    final_status[] = last_status
                elseif msg isa ACP.StreamFlush
                    ACP.signal_rendered!(msg)
                end
            end
            ACP.wait_turn!(ACP.prompt!(client, "go"))
            # The span's own end marker seals the turn; the slow consumer then
            # has to finish draining the tool before it reaches that marker.
            @test timedwait(() -> final_status[] == "completed", 30.0) === :ok
            @test tools_seen[] == 1                                 # never wedged
            close(client.updates)
            @test timedwait(() -> istaskdone(cons), 10.0) === :ok
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # A boundary must not kill a tool that is still running. `close(TurnState)`
    # force-fails every live tool, which is right at STREAM END and wrong at a
    # boundary — and boundaries land mid-stream all the time (the dispatcher
    # stamps one at every response, `begin_turn!` injects one before it
    # prompts). A long `bt_julia_eval` spanning one lost its entry in
    # `st.tools`, so every later update for it was dropped: the card sat at
    # `in_progress` with an empty CODE and OUTPUT while the eval kept running.
    @testset "a live tool survives a stream boundary" begin
        st  = ACP.TurnState()
        out = Channel{ACP.Message}(64)
        mk(d) = ACP.parse_session_update(Dict{String,Any}(d))

        ACP.parse_update!(out, st, mk(Dict(
            "sessionUpdate" => "tool_call", "toolCallId" => "eval-1",
            "kind" => "other", "title" => "bt_julia_eval", "status" => "in_progress",
            "rawInput" => Dict("code" => "1+1"))))
        tool = first(values(st.tools))
        ACP.parse_update!(out, st, mk(Dict("sessionUpdate" => "agent_message_chunk",
            "content" => Dict("type" => "text", "text" => "working"))))

        ACP.seal_message!(st)                       # what a boundary does
        @test st.current_message === nothing        # the bubble IS sealed
        @test haskey(st.tools, "eval-1")            # the tool is NOT

        # so its completion, which arrives after the boundary, still lands
        ACP.parse_update!(out, st, mk(Dict(
            "sessionUpdate" => "tool_call_update", "toolCallId" => "eval-1",
            "status" => "completed",
            "content" => [Dict("type" => "content",
                               "content" => Dict("type" => "text", "text" => "2"))])))
        @test tool.status == "completed"
        @test any(c -> c isa ACP.TextContent && c.text == "2", tool.content)

        # At true stream end an abandoned tool is still force-failed, so a tool
        # the agent never resolved cannot leave the UI pulsing forever.
        st2 = ACP.TurnState()
        ACP.parse_update!(out, st2, mk(Dict(
            "sessionUpdate" => "tool_call", "toolCallId" => "x",
            "kind" => "other", "title" => "t", "status" => "in_progress")))
        abandoned = first(values(st2.tools))
        close(st2)
        @test abandoned.status == "failed"
        @test isempty(st2.tools)
    end

    # ── A4: a stray blank frame does NOT tear the connection down ────────────
    # The mock emits blank frames around its frames; the real reader_loop must
    # skip them (not treat "" as EOF) and still deliver the response.
    @testset "A4 blank frame is skipped, not treated as EOF" begin
        m = spawn_mock("blank_line_then_answer"); conn = m.conn
        try
            r = ACP.send_request(conn, "ping", Dict(), 5.0)
            @test r["ok"] == true
            @test !conn.closed                    # blank frames didn't tear us down
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── A4b: a dead transport must terminate reader_loop, not hot-spin ────────
    # Over a REAL severed WebSocket: drop the agent's socket → the server-side
    # socket hits EOF → `WorkerTransport.transport_eof` is true → reader_loop
    # breaks promptly and the dispatcher drains. No livelock, scheduler not
    # starved. (The production analogue of the old "SIGKILL the subprocess".)
    @testset "A4b dead transport terminates reader_loop" begin
        m = spawn_mock("setup_then_idle"); conn = m.conn
        try
            do_setup(conn)
            @test peer_alive(m)
            kill_peer!(m)                         # sever the agent's WS → EOF
            @test timedwait(() -> istaskdone(conn.reader_task), 5.0) === :ok
            @test timedwait(() -> istaskdone(conn.dispatcher_task), 5.0) === :ok
        finally
            close(conn)
        end
        relay_close!(m)
    end

    # ── A3: a setup RPC error closes the connection (no leaked agent) ─────────
    # The mock returns a JSON-RPC error to `initialize`; `send_request` raises,
    # the caller closes the connection, and the agent task ends. This is exactly
    # the path `Client()` wraps in try/catch → close(conn) + rethrow.
    @testset "A3 setup RPC error closes the connection/transport" begin
        m = spawn_mock("setup_error"); conn = m.conn
        threw = false
        try
            ACP.send_request(conn, "initialize", Dict(), 5.0)
        catch e
            threw = true
            close(conn)                           # mirrors Client()'s catch
        end
        @test threw
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok   # agent ended
        close(conn)
        relay_close!(m)
    end

    # ── A3 (timeout): a wedged setup RPC times out instead of hanging ────────
    @testset "A3 setup RPC times out on a silent agent" begin
        m = spawn_mock("silent"); conn = m.conn
        try
            # The mock NEVER answers initialize. The timeout variant must raise
            # ConnectionClosed within the bounded window.
            @test_throws ACP.ConnectionClosed ACP.send_request(conn, "initialize", Dict(), 0.3)
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── A8: cancel! is a no-op when idle (no active turn) ────────────────────
    @testset "A8 cancel is a no-op when idle" begin
        m = spawn_mock("setup_then_idle"); conn = m.conn
        try
            sid = do_setup(conn)
            client = ACP.Client(conn, sid, pwd())
            @test ACP.cancel!(client) == false            # nothing to cancel
            @test ACP.session_activity(conn) isa ACP.Idle # ...and it stays idle
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # A cancel never mutes the session, whatever it was cancelling.
    #
    # There used to be a `cancelling` flag that made the dispatcher DROP
    # main-thread updates, so it could skip a cancelled prompt's backlog and
    # reach that prompt's `cancelled` response. It was cleared only by that
    # response — so cancelling UN-PROMPTED work (an auto-wake episode, a
    # background subagent), which has no response of ours coming, latched it
    # forever and every later frame was discarded unparsed. The agent kept
    # working and streaming while the client binned all of it; the chat looked
    # dead until a reload, whose `session/load` replayed the backlog at once.
    @testset "a cancel never mutes the session" begin
        m = spawn_mock("setup_then_idle"); conn = m.conn
        try
            sid    = do_setup(conn)
            client = ACP.Client(conn, sid, pwd())

            # No prompt of ours is open; the agent is working on its own.
            @atomic conn.last_work_at = time()
            @atomic conn.activity = ACP.Unprompted()
            @test ACP.session_live(client) == true
            @test ACP.cancel!(client) == true            # the cancel DOES go out
            # No prompt to settle, so it does not sit in `Cancelling`; and the
            # cancel consumes the work recency it acted on, so it lands on
            # `Idle` rather than re-reporting itself live for the quiet window.
            @test ACP.session_activity(conn) isa ACP.Idle

            put!(client.updates, ACP.AgentMessageChunk(ACP.TextContent("still working")))
            @test timedwait(() -> Base.n_avail(client.messages) >= 1, 5.0) === :ok
            msg = take!(client.messages)
            @test msg isa ACP.AgentMessage && msg.text == "still working"

            # With a prompt of ours open, the cancel is a STATE, and the frames
            # behind it still arrive — that is the whole change. Asserted on the
            # DELIVERED TEXT: consecutive chunks coalesce onto the open bubble,
            # so the message count would not grow even when nothing is dropped.
            span = ACP.PromptSpan(9992)
            lock(() -> push!(conn.active_prompts, span), conn.lock)
            @test ACP.cancel!(client) == true
            @test ACP.session_activity(conn) isa ACP.Cancelling
            put!(client.updates, ACP.AgentMessageChunk(ACP.TextContent("backlog")))
            @test timedwait(() -> isready(msg.updates), 5.0) === :ok
            @test take!(msg.updates) == "backlog"
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── Subagent tagging: `_meta.claudeCode.parentToolUseId` ─────────────────
    # claude-agent-acp forwards every SUBAGENT session/update (its text chunks,
    # tool_calls, tool_call_updates) tagged with the parent Task's tool_use id.
    # The parser must surface the tag; the per-turn coalescer must divert such
    # updates OUT of the main message stream (they'd otherwise interleave
    # subagent prose into the top-level reply) and hand them to the turn's
    # `on_subagent` sink — or drop them when no sink is installed.
    @testset "parentToolUseId extraction (present / absent / malformed)" begin
        chunk(meta...) = merge(
            Dict{String,Any}("sessionUpdate" => "agent_message_chunk",
                             "content" => Dict("type" => "text", "text" => "hi")),
            Dict{String,Any}(meta...))

        # Present: parse wraps the typed update in SubagentUpdate.
        u = ACP.parse_session_update(chunk(
            "_meta" => Dict("claudeCode" => Dict("parentToolUseId" => "task-1"))))
        @test u isa ACP.SubagentUpdate
        @test ACP.parent_tool_use_id(u) == "task-1"
        @test u.update isa ACP.AgentMessageChunk
        @test u.update.content.text == "hi"

        # Absent: plain typed update, accessor says nothing.
        u = ACP.parse_session_update(chunk())
        @test u isa ACP.AgentMessageChunk
        @test ACP.parent_tool_use_id(u) === nothing

        # Malformed envelopes at every level must not throw and not tag.
        for meta in (Dict("_meta" => "nope"),
                     Dict("_meta" => Dict("claudeCode" => 42)),
                     Dict("_meta" => Dict("claudeCode" => Dict())),
                     Dict("_meta" => Dict("claudeCode" =>
                          Dict("parentToolUseId" => 7))),
                     Dict("_meta" => Dict("claudeCode" =>
                          Dict("parentToolUseId" => ""))))
            u = ACP.parse_session_update(chunk(meta...))
            @test u isa ACP.AgentMessageChunk
            @test ACP.parent_tool_use_id(u) === nothing
        end

        # A subagent tool_call keeps its claudeCode.toolName alongside the tag.
        u = ACP.parse_session_update(Dict{String,Any}(
            "sessionUpdate" => "tool_call",
            "toolCallId" => "sub-1", "kind" => "search",
            "title" => "Grep foo", "status" => "in_progress",
            "_meta" => Dict("claudeCode" => Dict(
                "toolName" => "Grep", "parentToolUseId" => "task-1"))))
        @test u isa ACP.SubagentUpdate
        @test ACP.parent_tool_use_id(u) == "task-1"
        @test u.update isa ACP.ToolCallNotif
        @test u.update.tool_name == "Grep"
    end

    # A subagent's updates never enter the main thread's stream: the dispatcher
    # reads `parentToolUseId` FIRST and hands the update to its owner. Driven
    # through `dispatch_message`, which is where that decision lives.
    @testset "subagent updates are addressed to their owner, not the main stream" begin
        # A real Connection over the real WS relay; the mock is quiet after
        # setup, so every frame below is one we hand the dispatcher directly.
        # `session/update` never touches the wire — this exercises the addressing
        # decision itself, which is what the test is about.
        m = spawn_mock("two_turns_hang"); conn = m.conn
        do_setup(conn)
        sleep(0.2)                                 # let setup's own updates settle
        main  = ACP.SessionUpdate[]
        owned = Tuple{String,ACP.SessionUpdate}[]
        conn.on_main_update  = u -> push!(main, u)
        conn.on_owner_update = (owner, u) -> push!(owned, (owner, u))

        tagged(inner) = Dict{String,Any}("jsonrpc" => "2.0", "method" => "session/update",
            "params" => Dict{String,Any}("update" => merge(inner, Dict{String,Any}(
                "_meta" => Dict("claudeCode" => Dict("parentToolUseId" => "task-1"))))))
        plain(inner) = Dict{String,Any}("jsonrpc" => "2.0", "method" => "session/update",
            "params" => Dict{String,Any}("update" => inner))
        chunk(t) = Dict{String,Any}("sessionUpdate" => "agent_message_chunk",
            "content" => Dict("type" => "text", "text" => t))
        tcall(id, title, status) = Dict{String,Any}("sessionUpdate" => "tool_call",
            "toolCallId" => id, "kind" => "search", "title" => title, "status" => status)

        ACP.dispatch_message(conn, plain(chunk("main ")))
        ACP.dispatch_message(conn, tagged(chunk("sub prose")))
        ACP.dispatch_message(conn, tagged(tcall("sub-t1", "Grep foo", "in_progress")))
        ACP.dispatch_message(conn, tagged(Dict{String,Any}(
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "sub-t1", "status" => "completed")))
        ACP.dispatch_message(conn, plain(chunk("still main")))

        # The main thread saw only its own two chunks — no subagent prose, no
        # subagent tool. Interleaving those is the failure this addressing removes.
        @test length(main) == 2
        @test all(u -> u isa ACP.AgentMessageChunk, main)
        @test [ACP.text_of(u) for u in main] == ["main ", "still main"]

        # The subagent got its whole stream, tagged with its own id.
        @test length(owned) == 3
        @test all(((o, _),) -> o == "task-1", owned)

        # ... and distils into feed activity, which is what its owner renders.
        acts = [ACP.subagent_activity(o, u) for (o, u) in owned]
        @test acts[1].kind === :text && acts[1].label == "sub prose"
        @test acts[2].kind === :tool && acts[2].tool_id == "sub-t1" &&
              acts[2].label == "Grep foo" && acts[2].status == "in_progress"
        @test acts[3].kind === :tool && acts[3].status == "completed"

        # An UNTAGGED frame for a tool a subagent already claimed is still that
        # subagent's. claude-agent-acp does not tag every frame — captured live,
        # a subagent bash goes tagged → UNTAGGED (the toolResponse frame) →
        # tagged — and addressing on the tag alone hands the middle one to the
        # main thread, whose coalescer has never heard of the tool id and drops
        # it. The id is recoverable, so it is recovered.
        ACP.dispatch_message(conn, tagged(tcall("sub-t2", "Bash sleep", "pending")))
        ACP.dispatch_message(conn, plain(Dict{String,Any}(
            "sessionUpdate" => "tool_call_update", "toolCallId" => "sub-t2",
            "_meta" => Dict("claudeCode" => Dict("toolName" => "Bash",
                "toolResponse" => Dict("stdout" => "hi"))))))
        @test length(main) == 2                        # NOT the main thread's
        @test last(owned)[1] == "task-1"               # ... it went to the subagent
        @test ACP.tool_call_id(last(owned)[2]) == "sub-t2"

        # A tool id we have never seen tagged belongs to the main thread, and
        # stays there — recovery only ever re-unites frames with an owner the
        # wire already named.
        ACP.dispatch_message(conn, plain(Dict{String,Any}(
            "sessionUpdate" => "tool_call_update", "toolCallId" => "main-only",
            "status" => "completed")))
        @test length(main) == 3
        @test length(owned) == 5

        # The association is forgotten once the tool is terminal, so a long
        # session cannot accumulate them.
        ACP.dispatch_message(conn, plain(Dict{String,Any}(
            "sessionUpdate" => "tool_call_update", "toolCallId" => "sub-t2",
            "status" => "completed")))
        @test last(owned)[1] == "task-1"               # the terminal frame still lands
        @test !haskey(conn.tool_owners, "sub-t2")      # ... and then it is dropped

        # A cancel in flight silences NEITHER stream. The main thread's frames
        # are output the agent already produced, and the subagent was never
        # cancelled at all — it is addressed by `parentToolUseId` and reaches
        # its owner without consulting session state.
        @atomic conn.activity = ACP.Cancelling()
        ACP.dispatch_message(conn, plain(chunk("still rendered")))
        ACP.dispatch_message(conn, tagged(chunk("still mine")))
        @test length(main)  == 4
        @test length(owned) == 7
        close(conn)
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end

    # ── Regression: a long resumed history with an un-terminated tool must not
    # deadlock replay collection. Over the real wire: on `session/load` the mock
    # streams an un-terminated tool ("open", pending, never completed) followed
    # by > BUF further completed tools, then resolves the load. Concurrent
    # per-message draining + close(TurnState) at stream end means the open tool
    # can't wedge the >BUF history collection.
    @testset "replay survives an un-terminated tool in a >BUF history" begin
        m = spawn_mock("replay_history"; n = ACP.BUF + 50); conn = m.conn
        try
            do_setup(conn)
            res = @async ACP.replay_history(conn,
                Dict("sessionId" => "s", "cwd" => pwd(), "mcpServers" => []))
            @test timedwait(() -> istaskdone(res), 25.0) === :ok      # must NOT hang
            msgs, _ = fetch(res)
            @test length(msgs) == ACP.BUF + 51            # open tool + every follower
        finally
            close(conn)
        end
        @test timedwait(() -> !peer_alive(m), 5.0) === :ok
        relay_close!(m)
    end
end

# ── Non-claude agents: MCP tool identity + arguments ─────────────────────────
# Replays the REAL frames `kimi acp` 0.29.2 emitted while driving the real
# btworker MCP server (captured verbatim into test/fixtures). A non-claude agent
# ships no `_meta.claudeCode` envelope and no `rawInput` at all: it names the
# tool in the ACP `title` and streams the ARGUMENTS as growing content text.
# Parsed naively that yields a nameless `GenericTool` whose "output" is
# half-typed argument JSON — the same tool rendering completely differently
# depending on which agent ran it, with an empty code preview.
@testset "MCP tool call from a non-claude agent (real kimi wire)" begin
    frames = [JSON.parse(l) for l in
              readlines(joinpath(@__DIR__, "fixtures", "kimi_mcp_tool_call.jsonl"))]
    @test !isempty(frames)
    # The fixture must stay a genuine non-claude capture, or it stops guarding
    # anything: NO `_meta` envelope anywhere, so the tool is identifiable only
    # through its title. `rawInput` shows up on exactly one late frame (the one
    # that completes the argument stream), so it cannot name the tool either —
    # every earlier frame has to be routed on the title alone.
    @test !any(f -> haskey(f, "_meta"), frames)
    @test count(f -> haskey(f, "rawInput"), frames) == 1
    @test !haskey(frames[1], "rawInput")

    out = Channel{Any}(256)
    st  = ACP.TurnState()
    for f in frames
        ACP.parse_update!(out, st, ACP.parse_session_update(f))
    end
    close(st); close(out)
    tools = [x for x in collect(out) if x isa ACP.ToolCall]
    @test length(tools) == 1
    tc = tools[1]

    # Identity recovered from the title → the typed MCP path, not GenericTool.
    @test tc isa ACP.MCPCall
    @test tc.server == "btworker"
    @test tc.tool_name == "bt_julia_eval"
    # Arguments recovered from the streamed content → a filled code preview.
    @test tc.raw_input["code"] == "1+1"
    @test tc.raw_input["env_path"] == "/tmp/kimiprobe"
    # …and the streamed argument JSON never leaks into the content the UI shows
    # as output: only the tool's real result survives.
    @test tc.status == "completed"
    @test [c.text for c in tc.content if c isa ACP.TextContent] == ["2"]
end

# Native (non-MCP) tools from the same agent. Kimi labels them with Claude's own
# names — `Read`, `Bash`, `Agent` — but only on the OPENING frame: a later frame
# replaces the title with a sentence ("Running: echo …"). Without reading that
# opening title a shell call has no command to show and a delegation has no Task
# card, which is what "it used something else instead of subagents" looks like.
@testset "native tool calls from a non-claude agent (real kimi wire)" begin
    frames = [JSON.parse(l) for l in
              readlines(joinpath(@__DIR__, "fixtures", "kimi_native_tools.jsonl"))]
    @test !any(f -> haskey(f, "_meta"), frames)      # still a genuine non-claude capture

    out = Channel{Any}(1024)
    st  = ACP.TurnState()
    for f in frames
        ACP.parse_update!(out, st, ACP.parse_session_update(f))
    end
    close(st); close(out)
    tools = [x for x in collect(out) if x isa ACP.ToolCall]
    @test length(tools) == 3
    rd, sh, ag = tools

    @test rd isa ACP.GenericTool && rd.name == "Read" && rd.kind == "read"
    @test rd.raw_input["path"] == "hello.txt"

    # The shell call is the one that was landing as a nameless generic pill.
    @test sh isa ACP.BashCall
    @test sh.command == "echo NATIVEPROBE"
    @test !sh.run_in_background

    # Delegation: a real Task call, with the sub-prompt it dispatched.
    @test ag isa ACP.TaskCall
    @test ag.description == "Count lines in hello.txt"
    @test occursin("hello.txt", ag.prompt)

    # None of the half-typed argument JSON that streams through `content` may
    # survive as the tool's output.
    for t in tools
        for c in t.content
            c isa ACP.TextContent || continue
            @test !startswith(lstrip(c.text), "{\"")
        end
    end
    @test occursin("NATIVEPROBE", sh.content[end].text)
end

# The claude path must be entirely unaffected by the two fallbacks above: it
# names tools through `_meta` and sends `rawInput`, so a content frame stays
# content even when it happens to look like a JSON object.
@testset "claude-shaped MCP frames keep _meta/rawInput semantics" begin
    id = "toolu_1"
    call = Dict("sessionUpdate" => "tool_call", "toolCallId" => id,
                "title" => "Run julia code",
                "kind" => "other", "status" => "pending", "content" => [],
                "_meta" => Dict("claudeCode" => Dict("toolName" => "mcp__btworker__bt_julia_eval")),
                "rawInput" => Dict("code" => "2+2", "env_path" => "/tmp/x"))
    # A JSON-object-shaped OUTPUT chunk mid-flight must still be treated as
    # content — the arguments are already known, so the recovery stays dormant.
    mid  = Dict("sessionUpdate" => "tool_call_update", "toolCallId" => id,
                "status" => "in_progress",
                "content" => [Dict("type" => "content",
                                   "content" => Dict("type" => "text",
                                                     "text" => "{\"partial\":true}"))])
    fin  = Dict("sessionUpdate" => "tool_call_update", "toolCallId" => id,
                "status" => "completed",
                "content" => [Dict("type" => "content",
                                   "content" => Dict("type" => "text", "text" => "4"))])
    out = Channel{Any}(64)
    st  = ACP.TurnState()
    for f in (call, mid, fin)
        ACP.parse_update!(out, st, ACP.parse_session_update(f))
    end
    close(st); close(out)
    tc = only([x for x in collect(out) if x isa ACP.ToolCall])
    @test tc isa ACP.MCPCall
    @test tc.tool_name == "bt_julia_eval"
    @test tc.raw_input["code"] == "2+2"        # from rawInput, not from content
    @test tc.content[end].text == "4"
end

# The title fallback is narrow on purpose: only the canonical MCP form counts,
# so a human-readable title can never be mistaken for a tool name.
@testset "title fallback accepts only mcp__server__tool" begin
    @test ACP.is_mcp_tool_name("mcp__btworker__bt_julia_eval")
    @test !ACP.is_mcp_tool_name("Run julia code")
    @test !ACP.is_mcp_tool_name("mcp__btworker__")      # empty tool
    @test !ACP.is_mcp_tool_name("mcp____bt_julia_eval") # empty server
    @test !ACP.is_mcp_tool_name("mcp__btworker")        # no separator
    @test !ACP.is_mcp_tool_name("")
end

# A tool NAME is one token; every human title kimi emitted has a space in it.
@testset "bare-name titles are told apart from human titles" begin
    for name in ("Read", "Bash", "Agent", "TodoWrite", "mcp__btworker__bt_julia_eval")
        @test ACP.looks_like_tool_name(name)
    end
    for title in ("Reading hello.txt", "Running: echo NATIVEPROBE",
                  "Launching explore agent: Count lines", "", " ")
        @test !ACP.looks_like_tool_name(title)
    end

    # …and a mutated title on a LATER frame must not overwrite the name the
    # opening frame established, or a completed Bash would lose its identity.
    open_frame = Dict("sessionUpdate" => "tool_call", "toolCallId" => "t1",
                      "title" => "Bash", "kind" => "execute", "status" => "pending",
                      "content" => [])
    later      = Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "t1",
                      "title" => "Running: echo hi", "status" => "in_progress",
                      "content" => [])
    @test ACP.parse_session_update(open_frame).tool_name == "Bash"
    @test ACP.parse_session_update(later).tool_name === nothing
end

# Cancelling work the agent streams outside any request (the counterpart to
# "A8 cancel is a no-op when idle" above: idle must stay a no-op, but
# unregistered-and-working must not).
include(joinpath(@__DIR__, "orphan_cancel_test.jl"))
