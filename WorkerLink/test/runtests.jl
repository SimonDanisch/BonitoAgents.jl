using Test, WorkerLink, HTTP, Sockets, SHA, Base64
using HTTP: WebSockets
const WL = WorkerLink

# ── helpers ──────────────────────────────────────────────────────────────────

# The server side of a new connection, the way an application does it: a known
# link id whose link is still alive resumes; anything else gets a fresh link.
function serve!(registry::Dict, t::Transport; reply = UInt8[], kw...)
    h = read_hello(t)
    existing = get(registry, h.link_id, nothing)
    resumed = existing !== nothing && WL.state(existing) !== :dead
    link = resumed ? existing : Link(:server; id = h.link_id, kw...)
    registry[h.link_id] = link
    welcome!(link, t, h, reply; resumed)
    return link
end

# Connect `client` over a fresh in-memory connection; `kw` configure a NEW server link.
function dial!(client::Link, registry::Dict; kw...)
    ct, st = memory_pair()
    # errormonitor: a failing server side is reported at once, not as the
    # client's handshake timeout 30 s later.
    server = errormonitor(Threads.@spawn serve!(registry, st; kw...))
    connect!(client, ct, UInt8[])
    return fetch(server), ct, st
end

eventually(f; timeout = 10.0) = timedwait(f, timeout; pollint = 0.01) === :ok

# The error a receive ends with, or `nothing` if it returned.
receive_error(ch) = try
    WebSockets.receive(ch)
    nothing
catch e
    e
end

# Accept peer-opened channels into a queue; `accepted(header)` waits for one.
struct Acceptor
    queue::Base.Channel{LinkChannel}
end
Acceptor() = Acceptor(Base.Channel{LinkChannel}(Inf))
(a::Acceptor)(ch::LinkChannel) = put!(a.queue, ch)
function accepted(a::Acceptor, header::AbstractString)
    for _ in 1:100
        ch = take!(a.queue)
        String(copy(WL.header(ch))) == header && return ch
        put!(a.queue, ch)
    end
    error("no channel with header $(repr(header))")
end

# A connection whose sends can be held back, recording what goes out.
mutable struct GateTransport <: Transport
    inner::MemoryTransport
    lock::ReentrantLock
    cond::Threads.Condition
    held::Bool
    recording::Bool
    sent::Vector{Tuple{UInt8,UInt32}}     # (frame kind, channel) in wire order
end
function GateTransport(inner::MemoryTransport)
    lk = ReentrantLock()
    return GateTransport(inner, lk, Threads.Condition(lk), false, false, Tuple{UInt8,UInt32}[])
end
function WL.send_message(t::GateTransport, bytes::Vector{UInt8})
    lock(t.lock) do
        while t.held
            wait(t.cond)
        end
        if t.recording
            f = WL.decode(bytes)
            push!(t.sent, (f.kind, f.channel))
        end
    end
    WL.send_message(t.inner, bytes)
end
WL.receive_message(t::GateTransport) = WL.receive_message(t.inner)
WL.close_transport(t::GateTransport) = WL.close_transport(t.inner)
hold!(t::GateTransport, held::Bool) = lock(t.lock) do
    t.held = held
    notify(t.cond)
end

# A connection that silently stops delivering, like a dead route.
mutable struct SilentTransport <: Transport
    inner::MemoryTransport
    silent::Bool
end
WL.send_message(t::SilentTransport, bytes::Vector{UInt8}) =
    t.silent ? nothing : WL.send_message(t.inner, bytes)
WL.receive_message(t::SilentTransport) = WL.receive_message(t.inner)
WL.close_transport(t::SilentTransport) = WL.close_transport(t.inner)

# ── tests ────────────────────────────────────────────────────────────────────

@testset "WorkerLink" begin

