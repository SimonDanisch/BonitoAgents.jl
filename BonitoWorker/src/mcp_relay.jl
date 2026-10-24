# The worker's local relay: how processes this worker runs for a chat reach the
# server. Its MCP server (control: interrupts, live stdout, dev requests) and that
# MCP's eval workers (the live-render bridge, value exchanges) connect over
# loopback with a token the worker handed out for one chat and role. Each
# connection becomes a channel on the worker's link, opened with the chat it
# speaks for, so none of them needs the server's address or the worker's secret,
# and a client can't choose which chat or role it speaks for.
#
# Handshake, the first message on the local connection:
#   "<control token>"                 the MCP process's control channel
#   "<eval token> eval <prefix>"      an eval worker's bridge, `prefix` naming it
#   "<eval token> values"             an eval worker asking for a session on
#                                     another worker, to move Julia values
#   "<eval token> values <pair>"      an eval worker answering such a request
#                                     (`pair` names it, the server chose it)
# The relay answers "ok" once the server accepted the channel, or hangs up with
# the server's reason. After "ok" the connection and the channel carry the same
# messages both ways.
#
# Two local transports, one set of rules: a websocket (the MCP process and the
# bridge, which have HTTP loaded) and a plain TCP socket for value exchanges.
# Those run in the eval worker, i.e. in the USER's project, where no websocket
# client can be assumed; a TCP message is `[flags u8][length u32 LE][bytes]`,
# flags 1 for text. A refusal there is the text "refused\n<reason>".

# What a token was handed out for. `kind`: the channels it may open ("mcp", or
# "eval" for the bridge and value exchanges). `host`: an eval host serving the chat from this worker, not the chat's
# own MCP. `owner` groups grants to revoke them together (an agent session, or
# one chat's eval host).
struct RelayGrant
    kind::String
    project_id::String
    host::Bool
    owner::String
end

const LocalConnection = Union{WebSockets.WebSocket,Sockets.TCPSocket}

# A live local connection and the channel it was given.
struct RelayPeer
    conn::LocalConnection
    channel::WorkerLink.LinkChannel
    owner::String
end

mutable struct MCPRelay
    const link::WorkerLink.Link
    const grants::Dict{String,RelayGrant}     # by token
    const peers::Dict{String,RelayPeer}
    const lock::ReentrantLock
    closed::Bool
    # The loopback listeners, websocket and TCP; last, see below.
    server::WebSockets.Server
    tcp_server::Sockets.TCPServer
    function MCPRelay(link::WorkerLink.Link)
        # The listeners are set right after: their handlers need the relay.
        return new(link, Dict{String,RelayGrant}(), Dict{String,RelayPeer}(), ReentrantLock(), false)
    end
end

function start_mcp_relay(link::WorkerLink.Link)
    relay = MCPRelay(link)
    relay.server = WebSockets.listen!("127.0.0.1", 0) do ws
        serve_mcp_relay(relay, ws)
    end
    relay.tcp_server = Sockets.listen(Sockets.localhost, 0)
    Base.errormonitor(@async accept_tcp(relay))
    return relay
end

# Serve every TCP client until the relay closes its listener.
function accept_tcp(relay::MCPRelay)
    while true
        sock = try
            Sockets.accept(relay.tcp_server)
        catch e
            # Closing the relay closes the listener: that is how this loop ends.
            (e isa Base.IOError && !isopen(relay.tcp_server)) || rethrow()
            return nothing
        end
        Sockets.nagle(sock, false)
        Base.errormonitor(@async serve_mcp_relay(relay, sock))
    end
end

tcp_address(relay::MCPRelay) = "127.0.0.1:" * string(Sockets.getsockname(relay.tcp_server)[2])

new_relay_token() = bytes2hex(rand(Random.RandomDevice(), UInt8, 32))

