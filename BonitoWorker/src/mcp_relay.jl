# Local MCP control sockets terminate at the daemon. Only the daemon's existing
# authenticated control connection talks to the server. Grants bind a local
# client to a chat and role; client payloads cannot select either identity.
mutable struct MCPRelay
    control::Any
    server::Any
    grants::Dict{String,NamedTuple}
    peers::Dict{String,Any}
    lock::ReentrantLock
    closed::Bool
end

mutable struct MCPRelayPeer
    ws::Any
    owner::String
    queue::Vector{Union{String,Nothing}}
    bytes::Int
    condition::Threads.Condition
    closed::Bool
end

function write_mcp_peer(peer::MCPRelayPeer)
    try
        while true
            frame = lock(peer.condition) do
                while isempty(peer.queue) && !peer.closed
                    wait(peer.condition)
                end
                isempty(peer.queue) && return nothing
                frame = popfirst!(peer.queue)
                frame === nothing || (peer.bytes -= sizeof(frame))
                frame
            end
            frame === nothing && break
            WebSockets.send(peer.ws, frame)
        end
    finally
        stop_mcp_peer!(peer)
    end
end

function stop_mcp_peer!(peer::MCPRelayPeer)
    lock(peer.condition) do
        peer.closed = true
        empty!(peer.queue)
        peer.bytes = 0
        notify(peer.condition)
    end
    close_transport_quietly!(peer.ws)
end

function start_mcp_relay(control)
    relay = MCPRelay(control, nothing, Dict{String,NamedTuple}(), Dict{String,Any}(),
                     ReentrantLock(), false)
    relay.server = WebSockets.listen!("127.0.0.1", 0) do ws
        serve_mcp_relay(relay, ws)
    end
    return relay
end

function mcp_relay_env(relay::MCPRelay, project_id::AbstractString;
                       host::Bool = false, owner::AbstractString = project_id)
    token = bytes2hex(rand(Random.RandomDevice(), UInt8, 32))
    lock(relay.lock) do
        relay.closed && error("worker control connection is closed")
        relay.grants[token] = (; project_id = String(project_id), host, owner = String(owner))
    end
    return Dict("BONITOAGENTS_CONTROL_URL" => "ws://" * WebSockets.server_addr(relay.server),
                "BONITOAGENTS_CONTROL_TOKEN" => token)
end

function revoke_mcp_grants!(relay::MCPRelay, owner::AbstractString)
    peers = lock(relay.lock) do
        filter!(p -> p.second.owner != owner, relay.grants)
        [p for p in values(relay.peers) if p.owner == owner]
    end
    foreach(stop_mcp_peer!, peers)
    return nothing
end

function serve_mcp_relay(relay::MCPRelay, ws)
    id = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
    registered = false
    peer = MCPRelayPeer(ws, "", Union{String,Nothing}[], 0, Threads.Condition(), false)
    writer = nothing
    # A local client must authenticate promptly; never retain idle unauthenticated sockets.
    authenticated = Ref(false)
    timer = Timer(10.0) do _
        authenticated[] || close_transport_quietly!(ws)
    end
    try
        token = String(WebSockets.receive(ws))
        grant = lock(relay.lock) do
            grant = relay.closed ? nothing : get(relay.grants, token, nothing)
            grant === nothing && return nothing
            peer.owner = grant.owner
            relay.peers[id] = peer
            grant
        end
        grant === nothing && return
        authenticated[] = true
        registered = true
        writer = @async try
            write_mcp_peer(peer)
        catch e
            e isa InterruptException && rethrow()
        end
        send_control(relay.control, Dict("type" => "mcp_open", "channel" => id,
            "project_id" => grant.project_id, "host" => grant.host))
        for frame in ws
            send_control(relay.control, Dict("type" => "mcp_frame", "channel" => id,
                                            "frame" => String(frame)))
        end
    catch e
        (e isa EOFError || e isa Base.IOError || e isa WebSockets.WebSocketError) ||
            @warn "local MCP relay ended" exception = e
    finally
        close(timer)
        stop_mcp_peer!(peer)
        writer === nothing || wait(writer)
        lock(relay.lock) do; delete!(relay.peers, id); end
        if registered && !relay.closed
            try
                send_control(relay.control, Dict("type" => "mcp_close", "channel" => id))
            catch e
                e isa InterruptException && rethrow()
            end
        end
    end
end

function handle_mcp_relay_frame!(relay::MCPRelay, cmd::AbstractDict)
    peer = lock(relay.lock) do
        get(relay.peers, String(get(cmd, "channel", "")), nothing)
    end
    peer === nothing && return
    frame = get(cmd, "type", "") == "mcp_close" ? nothing : String(cmd["frame"])
    # Preserve frame order (particularly shutdown reply → close), but never
    # hold heartbeat/cancel delivery behind a slow local reader. Disconnect that
    # client if it exceeds the bounded queue; it cannot consume unbounded RAM.
    accepted = lock(peer.condition) do
        peer.closed && return false
        bytes = frame === nothing ? 0 : sizeof(frame)
        (length(peer.queue) >= 128 || peer.bytes + bytes > 16 * 1024 * 1024) && return false
        push!(peer.queue, frame)
        peer.bytes += bytes
        notify(peer.condition)
        true
    end
    accepted || stop_mcp_peer!(peer)
    return nothing
end

function Base.close(relay::MCPRelay)
    peers = lock(relay.lock) do
        relay.closed = true
        empty!(relay.grants)
        result = collect(values(relay.peers))
        empty!(relay.peers)
        result
    end
    foreach(stop_mcp_peer!, peers)
    close(relay.server)
    return nothing
end