@testset "frames round-trip" begin
    for f in (WL.Frame(WL.F_DATA, 7; flags = WL.FLAG_EOM, seq = 42, payload = UInt8[1, 2, 3]),
              WL.Frame(WL.F_ACK, 0; seq = UInt64(typemax(UInt32)) + 5),
              WL.Frame(WL.F_OPEN, 0xfffffffe; payload = UInt8[2, 0x61]))
        g = WL.decode(WL.encode(f))
        @test (g.kind, g.flags, g.channel, g.seq, g.payload) ==
              (f.kind, f.flags, f.channel, f.seq, f.payload)
    end
    @test_throws ProtocolError WL.decode(UInt8[1, 2, 3])
end

@testset "control channel: both ways, in order, text stays text" begin
    reg = Dict{Vector{UInt8},Link}()
    client = Link(:client)
    server, _, _ = dial!(client, reg)
    c0, s0 = control_channel(client), control_channel(server)
    for i in 1:200
        WebSockets.send(c0, isodd(i) ? "text $i" : UInt8[i % 256, 0x00])
    end
    got = [WebSockets.receive(s0) for _ in 1:200]
    @test got[1] isa String && got[2] isa Vector{UInt8}
    @test all(got[i] == (isodd(i) ? "text $i" : UInt8[i % 256, 0x00]) for i in 1:200)
    WebSockets.send(s0, "back")
    @test WebSockets.receive(c0) == "back"
    WebSockets.send(c0, UInt8[])                    # an empty message is a message
    @test WebSockets.receive(s0) == UInt8[]
    @test_throws ArgumentError close(c0)            # control ends with the link
    kill!(client, "done"); kill!(server, "done")
end

@testset "a channel the peer opens arrives in on_open, with its header" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client)
    server, _, _ = dial!(client, reg; on_open = acc)
    ch = open_channel(client, Vector{UInt8}("acp sid=42"))
    sch = accepted(acc, "acp sid=42")
    @test isodd(WL.channel_id(ch)) && WL.channel_id(sch) == WL.channel_id(ch)
    WebSockets.send(ch, "ping");  @test WebSockets.receive(sch) == "ping"
    WebSockets.send(sch, "pong"); @test WebSockets.receive(ch) == "pong"

    # A clean close delivers everything sent before it, then iteration just ends.
    for i in 1:5
        WebSockets.send(ch, "m$i")
    end
    close(ch)
    @test collect(sch) == ["m$i" for i in 1:5]
    err = receive_error(sch)
    @test err isa WebSockets.WebSocketError && WebSockets.isok(err)
    # Sending on a closed channel fails the way a closed websocket does, on
    # both sides: the peer answered the close with its own.
    err = try WebSockets.send(ch, "late"); nothing catch e; e end
    @test err isa WebSockets.WebSocketError && err.message.code == 1006
    err = try WebSockets.send(sch, "late"); nothing catch e; e end
    @test err isa WebSockets.WebSocketError && err.message.code == 1006
    close(sch)                                      # already closed: a no-op
    @test eventually(() -> WebSockets.isclosed(ch) && WebSockets.isclosed(sch))
    @test eventually(() -> lock(() -> length(client.channels) == 1, client.lock))  # retired

    # The server opens channels from the other id range; a client with no
    # handler turns them away, and the opener hears why.
    unwanted = open_channel(server, Vector{UInt8}("unwanted"))
    @test iseven(WL.channel_id(unwanted))
    err = receive_error(unwanted)
    @test err isa WebSockets.WebSocketError && !WebSockets.isok(err)
    @test occursin("no channels are accepted", sprint(showerror, err))
    kill!(client, "done"); kill!(server, "done")
end

