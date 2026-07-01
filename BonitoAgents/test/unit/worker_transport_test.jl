@testitem "unit:worker_transport" tags = [:unit] begin

# Headless unit test for the WorkerTransport outbound-write drop policy.
#
# The transport must DISTINGUISH two failure modes when it writes to the worker
# WebSocket:
#
#   * FULLY closed (both halves): a clean/known-dead connection whose teardown is
#     already in motion (the recv side returns "" + `transport_eof` is true, which
#     tears the read loop down and fails pending requests). There is nothing left
#     to deliver and nothing to surface — drop the write QUIETLY (return nothing).
#
#   * HALF-open write death (write side closed, read side possibly still blocked):
#     a mid-write failure. Dropping this quietly would silently vanish an outbound
#     frame — a `session/prompt` registers a turn whose `updates`/`response`
#     channels then wait forever for a reply the agent never received. This must
#     SURFACE as `ConnectionClosed` so the chat's `is_session_dead_error` path
#     marks the session dead instead of the turn wedging.
#
# We build a real HTTP WebSocket pair over loopback, then drive the two states by
# toggling the socket's `writeclosed`/`readclosed` flags (HTTP's `isclosed` is
# `readclosed && writeclosed`; its `send` throws on `writeclosed`).

using Test
import HTTP
using AgentClientProtocol
const ACP = AgentClientProtocol

# A connected WebSocket end (server side) + a keep-alive server. The caller must
# `close(srv)` when done.
function ws_pair()
    got  = Channel{Any}(2)
    port = rand(20000:40000)
    srv  = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        put!(got, ws)
        try
            for _ in ws end          # keep the read side alive
        catch
        end
    end
    Threads.@spawn try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
            put!(got, ws)
            try
                for _ in ws end
            catch
            end
        end
    catch
    end
    ws = take!(got); take!(got)      # server end (used) + client end (parked)
    sleep(0.2)                        # let the handshake settle
    return ws, srv
end

@testset "half-open write death surfaces as ConnectionClosed" begin
    ws, srv = ws_pair()
    try
        t = ACP.WorkerTransport(Ref{Any}(ws))
        # Write half dead, read half still open — the mid-write failure case.
        ws.writeclosed = true
        ws.readclosed  = false
        @test HTTP.WebSockets.isclosed(ws) == false   # NOT the clean-shutdown state

        thrown = nothing
        try
            ACP.send(t, "session/prompt frame\n")
        catch e
            thrown = e
        end
        # It must NOT be silently dropped, and it must be the typed dead-session
        # signal (so `is_session_dead_error` fires downstream).
        @test thrown isa ACP.ConnectionClosed
    finally
        close(srv)
    end
end

@testset "fully-closed transport drops the write quietly" begin
    ws, srv = ws_pair()
    try
        t = ACP.WorkerTransport(Ref{Any}(ws))
        # Both halves closed: teardown already in motion — nothing to surface.
        ws.writeclosed = true
        ws.readclosed  = true
        @test HTTP.WebSockets.isclosed(ws) == true

        # No throw, no hang — a plain quiet drop.
        @test ACP.send(t, "late frame\n") === nothing
    finally
        close(srv)
    end
end

@testset "a nothing ws is a no-op (never dialed / stopped)" begin
    t = ACP.WorkerTransport(Ref{Any}(nothing))
    @test ACP.send(t, "frame\n") === nothing
end

end
