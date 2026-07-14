# The sendlock deadlock behind the zombie-worker watchdog (#33, WLAN→LAN
# incident). A send into a wedged link parks in `waitwrite` HOLDING
# `ws.sendlock`; the polite `close(ws)` then writes its CLOSE frame under that
# same lock, so "detect zombie → close(ws)" deadlocks and the teardown never
# runs. `force_close_ws!` kills the raw transport instead (no locks; Reseau's
# `evict!` wakes all parked readers AND writers into their error paths).
#
# The peer here is a RAW TCP socket that completes the websocket handshake and
# then never reads again — NOT an `HTTP.WebSockets` server, whose read task
# drains frames into an unbounded Channel and would never let the client park.
# Kernel rcv+snd buffers fill after a few MiB and the client send wedges,
# exactly like the interface-switch incident (socket ESTABLISHED, peer gone).
@testitem "unit:force_close_ws" tags = [:unit] begin
    using Sockets, SHA, Base64
    using HTTP: WebSockets

    hold   = Base.Event()
    server = Sockets.listen(Sockets.ip"127.0.0.1", 0)
    port   = getsockname(server)[2]
    srv_task = Base.errormonitor(@async begin
        sock = accept(server)
        req  = readuntil(sock, "\r\n\r\n")
        key  = match(r"Sec-WebSocket-Key:\s*(\S+)"i, req)[1]
        acc  = base64encode(sha1(key * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        write(sock, "HTTP/1.1 101 Switching Protocols\r\n" *
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" *
                    "Sec-WebSocket-Accept: $acc\r\n\r\n")
        wait(hold)          # park WITHOUT reading — the wedge
        close(sock)
    end)

    ws_ch    = Channel{Any}(1)
    sends_ok = Threads.Atomic{Int}(0)
    send_err = Channel{Any}(1)
    client_task = Base.errormonitor(@async try
        WebSockets.open("ws://127.0.0.1:$port") do ws
            put!(ws_ch, ws)
            chunk = rand(UInt8, 1 << 20)        # 1 MiB binary — incompressible
            try
                while true
                    WebSockets.send(ws, chunk)
                    Threads.atomic_add!(sends_ok, 1)
                end
            catch e
                put!(send_err, e)
                rethrow()   # let open()'s teardown see the dead socket
            end
        end
    catch
        # expected: the whole connection dies when the transport is killed
    end)
    ws = take!(ws_ch)

    # Wedged = the send counter stops moving (a parked send holds sendlock).
    stalled_at = Ref(-1)
    @test timedwait(15.0; pollint = 0.25) do
        n = sends_ok[]
        stalled = n == stalled_at[]
        stalled_at[] = n
        stalled && islocked(ws.sendlock)
    end == :ok

    @testset "polite close(ws) deadlocks behind the wedged send" begin
        polite = @async (BonitoAgents.close_ws_safe(ws); true)
        @test timedwait(() -> istaskdone(polite), 3.0) == :timed_out

        @testset "force_close_ws! unwedges everything" begin
            forcer = @async (BonitoAgents.force_close_ws!(ws); true)
            @test timedwait(() -> istaskdone(forcer), 3.0) == :ok
            # The parked send wakes with an error…
            @test timedwait(() -> isready(send_err), 5.0) == :ok
            # …which releases sendlock, so even the stuck polite close finishes.
            @test timedwait(() -> istaskdone(polite), 10.0) == :ok
            @test timedwait(() -> istaskdone(client_task), 10.0) == :ok
        end
    end

    notify(hold)
    close(server)
end