@testset "isclosed stays false until the last message is read" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client)
    server, _, _ = dial!(client, reg; on_open = acc)
    ch = open_channel(client, Vector{UInt8}("drain"))
    sch = accepted(acc, "drain")
    WebSockets.send(sch, "last words")
    close(sch)
    # The close has arrived (the echo went back), the message is still unread.
    @test eventually(() -> lock(() -> ch.remote_closed, client.lock))
    @test !WebSockets.isclosed(ch)
    @test WebSockets.receive(ch) == "last words"
    @test WebSockets.isclosed(ch)

    # Same for an abort: what arrived before it is read first, then the error.
    ch2 = open_channel(client, Vector{UInt8}("drain2"))
    sch2 = accepted(acc, "drain2")
    WebSockets.send(sch2, "before the abort")
    @test eventually(() -> lock(() -> !isempty(ch2.inbox), client.lock))
    abort(sch2, "gone")
    @test eventually(() -> lock(() -> ch2.aborted !== nothing, client.lock))
    @test !WebSockets.isclosed(ch2)
    @test WebSockets.receive(ch2) == "before the abort"
    err = receive_error(ch2)
    @test err isa WebSockets.WebSocketError && !WebSockets.isok(err)
    @test WebSockets.isclosed(ch2)
    kill!(client, "done"); kill!(server, "done")
end

@testset "abort ends a channel at once and says why" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client)
    server, _, _ = dial!(client, reg; on_open = acc)
    ch = open_channel(client, Vector{UInt8}("doomed"))
    sch = accepted(acc, "doomed")
    abort(sch, "nope")
    err = receive_error(ch)
    @test err isa WebSockets.WebSocketError && !WebSockets.isok(err)
    @test occursin("nope", sprint(showerror, err))
    err = try WebSockets.send(ch, "x"); nothing catch e; e end
    @test err isa WebSockets.WebSocketError && occursin("aborted", sprint(showerror, err))
    @test WebSockets.isclosed(ch)
    kill!(client, "done"); kill!(server, "done")
end

@testset "a message far larger than the window arrives whole" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    W = 64 * 1024
    client = Link(:client; window = W)
    server, _, _ = dial!(client, reg; window = W, on_open = acc)
    ch = open_channel(client, Vector{UInt8}("big"))
    sch = accepted(acc, "big")
    big = rand(UInt8, 3 * 1024 * 1024 + 17)
    sender = Threads.@spawn WebSockets.send(ch, big)
    @test WebSockets.receive(sch) == big
    wait(sender)
    kill!(client, "done"); kill!(server, "done")
end

@testset "a reader that stops reading stalls only its own channel" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    W = 256 * 1024
    client = Link(:client; window = W)
    server, _, _ = dial!(client, reg; window = W, on_open = acc)
    a = open_channel(client, Vector{UInt8}("a"); priority = 3)
    b = open_channel(client, Vector{UInt8}("b"); priority = 3)
    sa, sb = accepted(acc, "a"), accepted(acc, "b")

    # Nobody reads `a`: its sender must block once the window is full...
    stuck = Threads.@spawn for _ in 1:64
        WebSockets.send(a, rand(UInt8, 32 * 1024))      # 2 MiB in total
    end
    # ...while `b`, same priority, keeps flowing.
    for i in 1:100
        WebSockets.send(b, "b$i")
    end
    @test [WebSockets.receive(sb) for _ in 1:100] == ["b$i" for i in 1:100]
    @test !istaskdone(stuck)
    # What the server holds for `a` is bounded by the window, not by what was sent.
    held = lock(server.lock) do
        sum((length(m) for (m, _, _) in sa.inbox); init = 0) + length(sa.assembling)
    end
    @test held <= W
    # Reading `a` releases its sender.
    for _ in 1:64
        WebSockets.receive(sa)
    end
    @test eventually(() -> istaskdone(stuck))
    kill!(client, "done"); kill!(server, "done")
end

