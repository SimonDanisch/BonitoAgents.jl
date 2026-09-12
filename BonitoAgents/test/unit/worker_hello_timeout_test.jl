# The registration hello/ack is the ONE window in a worker's life with no
# watchdog on either side: the worker's receive-watchdog is armed from the
# `heartbeat_interval` that arrives IN the ack, and the server's zombie reaper
# only watches workers it has already registered. A server that completes the
# websocket upgrade and then never answers therefore used to park the worker in
# `receive` forever.
#
# That is not hypothetical. On 2026-09-11 a worker dialled in at 14:49:07 and
# sat there until 15:03:44 — 14m37s — and was released not by noticing anything
# but by the server PROCESS dying (1006). For that whole quarter hour the worker
# looked connected to itself and absent to everyone else.
#
# The peer here is a RAW TCP socket (same trick as `unit:force_close_ws`): it
# completes the websocket handshake and then says nothing. An
# `HTTP.WebSockets` server would answer at the protocol level and defeat the
# point.
@testitem "unit:worker_hello_timeout" tags = [:unit] begin
    using Sockets, SHA, Base64, Test
    import BonitoWorker

    server = Sockets.listen(Sockets.ip"127.0.0.1", 0)
    port   = getsockname(server)[2]
    accepted = Channel{Any}(1)
    srv_task = Base.errormonitor(@async begin
        sock = accept(server)
        req  = readuntil(sock, "\r\n\r\n")
        key  = match(r"Sec-WebSocket-Key:\s*(\S+)"i, req)[1]
        acc  = base64encode(sha1(key * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        write(sock, "HTTP/1.1 101 Switching Protocols\r\n" *
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" *
                    "Sec-WebSocket-Accept: $acc\r\n\r\n")
        put!(accepted, sock)
        # …and now the wedge: upgraded, listening, never answering the hello.
        sleep(120)
        close(sock)
    end)

    # Generous relative to `hello_timeout`, tight relative to "forever": the
    # whole point is that this returns at all.
    HELLO_TIMEOUT = 2.0
    done = Channel{Any}(1)
    t0 = time()
    Base.errormonitor(@async put!(done, try
        BonitoWorker.run_control_session(;
            server_url    = "http://127.0.0.1:$port",
            secret        = "s", worker_id = "w", name = "w",
            mcp_command   = "julia", mcp_arguments = String[],
            projects_root = mktempdir(), agent_bin = "true",
            hello_timeout = HELLO_TIMEOUT)
        nothing
    catch e
        e
    end))

    @test timedwait(() -> isready(done), 30.0) === :ok
    elapsed = time() - t0
    outcome = take!(done)

    # It gave up, and it gave up on OUR schedule — not the peer's, and for the
    # stated reason. Asserting the MESSAGE matters: without the bound this test
    # returns almost immediately and without an error, so timing alone could
    # pass for the wrong reason.
    @test outcome isa Exception
    @test occursin("registration hello", sprint(showerror, outcome))
    @test elapsed < 20.0
    @test elapsed >= HELLO_TIMEOUT
    # The server did get the hello: this is a wedged server, not a failed dial,
    # and the distinction is the whole diagnosis.
    @test isready(accepted)

    close(server)
end
