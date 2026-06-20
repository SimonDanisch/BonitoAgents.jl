# Regression for the `stop_session!` → 100% CPU livelock (close-chat freeze).
#
# Root cause: `stop_session!` used to close the bare `model.transport` instead of
# the ACP connection. The proper teardown is `close(client)` → `close(conn)`,
# which sets `conn.closed = true` BEFORE closing the socket so the reader loop
# exits on its `while !conn.closed` guard (mirrors the restart path). Closing only
# the transport left `conn.closed == false`; the worker WS's `recv` then returned
# "" on close without unblocking the guard, and — because `WorkerTransport` had no
# `transport_eof` — `reader_loop` `continue`d forever, hot-spinning its sticky
# (`@async`, thread-1) task and starving every other server task ("100% CPU, GUI
# navigable but no Julia action triggers").
#
# Three independent fixes, one testset each below:
#   1. `stop_session!`/teardown closes the CONNECTION → `conn.closed` short-circuits.
#   2. `transport_eof(::WorkerTransport/::LocalTransport)` reports EOF on a closed
#      ws, so an UNSOLICITED clean close (worker drops the ws) also breaks the loop.
#   3. `WorkerTransport.recv` no longer blanket-swallows IOError/WebSocketError →
#      an ABNORMAL close surfaces as an error instead of masquerading as clean EOF.

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

@testset "transport_eof on dead/undialed transports" begin
    state = newstate_eof()

    @testset "WorkerTransport: never-dialed ws is EOF" begin
        t = BT.WorkerTransport(state, "w1", "/tmp/wp")
        @test t.ws[] === nothing
        @test ACP.transport_eof(t) == true     # ws nothing → no more frames → EOF
    end

    @testset "WorkerTransport: closed ws is EOF" begin
        # A real HTTP WebSocket pair, then close one side: `isclosed` flips true,
        # `recv` returns "" instantly, and `transport_eof` must agree so the
        # reader loop terminates instead of hot-spinning on the closed socket.
        t = BT.WorkerTransport(state, "w2", "/tmp/wp")
        with_ws_pair(ws -> (for _ in ws; end)) do client_ws   # server holds open
            t.ws[] = client_ws
            @test ACP.transport_eof(t) == false   # live ws is not EOF
            close(client_ws)
            @test ACP.transport_eof(t) == true    # closed ws → EOF
        end
    end

    @testset "LocalTransport: un-started (inner nothing) is EOF" begin
        lt = BT.LocalTransport(mktempdir(); agent_bin = "/bin/true")
        @test lt.inner[] === nothing
        @test ACP.transport_eof(lt) == true
    end
end

@testset "WorkerTransport.recv does not swallow abnormal closes" begin
    # `recv`'s contract: "" on a CLEAN end-of-stream, throw on a real failure.
    # The reader must be BLOCKED in `recv` when the close lands (as in the real
    # `reader_loop`), so the close is processed by the in-flight `receive` rather
    # than the `isclosed` fast path.
    state = newstate_eof()

    function recv_when(action::Symbol)
        t = BT.WorkerTransport(state, "w", "/tmp/wp")
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
    # `stop_session!` now closes the ACP connection (`close(client)` → `close(conn)`),
    # NOT the bare transport. `close(conn)` sets `conn.closed` first, so the reader
    # loop — even one parked in a live `receive` — exits on its guard without
    # hot-spinning. This is the exact mechanism that fixes the close-chat freeze.
    state = newstate_eof()
    t = BT.WorkerTransport(state, "w", "/tmp/wp")
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