@testset "control overtakes bulk data already queued" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client)
    ct, st = memory_pair()
    gate = GateTransport(ct)
    server_task = Threads.@spawn serve!(reg, st; on_open = acc)
    connect!(client, gate, UInt8[])
    server = fetch(server_task)
    bulk = open_channel(client, Vector{UInt8}("bulk"); priority = 3)
    sbulk = accepted(acc, "bulk")

    # Hold the wire, queue ten 64 KiB pieces of bulk data, then one control
    # message. The writer is stuck on the first piece; the control message must
    # be the very next thing out, ahead of the other nine.
    lock(() -> (gate.recording = true), gate.lock)
    hold!(gate, true)
    sender = Threads.@spawn WebSockets.send(bulk, rand(UInt8, 10 * 64 * 1024))
    # All ten queued and exactly one taken: the writer is blocked on the gate.
    @test eventually(() -> istaskdone(sender) && lock(() -> length(bulk.outq) == 9, client.lock))
    WebSockets.send(control_channel(client), "urgent")
    hold!(gate, false)
    @test WebSockets.receive(control_channel(server)) == "urgent"
    @test length(WebSockets.receive(sbulk)) == 10 * 64 * 1024
    wait(sender)
    data = [c for (k, c) in gate.sent if k == WL.F_DATA]
    @test data[1] == WL.channel_id(bulk)      # the piece the writer was already sending
    @test data[2] == 0                        # then control, ahead of the rest
    @test count(==(WL.channel_id(bulk)), data) == 10
    kill!(client, "done"); kill!(server, "done")
end

@testset "a dropped connection resumes without losing or repeating a message" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client)
    server, ct, _ = dial!(client, reg; on_open = acc)
    ch = open_channel(client, Vector{UInt8}("stream"))
    sch = accepted(acc, "stream")
    N = 3000
    up   = Threads.@spawn for i in 1:N; WebSockets.send(ch,  "up $i");   end
    down = Threads.@spawn for i in 1:N; WebSockets.send(sch, "down $i"); end
    got_up, got_down = String[], String[]
    r_up   = Threads.@spawn for _ in 1:N; push!(got_up,   WebSockets.receive(sch)); end
    r_down = Threads.@spawn for _ in 1:N; push!(got_down, WebSockets.receive(ch));  end

    # Drop the network three times while both directions are busy.
    for _ in 1:3
        sleep(0.05)
        WL.close_transport(ct)
        @test eventually(() -> WL.state(client) === :detached)
        again, ct, _ = dial!(client, reg)
        @test again === server                  # resumed, not replaced
    end
    foreach(wait, (up, down, r_up, r_down))
    @test got_up == ["up $i" for i in 1:N]
    @test got_down == ["down $i" for i in 1:N]
    kill!(client, "done"); kill!(server, "done")
end

@testset "a server that forgot the link resets the client" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client)
    server, _, _ = dial!(client, reg; on_open = acc)
    ch = open_channel(client, Vector{UInt8}("x"))
    accepted(acc, "x")
    old0 = control_channel(client)
    empty!(reg)                                  # the server restarted
    disconnect!(client)
    server2, _, _ = dial!(client, reg)
    @test server2 !== server
    err = receive_error(ch)
    @test err isa WebSockets.WebSocketError && occursin("link reset", sprint(showerror, err))
    new0 = control_channel(client)
    @test new0 !== old0
    WebSockets.send(new0, "after")
    @test WebSockets.receive(control_channel(server2)) == "after"
    kill!(client, "done"); kill!(server, "done"); kill!(server2, "done")
end

@testset "a reset is reported before the new connection delivers anything" begin
    reg = Dict{Vector{UInt8},Link}()
    seen = Any[]
    seen_lock = ReentrantLock()
    note(x) = lock(() -> push!(seen, x), seen_lock)
    client = Link(:client; on_state = (_, st) -> note(st),
                  on_open = ch -> note(String(copy(WL.header(ch)))))
    server, _, _ = dial!(client, reg)
    empty!(reg)                                  # the server restarted
    disconnect!(client)
    # The restarted server opens a channel the moment it has welcomed the
    # client, which can arrive before the client's `connect!` has returned.
    ct, st = memory_pair()
    server2 = errormonitor(Threads.@spawn begin
        link = serve!(reg, st)
        open_channel(link, Vector{UInt8}("early"))
        link
    end)
    connect!(client, ct, UInt8[])
    @test eventually(() -> "early" in lock(() -> copy(seen), seen_lock))
    got = lock(() -> copy(seen), seen_lock)
    @test :reset in got
    @test findfirst(==(:reset), got) < findfirst(==("early"), got)
    kill!(client, "done"); kill!(server, "done"); kill!(fetch(server2), "done")
