# Regression for the `stop_session!` → 100% CPU livelock (close-chat freeze)
# AND the old `LocalTransport` shared-inner clobber — re-expressed against the
# first-class-agent model.
#
# Root cause (livelock): teardown must close the ACP CONNECTION (`close(client)`
# → `close(conn)`), which sets `conn.closed = true` BEFORE closing the socket so
# the reader loop exits on its `while !conn.closed` guard. Closing only the
# transport left `conn.closed == false`; a worker WS's `recv` then returned ""
# on close without unblocking the guard, and — without a `transport_eof` method —
# `reader_loop` `continue`d forever, hot-spinning its sticky (`@async`, thread-1)
# task and starving every other server task.
#
# What changed in the model: `LocalTransport` and `MockTransport` are DELETED.
# Local/mock sessions now spawn a real `ACP.SubprocessTransport` (each `BinAgent`
# owns its own subprocess), and the worker path uses the slimmed
# `WorkerTransport` (a `ws` Ref). So:
#   1. `transport_eof(::WorkerTransport)` — never-dialed + closed-ws cases (kept).
#   2. `transport_eof(::SubprocessTransport)` — the BinAgent local path: a live
#      agent (stdout open, frames pending) is NOT EOF; an exited / killed agent
#      IS. This is what stops the reader loop hot-spinning on the local path.
#   3. `WorkerTransport.recv` still surfaces ABNORMAL closes (doesn't masquerade
#      them as clean EOF).
#   4. `close(conn)` tears down the reader loop (the `stop_session!` path).
#   5. The old `LocalTransport` "shared-inner clobber" is GONE BY CONSTRUCTION —
#      each agent owns its own subprocess, so a fresh `start!` can never clobber
#      a sibling's session. We assert the POSITIVE invariant instead: rapid
#      `start!`/`stop!` and `restart_chat_session!` cycles on a real MockAgent
#      never fail and leak no subprocess.

using Test
using BonitoAgents
import HTTP
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
const WSK = HTTP.WebSockets

newstate_eof() = BT.ServerState(; state_dir   = mktempdir(),
                                  working_dir = mktempdir(),
                                  worker_secret = "x")

# Stand up a one-shot loopback WS server and hand a live client socket to `f`.
# `server` runs in the accept handler (so it can close cleanly/abnormally).
function with_ws_pair(f, server)
    port = rand(20000:40000)
    srv = WSK.listen!("127.0.0.1", port) do ws
        try; server(ws); catch; end
    end
    try
        WSK.open("ws://127.0.0.1:$port") do client
            f(client)
        end
    finally
        close(srv)
    end
end

# Count live mock subprocesses (pgrep exits 1 ⇒ none → 0).
mock_proc_count() =
    try parse(Int, strip(read(`pgrep -fc mock_claude_agent_acp.jl`, String))) catch; 0 end

@testset "transport_eof on dead/undialed transports" begin

    @testset "WorkerTransport: never-dialed ws is EOF" begin
        t = BT.WorkerTransport()                 # ws Ref starts nothing
        @test t.ws[] === nothing
        @test ACP.transport_eof(t) == true       # ws nothing → no more frames → EOF
    end

    @testset "WorkerTransport: closed ws is EOF" begin
        # A real HTTP WebSocket pair, then close one side: `isclosed` flips true,
        # `recv` returns "" instantly, and `transport_eof` must agree so the
        # reader loop terminates instead of hot-spinning on the closed socket.
        t = BT.WorkerTransport()
        with_ws_pair(ws -> (for _ in ws; end)) do client_ws   # server holds open
            t.ws[] = client_ws
            @test ACP.transport_eof(t) == false   # live ws is not EOF
            close(client_ws)
            @test ACP.transport_eof(t) == true    # closed ws → EOF
        end
    end

    @testset "SubprocessTransport (BinAgent local path): live vs dead" begin
        # The local/mock path now spawns a real SubprocessTransport. A live agent
        # whose stdout has a frame pending is NOT EOF (the reader loop must keep
        # reading); an exited or killed agent IS EOF (the loop must terminate
        # instead of hot-spinning on its stdout). NB: don't call `transport_eof`
        # on a transport whose stdout is being concurrently drained by a live
        # reader loop — `eof(proc.out)` blocks there; these procs are unread.

        # Live: a buffered line keeps the read pipe non-empty while the proc lives.
        live = open(`sh -c "echo hi; sleep 5"`, "r+")
        st_live = ACP.SubprocessTransport(live)
        sleep(0.2)
        @test ACP.transport_eof(st_live) == false   # pending frame → not EOF

        # Exited: /bin/true returns immediately → stdout EOF + process gone.
        gone = open(`/bin/true`, "r+")
        st_gone = ACP.SubprocessTransport(gone)
        sleep(0.2)
        @test ACP.transport_eof(st_gone) == true

        # Killed: close() (stdin EOF, then kill) ends the live one → EOF.
        close(st_live)
        sleep(0.2)
        @test ACP.transport_eof(st_live) == true
        close(st_gone)
    end
