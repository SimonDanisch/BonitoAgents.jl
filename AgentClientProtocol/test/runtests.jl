using AgentClientProtocol
using Test

const ACP = AgentClientProtocol

# ── Real-subprocess mock agent ────────────────────────────────────────────────
# The ONLY fake here is a real-spawned mock AGENT process: a tiny Julia script
# that speaks ACP JSON-RPC over stdio (test/mocks/acp_mock_agent.jl). There is
# NO fake Transport — every testset drives the genuine `ACP.SubprocessTransport`
# / `ACP.Connection` (real reader_loop/dispatcher) and the mock's behavior is
# selected per-test via the `ACP_MOCK_SCENARIO` env var. See the script for the
# scenario list.
const MOCK_AGENT = joinpath(@__DIR__, "mocks", "acp_mock_agent.jl")
const JULIA_BIN  = Base.julia_cmd()[1]

# Spawn the mock under a scenario and wrap it in a real Connection. `n` is an
# integer knob a scenario reads (e.g. flood count). The caller MUST `close(conn)`
# in a `finally` — that closes stdin, SIGTERMs, then SIGKILLs the subprocess, so
# nothing leaks.
function spawn_mock(scenario::AbstractString; n::Integer = 0,
                    handler::ACP.Handler = ACP.DiscardHandler())
    env = merge(Dict(k => v for (k, v) in ENV),
                Dict("ACP_MOCK_SCENARIO" => scenario,
                     "ACP_MOCK_N"        => string(n)))
    proc = open(Cmd(`$JULIA_BIN --startup-file=no $MOCK_AGENT`; env), "r+")
    conn = ACP.Connection(proc, handler)
    return proc, conn
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
        proc, conn = spawn_mock("echo_requests")
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
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A2: requests after teardown throw ConnectionClosed, never hang ───────
    @testset "A2 send_request after close throws ConnectionClosed" begin
        proc, conn = spawn_mock("setup_then_idle")
        try
            do_setup(conn)
            close(conn)
            @test timedwait(() -> conn.closed, 2.0) === :ok
            @test_throws ACP.ConnectionClosed ACP.send_request(conn, "ping", Dict())
            @test_throws ACP.ConnectionClosed ACP.request_updates(conn, "session/load", Dict())
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A2/teardown: a pending request in flight is failed with ConnectionClosed
    @testset "A2 in-flight request fails with ConnectionClosed on teardown" begin
        # The agent completes setup, then SWALLOWS further requests (never
        # answers). A `ping` left in flight must be failed by teardown.
        proc, conn = spawn_mock("setup_then_swallow")
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
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A8: concurrent turns route updates oldest-first + handoff on response ──
    # claude-agent-acp supports a second `session/prompt` while one runs
    # (steering). Updates route to the OLDEST unresolved prompt; a prompt's
    # response closes ITS stream and updates flow to the next. The mock streams
    # one chunk for turn 1, resolves turn 1, streams one chunk for turn 2,
    # resolves turn 2 — all over the real wire.
    @testset "concurrent turns route updates oldest-first, handoff on response" begin
        proc, conn = spawn_mock("concurrent_turns")
        try
            do_setup(conn)
            u1, r1 = ACP.request_updates(conn, "session/prompt", Dict())
            u2, r2 = ACP.request_updates(conn, "session/prompt", Dict())

            # Drain both streams concurrently: each closes when ITS response lands.
            t1 = @async drain_text(u1)
            t2 = @async drain_text(u2)
            @test timedwait(() -> istaskdone(t1) && istaskdone(t2), 10.0) === :ok
            @test fetch(t1) == ["for-turn-1"]            # u1 closed by id1's response
            @test fetch(t2) == ["for-turn-2"]            # turn 1 gone → routed to 2
            @test take!(r1)["stopReason"] == "end_turn"
            @test take!(r2)["stopReason"] == "end_turn"
            @test isempty(conn.active_turns)
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    @testset "teardown closes every in-flight turn" begin
        # The mock opens (reads) both prompts but never resolves them; teardown
        # must close both update streams and fail both responses.
        proc, conn = spawn_mock("two_turns_hang")
        try
            do_setup(conn)
            u1, r1 = ACP.request_updates(conn, "session/prompt", Dict())
            u2, r2 = ACP.request_updates(conn, "session/prompt", Dict())
            sleep(0.1)
            close(conn)
            @test timedwait(() -> !isopen(u1) && !isopen(u2), 5.0) === :ok
            @test take!(r1) isa ACP.ConnectionClosed
            @test take!(r2) isa ACP.ConnectionClosed
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A7: the update stream backpressures and never DROPS a distinct update ──
    # The mock floods 1000 DISTINCT text chunks ("u1".."u1000") through the turn
    # over the real wire while a consumer drains. Dropping any used to discard a
    # message and deadlock its consumer; with backpressure EVERY chunk arrives,
    # in order, none lost.
    @testset "A7 update stream backpressures, never drops" begin
        proc, conn = spawn_mock("flood_text"; n = 1000)
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
        @test timedwait(() -> !process_running(proc), 5.0) === :ok

        # deliver_update! robustness unit-checks (no transport involved — these
        # construct bare channels to assert the two non-flood invariants):
        #   * a cancel in flight must NOT block on a full channel, so the single
        #     dispatcher stays free to reach the turn's `cancelled` response;
        #   * a closed channel is a no-op, not an error.
        mk(i) = ACP.UnknownUpdate("u$i", Dict{String,Any}())
        full = Channel{ACP.SessionUpdate}(2)
        put!(full, mk(1)); put!(full, mk(2))          # full, no consumer
        @atomic conn.cancelling = true
        cancel_task = @async ACP.deliver_update!(conn, full, mk(3))
        @test timedwait(() -> istaskdone(cancel_task), 2.0) === :ok

        closed = Channel{ACP.SessionUpdate}(1); close(closed)
        @test ACP.deliver_update!(conn, closed, mk(1)) === nothing
    end

    # ── A7: tool-call snapshots — drop-oldest / latest-wins / never wedge ─────
    # BEHAVIORAL rewrite (no white-box `Base.n_avail`): the mock opens ONE tool
    # then floods N `tool_call_update`s mutating that SAME tool, ending with a
    # terminal `completed`. The real `prompt!` consumer coalesces these onto one
    # ToolCall whose per-message `updates` is the drop-oldest snapshot channel.
    # A deliberately SLOW consumer must (a) never wedge, and (b) still observe the
    # LATEST snapshot (status == "completed") — latest-wins, no block, no deadlock.
    @testset "A7 tool snapshots: drop-oldest, latest-wins, never wedge" begin
        handler = ACP.FSRequestHandler(pwd())
        proc, conn = spawn_mock("flood_snapshots"; n = 2000, handler)
        try
            sid = do_setup(conn)
            client = ACP.Client(conn, sid, pwd())
            messages = ACP.prompt!(client, "go")

            final_status = Ref{String}("")
            tools_seen   = Ref(0)
            cons = @async for m in messages
                if m isa ACP.ToolCall
                    tools_seen[] += 1
                    last_status = m.status
                    for snap in m.updates
                        last_status = snap.status
                        sleep(0.0005)        # slow consumer → producer must drop-oldest
                    end
                    final_status[] = last_status
                end
            end
            @test timedwait(() -> istaskdone(cons), 30.0) === :ok   # never wedged
            @test tools_seen[] == 1
            @test final_status[] == "completed"                     # latest-wins
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A4: a stray blank line does NOT tear the connection down ─────────────
    # The mock emits blank lines around its frames; the real reader_loop must
    # skip them (not treat "" as EOF) and still deliver the response.
    @testset "A4 blank line is skipped, not treated as EOF" begin
        proc, conn = spawn_mock("blank_line_then_answer")
        try
            r = ACP.send_request(conn, "ping", Dict(), 5.0)
            @test r["ok"] == true
            @test !conn.closed                    # blank lines didn't tear us down
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A4b: a dead transport must terminate reader_loop, not hot-spin ────────
    # Over a REAL killed subprocess: SIGKILL the mock → its stdout hits EOF →
    # SubprocessTransport reports EOF → reader_loop breaks promptly and the
    # dispatcher drains. No livelock, scheduler not starved.
    @testset "A4b dead subprocess terminates reader_loop" begin
        proc, conn = spawn_mock("setup_then_idle")
        try
            do_setup(conn)
            @test process_running(proc)
            kill(proc, Base.SIGKILL)              # real subprocess death → EOF
            @test timedwait(() -> istaskdone(conn.reader_task), 5.0) === :ok
            @test timedwait(() -> istaskdone(conn.dispatcher_task), 5.0) === :ok
        finally
            close(conn)
        end
    end

    # ── A3: a setup RPC error closes the connection (no leaked process) ───────
    # The mock returns a JSON-RPC error to `initialize`; `send_request` raises,
    # the caller closes the connection, and the subprocess is reaped. This is
    # exactly the path `Client()` wraps in try/catch → close(conn) + rethrow.
    @testset "A3 setup RPC error closes the connection/transport" begin
        proc, conn = spawn_mock("setup_error")
        threw = false
        try
            ACP.send_request(conn, "initialize", Dict(), 5.0)
        catch e
            threw = true
            close(conn)                           # mirrors Client()'s catch
        end
        @test threw
        @test timedwait(() -> !process_running(proc), 5.0) === :ok   # reaped
        close(conn)
    end

    # ── A3 (timeout): a wedged setup RPC times out instead of hanging ────────
    @testset "A3 setup RPC times out on a silent agent" begin
        proc, conn = spawn_mock("silent")
        try
            # The mock NEVER answers initialize. The timeout variant must raise
            # ConnectionClosed within the bounded window.
            @test_throws ACP.ConnectionClosed ACP.send_request(conn, "initialize", Dict(), 0.3)
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── A8: cancel! is a no-op when idle (no active turn) ────────────────────
    @testset "A8 cancel is a no-op when idle" begin
        proc, conn = spawn_mock("setup_then_idle")
        try
            sid = do_setup(conn)
            client = ACP.Client(conn, sid, pwd())
            ACP.cancel!(client)
            @test !(@atomic conn.cancelling)      # not latched → next turn renders
        finally
            close(conn)
        end
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end

    # ── Regression: a long resumed history with an un-terminated tool must not
    # deadlock replay collection. Over the real wire: on `session/load` the mock
    # streams an un-terminated tool ("open", pending, never completed) followed
    # by > BUF further completed tools, then resolves the load. Concurrent
    # per-message draining + close(TurnState) at stream end means the open tool
    # can't wedge the >BUF history collection.
    @testset "replay survives an un-terminated tool in a >BUF history" begin
        proc, conn = spawn_mock("replay_history"; n = ACP.BUF + 50)
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
        @test timedwait(() -> !process_running(proc), 5.0) === :ok
    end
end