end

@testset "no reconnect within the grace period kills the link" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    client = Link(:client; grace = 0.3)
    server, ct, _ = dial!(client, reg; grace = 0.3, on_open = acc)
    ch = open_channel(client, Vector{UInt8}("x"))
    accepted(acc, "x")
    WL.close_transport(ct)
    @test eventually(() -> WL.state(client) === :dead && WL.state(server) === :dead; timeout = 5)
    err = receive_error(ch)
    @test err isa WebSockets.WebSocketError && !WebSockets.isok(err)
    @test occursin("no connection", sprint(showerror, err))
    @test_throws LinkDead open_channel(client, UInt8[])
    @test_throws LinkDead control_channel(client)
end

@testset "a silent connection is caught by the ping deadline" begin
    reg = Dict{Vector{UInt8},Link}()
    client = Link(:client; ping_interval = 0.1, ping_deadline = 0.5)
    ct, st = memory_pair()
    sct, sst = SilentTransport(ct, false), SilentTransport(st, false)
    server_task = Threads.@spawn serve!(reg, sst; ping_interval = 0.1, ping_deadline = 0.5)
    connect!(client, sct, UInt8[])
    server = fetch(server_task)
    sleep(1.0)
    @test WL.state(client) === :connected         # pings keep a quiet link alive
    sct.silent = true
    sst.silent = true
    @test eventually(() -> WL.state(client) === :detached && WL.state(server) === :detached;
                     timeout = 5)
    kill!(client, "done"); kill!(server, "done")
end

@testset "liveness can be tightened on a live link" begin
    reg = Dict{Vector{UInt8},Link}()
    ct, st = memory_pair()
    sct, sst = SilentTransport(ct, false), SilentTransport(st, false)
    client = Link(:client; ping_interval = 30, ping_deadline = 60)
    server_task = Threads.@spawn serve!(reg, sst; ping_interval = 30, ping_deadline = 60)
    connect!(client, sct, UInt8[])
    server = fetch(server_task)
    sct.silent = true
    sst.silent = true
    sleep(1.0)
    @test WL.state(server) === :connected          # the relaxed deadline is far away
    WL.set_liveness!(server; ping_interval = 0.1, ping_deadline = 0.5)
    @test eventually(() -> WL.state(server) === :detached; timeout = 5)
    kill!(client, "done"); kill!(server, "done")
end

