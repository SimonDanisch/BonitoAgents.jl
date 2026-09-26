# The worker's local relay: how processes this worker runs for a chat reach the
# server. Its MCP server (control: interrupts, live stdout, dev requests) and that
# MCP's eval workers (the live-render bridge) connect to a loopback websocket
# with a token the worker handed out for one chat and role. Each connection
# becomes a channel on the worker's link, opened with the chat it speaks for,
# so none of them needs the server's address or the worker's secret, and a
# client can't choose which chat or role it speaks for.
#
# Handshake, the first message on the local socket:
#   "<control token>"                 the MCP process's control channel
#   "<eval token> eval <prefix>"      an eval worker's bridge, `prefix` naming it
# The relay answers "ok" once the server accepted the channel, or closes the
# socket with the server's reason. After "ok" the socket and the channel carry
# the same messages both ways.

# What a token was handed out for. `kind`: the channel it may open ("mcp" or
# "eval"). `host`: an eval host serving the chat from this worker, not the chat's
# own MCP. `owner` groups grants to revoke them together (an agent session, or
# one chat's eval host).
struct RelayGrant
    kind::String
    project_id::String
    host::Bool
    owner::String
end

# A live local connection and the channel it was given.
struct RelayPeer
    ws::WebSockets.WebSocket
    channel::WorkerLink.LinkChannel
    owner::String
end

mutable struct MCPRelay
    const link::WorkerLink.Link
    const grants::Dict{String,RelayGrant}     # by token
    const peers::Dict{String,RelayPeer}
    const lock::ReentrantLock
    closed::Bool
    server::WebSockets.Server                 # the loopback listener; last, see below
    function MCPRelay(link::WorkerLink.Link)
        # `server` is set right after: its handler needs the relay.
        return new(link, Dict{String,RelayGrant}(), Dict{String,RelayPeer}(), ReentrantLock(), false)
    end
end

function start_mcp_relay(link::WorkerLink.Link)
    relay = MCPRelay(link)
    relay.server = WebSockets.listen!("127.0.0.1", 0) do ws
        serve_mcp_relay(relay, ws)
    end
    return relay
end

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
                "BONITOAGENTS_CONTROL_TOKEN" => control,
                "BONITOAGENTS_EVAL_TOKEN" => eval)
end

# End a connection both ways: the local socket, and the channel to the server.
function Base.close(peer::RelayPeer)
    close_transport_quietly!(peer.ws)
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

# Hang up on a local client, telling it why.
function refuse_local(ws::WebSockets.WebSocket, reason::AbstractString)
    try
        WebSockets.close(ws, WebSockets.CloseFrameBody(1008, reason))
    catch e
        (e isa WebSockets.WebSocketError || e isa Base.IOError) || rethrow()
    end
    return nothing
end

function serve_mcp_relay(relay::MCPRelay, ws::WebSockets.WebSocket)
    # A local client must authenticate promptly; never keep idle unauthenticated sockets.
    authenticated = Ref(false)
    timer = Timer(10.0) do _
        authenticated[] || close_transport_quietly!(ws)
    end
    id = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
    try
        request = relay_request(relay, String(WebSockets.receive(ws)))
        if request === nothing
            @warn "BonitoWorker relay: refused a local connection with an unknown token or handshake"
            return refuse_local(ws, "unknown token")
        end
        token, owner, header = request
        authenticated[] = true
        # Live-render frames can be large; the MCP's control messages are small
        # and should not wait behind them.
        channel = WorkerLink.open_channel(relay.link, MsgPack.pack(header);
                                          priority = header["kind"] == "eval" ? 2 : 1)
        # Registered before the server answers, so a revoke or close reaches a
        # connection still waiting; and only while its grant stands, since a
        # revoke that ran since the handshake has closed every peer it knew of.
        registered = lock(relay.lock) do
            (relay.closed || !haskey(relay.grants, token)) && return false
            relay.peers[id] = RelayPeer(ws, channel, owner)
            true
        end
        if !registered
            WorkerLink.abort(channel, "relay grant revoked")
            return refuse_local(ws, "grant revoked")
        end
        refused = server_verdict(channel)
        if refused !== nothing
            ours = lock(() -> relay.closed || !haskey(relay.grants, token), relay.lock)
            ours || @warn "BonitoWorker relay: the server refused a channel" kind = header["kind"] project_id = header["project_id"] reason = refused
            return refuse_local(ws, refused)
        end
        WebSockets.send(ws, "ok")
        # Server → local client, while this task pumps the other way.
        down = @async try
            for msg in channel
                WebSockets.send(ws, msg)
            end
        catch e
            (e isa WebSockets.WebSocketError || e isa Base.IOError) || rethrow()
        finally
            close_transport_quietly!(ws)
        end
        try
            for msg in ws
                WebSockets.send(channel, msg)
            end
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
    return nothing
end