# The environment an MCP process needs to reach the server for `project_id`: the
# relay's address, a control token for itself, and an eval token for its eval
# workers' bridges. The eval workers run user code, which must not be able to
# speak as the MCP's control channel.
function mcp_relay_env(relay::MCPRelay, project_id::AbstractString;
                       host::Bool = false, owner::AbstractString = project_id)
    control, eval = new_relay_token(), new_relay_token()
    lock(relay.lock) do
        relay.closed && error("worker control connection is closed")
        relay.grants[control] = RelayGrant("mcp", project_id, host, owner)
        relay.grants[eval] = RelayGrant("eval", project_id, host, owner)
    end
    return Dict("BONITOAGENTS_CONTROL_URL" => "ws://" * WebSockets.server_addr(relay.server),
                "BONITOAGENTS_VALUES_ADDR" => tcp_address(relay),
                "BONITOAGENTS_CONTROL_TOKEN" => control,
                "BONITOAGENTS_EVAL_TOKEN" => eval)
end

# ── The local connection, either transport ──────────────────────────────────
# Past this block the relay does not care which one a client used.

receive_local(ws::WebSockets.WebSocket) = WebSockets.receive(ws)
send_local(ws::WebSockets.WebSocket, msg) = WebSockets.send(ws, msg)
close_local(ws::WebSockets.WebSocket) = close_transport_quietly!(ws)
function each_local(f, ws::WebSockets.WebSocket)
    for msg in ws
        f(msg)
    end
end

# No local client needs more per message: value exchanges send 1 MiB pieces.
# Checked before anything is allocated, since this is read before the handshake.
const MAX_TCP_MESSAGE = 16 * 1024 * 1024

function receive_local(s::Sockets.TCPSocket)
    flags = read(s, UInt8)
    n = Int(ltoh(read(s, UInt32)))
    n <= MAX_TCP_MESSAGE || error("local message of $(n) bytes is over the $(MAX_TCP_MESSAGE) limit")
    bytes = read(s, n)
    length(bytes) == n || throw(EOFError())
    return flags & 0x01 == 0x01 ? String(bytes) : bytes
end

function send_local(s::Sockets.TCPSocket, msg::Union{AbstractString,AbstractVector{UInt8}})
    header = Vector{UInt8}(undef, 5)
    header[1] = msg isa AbstractString ? 0x01 : 0x00
    header[2:5] .= reinterpret(UInt8, [htol(UInt32(msg isa AbstractString ? ncodeunits(msg) : length(msg)))])
    write(s, header)
    write(s, msg)
    return nothing
end

close_local(s::Sockets.TCPSocket) = close(s)

# When the relay is done with a connection: HTTP closes a websocket once its
# handler returns, a TCP socket is ours to close.
finish_local(::WebSockets.WebSocket) = nothing
finish_local(s::Sockets.TCPSocket) = close(s)

function each_local(f, s::Sockets.TCPSocket)
    while !eof(s)
        f(receive_local(s))
    end
end

# Hang up on a local client, telling it why.
function refuse_local(ws::WebSockets.WebSocket, reason::AbstractString)
    try
        WebSockets.close(ws, WebSockets.CloseFrameBody(1008, reason))
    catch e
        (e isa WebSockets.WebSocketError || e isa Base.IOError) || rethrow()
    end
    return nothing
end

function refuse_local(s::Sockets.TCPSocket, reason::AbstractString)
    try
        send_local(s, "refused\n" * reason)
    catch e
        e isa Base.IOError || rethrow()     # the client is gone already
    end
    close(s)
    return nothing
end

# End a connection both ways: the local socket, and the channel to the server.
function Base.close(peer::RelayPeer)
    close_local(peer.conn)
    WorkerLink.abort(peer.channel, "relay connection closed")
    return nothing
end

function revoke_mcp_grants!(relay::MCPRelay, owner::AbstractString)
    peers = lock(relay.lock) do
        filter!(p -> p.second.owner != owner, relay.grants)
        [p for p in values(relay.peers) if p.owner == owner]
    end
    foreach(close, peers)
    return nothing
end