end

@testset "WorkerTransport.recv does not swallow abnormal closes" begin
    # `recv`'s contract: "" on a CLEAN end-of-stream, throw on a real failure.
    # The reader must be BLOCKED in `recv` when the close lands (as in the real
    # `reader_loop`), so the close is processed by the in-flight `receive` rather
    # than the `isclosed` fast path.
    function recv_when(action::Symbol)
        t = BT.WorkerTransport()
        out = Ref{Any}(:none)
        with_ws_pair(ws -> (sleep(0.15); action === :clean ? close(ws) :
                            close(ws, WSK.CloseFrameBody(1011, "boom")))) do client
            t.ws[] = client
            try
                out[] = (:returned, ACP.recv(t))      # blocks until the close arrives
            catch e
                out[] = (:threw, e)
            end
        end
        return out[]
    end

    clean = recv_when(:clean)
    @test clean[1] === :returned && clean[2] == ""      # clean close → EOF sentinel

    abn = recv_when(:abnormal)
    @test abn[1] === :threw                              # abnormal close → surfaced
    @test abn[2] isa WSK.WebSocketError && !WSK.isok(abn[2])
end

@testset "close(conn) tears down the reader loop (the stop_session! path)" begin
    # `stop_session!`/`stop!` now close the ACP connection (`close(client)` →
    # `close(conn)`), NOT the bare transport. `close(conn)` sets `conn.closed`
    # first, so the reader loop — even one parked in a live `receive` — exits on
    # its guard without hot-spinning. This is the exact mechanism that fixes the
    # close-chat freeze.
    t = BT.WorkerTransport()
    with_ws_pair(ws -> (for _ in ws; end)) do client     # server holds open
        t.ws[] = client
        conn = ACP.Connection(t)                         # reader_loop parks in receive()
        sleep(0.1)
        @test !istaskdone(conn.reader_task)              # genuinely parked, not spinning
        close(conn)                                      # ← what close(client) calls
        t0 = time()
        while !istaskdone(conn.reader_task) && time() - t0 < 2.0; sleep(0.01); end
        @test conn.closed == true
        @test istaskdone(conn.reader_task)               # broke out cleanly, no 100% CPU
    end
end

@testset "no clobber by construction: rapid bring-ups never fail or leak" begin
    # The old LocalTransport shared-inner clobber (a fresh local session
    # overwriting a sibling's live subprocess Ref) is gone: each BinAgent owns
    # its OWN subprocess. So the regression is now the POSITIVE invariant — rapid
    # start!/stop! and restart cycles on a real MockAgent always succeed and
    # leave no orphaned mock process.

    @testset "rapid start!/stop! on one MockAgent: client cleared, no leak" begin
        base = mock_proc_count()
        ag = BT.MockAgent(; cwd = mktempdir())
        ag.env["BT_MOCK_ACP_SCENARIO"] = "normal"
        for _ in 1:5
            redirect_stderr(devnull) do; BT.start!(ag); end
            @test BT.client(ag) !== nothing      # came up
            @test isopen(ag) == true
            redirect_stderr(devnull) do; BT.stop!(ag); end
            @test BT.client(ag) === nothing      # torn down
            @test isopen(ag) == false
        end
        @test timedwait(() -> mock_proc_count() <= base, 6.0) === :ok
    end

    @testset "rapid restart_chat_session! on a live chat: alive each time, no leak" begin
        base = mock_proc_count()
        st = newstate_eof()
        ag = BT.MockAgent(; cwd = mktempdir())
        ag.env["BT_MOCK_ACP_SCENARIO"] = "normal"
        model = BT.ChatModel(st, ag.cwd; agent = ag)
        try
            redirect_stderr(devnull) do; BT.start_chat_client!(model); end
            for _ in 1:4
                redirect_stderr(devnull) do; BT.restart_chat_session!(model); end
                @test model.session_alive[] == true
                @test isempty(model.last_error[])
                @test BT.client(model.agent) !== nothing
            end
        finally
            redirect_stderr(devnull) do; BT.stop!(model.agent); end
        end
        # Exactly one agent at a time across all restarts → returns to baseline.
        @test timedwait(() -> mock_proc_count() <= base, 6.0) === :ok
    end
end