# The wedge behind the worker-zombie incident (#33): a peer that stops reading
# leaves the socket ESTABLISHED, the kernel buffers fill, and a send parks in
# the kernel forever. The link's writer must be released anyway: the deadline
# drops the connection, and a new one carries on. The peer is a RAW TCP socket
# that completes the websocket handshake and then never reads — an HTTP
# websocket server would drain frames into memory and never let a send park.
@testset "a peer that stops reading cannot wedge the link" begin
    hold = Base.Event()
    server = Sockets.listen(Sockets.ip"127.0.0.1", 0)
    port = getsockname(server)[2]
    peer = errormonitor(@async begin
        sock = accept(server)
        req = readuntil(sock, "\r\n\r\n")
        key = match(r"Sec-WebSocket-Key:\s*(\S+)"i, req)[1]
        acc = base64encode(sha1(key * "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        write(sock, "HTTP/1.1 101 Switching Protocols\r\n" *
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" *
                    "Sec-WebSocket-Accept: $acc\r\n\r\n")
        wait(hold)              # never read: the wedge
        close(sock)
    end)
    # Attached without a handshake (the peer would never answer one): this is
    # about the connection, not about who is on the other end.
    client = Link(:client; ping_interval = 0.2, ping_deadline = 1.0)
    t = WebSocketTransport(WebSockets.open("ws://127.0.0.1:$port"))
    WL.attach!(client, t, UInt64(0))
    # 16 channels × a full window = 16 MiB queued, far more than the loopback
    # buffers hold: the writer parks in the kernel. Each message is twice the
    # window, so every sender also parks, waiting for credit that never comes.
    senders = map(1:16) do i
        ch = open_channel(client, Vector{UInt8}("bulk$i"))
        @async try
            WebSockets.send(ch, rand(UInt8, 2 * 1024 * 1024))
            nothing
        catch e
            e
        end
    end
    @test eventually(() -> WL.state(client) === :detached; timeout = 10)
    @test eventually(() -> t.ended.set; timeout = 5)   # the transport was killed, not left hanging
    # And the link works on the next connection: everything queued is delivered.
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    ct, st = memory_pair()
    server_task = Threads.@spawn begin
        h = read_hello(st)
        s = Link(:server; id = h.link_id, on_open = acc)
        welcome!(s, st, h, UInt8[]; resumed = false)
        s
    end
    connect!(client, ct, UInt8[])          # a server that never saw this link: reset
    srv = fetch(server_task)
    @test eventually(() -> all(istaskdone, senders))
    @test all(t -> fetch(t) isa WebSockets.WebSocketError, senders)   # the reset aborted them
    ch2 = open_channel(client, Vector{UInt8}("after"))
    sch2 = accepted(acc, "after")
    WebSockets.send(ch2, "still alive")
    @test WebSockets.receive(sch2) == "still alive"
    notify(hold)
    close(server)
    kill!(client, "done"); kill!(srv, "done")
end

@testset "handshake: refusal and a server that never answers" begin
    ct, st = memory_pair()
    Threads.@spawn begin
        h = read_hello(st)
        refuse(st, "bad secret: $(String(copy(h.app)))")
    end
    err = try connect!(Link(:client), ct, Vector{UInt8}("wrong")); nothing catch e; e end
    @test err isa LinkRefused && err.reason == "bad secret: wrong"

    ct, _ = memory_pair()
    t0 = time()
    @test_throws ProtocolError connect!(Link(:client), ct, UInt8[]; timeout = 0.3)
    @test time() - t0 < 5

    ct, st = memory_pair()
    Threads.@spawn WL.send_message(st, UInt8[1, 2, 3])          # not a handshake
    @test_throws ProtocolError connect!(Link(:client), ct, UInt8[])
end

@testset "over a real websocket, including a reconnect" begin
    reg = Dict{Vector{UInt8},Link}()
    acc = Acceptor()
    srv = WebSockets.listen!("127.0.0.1", 0; listenany = true) do ws
        t = WebSocketTransport(ws)
        serve!(reg, t; on_open = acc)
        # Returning from the handler closes the socket: stay until it ends.
        wait(t)
    end
    try
        url = "ws://" * WebSockets.server_addr(srv)
        client = Link(:client)
        dial() = connect!(client, WebSocketTransport(WebSockets.open(url)), UInt8[])
        dial()
        ch = open_channel(client, Vector{UInt8}("ws"))
        sch = accepted(acc, "ws")
        big = rand(UInt8, 20 * 1024 * 1024)      # beyond HTTP.jl's 16 MiB frame limit
        sender = Threads.@spawn WebSockets.send(ch, big)
        @test WebSockets.receive(sch) == big
        wait(sender)

        server_t = lock(() -> only(values(reg)).transport, only(values(reg)).lock)
        disconnect!(client)                      # drop the TCP connection
        @test eventually(() -> WL.state(client) === :detached)
        # The server's handler is released once its connection ended.
        @test timedwait(() -> server_t.ended.set, 10.0) === :ok
        WebSockets.send(ch, "queued while away")
        dial()
        @test WebSockets.receive(sch) == "queued while away"
        WebSockets.send(sch, "and back")
        @test WebSockets.receive(ch) == "and back"
        kill!(client, "done")
        foreach(l -> kill!(l, "done"), values(reg))
    finally
        close(srv)
    end
end

end # WorkerLink