# What a handshake asks for: its token and the channel header to open, or
# `nothing` when the token is not one we handed out (or no longer valid), or is
# not one for the channel asked for.
function relay_request(relay::MCPRelay, handshake::AbstractString)
    token, rest... = split(handshake, ' ')
    grant = lock(() -> relay.closed ? nothing : get(relay.grants, token, nothing), relay.lock)
    grant === nothing && return nothing
    header = Dict{String,Any}("kind" => grant.kind, "project_id" => grant.project_id, "host" => grant.host)
    if grant.kind == "mcp"
        isempty(rest) || return nothing
    elseif length(rest) == 2 && rest[1] == "eval" && !isempty(rest[2])
        header["prefix"] = String(rest[2])
    elseif length(rest) in (1, 2) && rest[1] == "values" && all(!isempty, rest)
        header["kind"] = "values"
        length(rest) == 2 && (header["pair"] = String(rest[2]))
    else
        return nothing
    end
    return String(token), grant.owner, header
end

# The server's answer to a channel we opened: `nothing` once it accepted, or the
# reason it refused.
function server_verdict(channel::WorkerLink.LinkChannel)
    reply = try
        decode_control(WebSockets.receive(channel))
    catch e
        e isa WebSockets.WebSocketError || rethrow()
        return e.message isa WebSockets.CloseFrameBody ? e.message.reason : sprint(showerror, e)
    end
    get(reply, "ok", false) === true && return nothing
    return "unexpected answer: $(reply)"
end

function serve_mcp_relay(relay::MCPRelay, conn::LocalConnection)
    # A local client must authenticate promptly; never keep idle unauthenticated sockets.
    authenticated = Ref(false)
    timer = Timer(10.0) do _
        authenticated[] || close_local(conn)
    end
    id = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
    try
        request = relay_request(relay, String(receive_local(conn)))
        if request === nothing
            @warn "BonitoWorker relay: refused a local connection with an unknown token or handshake"
            return refuse_local(conn, "unknown token")
        end
        token, owner, header = request
        authenticated[] = true
        # Live-render frames and values can be large; the MCP's control messages
        # are small and should not wait behind them.
        channel = WorkerLink.open_channel(relay.link, MsgPack.pack(header);
                                          priority = header["kind"] == "mcp" ? 1 : 2)
        # Registered before the server answers, so a revoke or close reaches a
        # connection still waiting; and only while its grant stands, since a
        # revoke that ran since the handshake has closed every peer it knew of.
        registered = lock(relay.lock) do
            (relay.closed || !haskey(relay.grants, token)) && return false
            relay.peers[id] = RelayPeer(conn, channel, owner)
            true
        end
        if !registered
            WorkerLink.abort(channel, "relay grant revoked")
            return refuse_local(conn, "grant revoked")
        end
        refused = server_verdict(channel)
        if refused !== nothing
            ours = lock(() -> relay.closed || !haskey(relay.grants, token), relay.lock)
            ours || @warn "BonitoWorker relay: the server refused a channel" kind = header["kind"] project_id = header["project_id"] reason = refused
            return refuse_local(conn, refused)
        end
        send_local(conn, "ok")
        # Server → local client, while this task pumps the other way.
        down = @async try
            for msg in channel
                send_local(conn, msg)
            end
        catch e
            (e isa WebSockets.WebSocketError || e isa Base.IOError) || rethrow()
        finally
            close_local(conn)
        end
        try
            each_local(msg -> WebSockets.send(channel, msg), conn)
        finally
            # The local client is gone: so is its channel. Clean when it closed
            # cleanly, which lets the server read what was already sent.
            close(channel)
            wait(down)
        end
    catch e
        (e isa EOFError || e isa Base.IOError || e isa WebSockets.WebSocketError ||
         e isa WorkerLink.LinkDead) || @warn "local MCP relay connection ended" exception = e
    finally
        close(timer)
        lock(() -> delete!(relay.peers, id), relay.lock)
        finish_local(conn)
    end
    return nothing
end

function Base.close(relay::MCPRelay)
    peers = lock(relay.lock) do
        relay.closed && return nothing
        relay.closed = true
        empty!(relay.grants)
        collect(values(relay.peers))
    end
    peers === nothing && return nothing
    foreach(close, peers)
    close(relay.server)
    close(relay.tcp_server)
    return nothing
end
