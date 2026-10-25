# ── Transports ──────────────────────────────────────────────────────────────
# One transport is one connection. A link outlives any number of them.
#
#   send_message(t, bytes)   one frame; throws when the connection is gone
#   receive_message(t)       the next frame, or `nothing` once the connection ended
#   close_transport(t)       end it NOW — never waits on a send that is stuck

abstract type Transport end

"""
    WebSocketTransport(ws)

A link connection over an `HTTP.WebSocket`. Frames are binary messages.
`wait(t)` returns once the connection has ended, which is how a websocket
handler knows it may return (HTTP closes the socket when it does).
"""
struct WebSocketTransport <: Transport
    ws::WebSockets.WebSocket
    ended::Base.Event
end
WebSocketTransport(ws::WebSockets.WebSocket) = WebSocketTransport(ws, Base.Event())

send_message(t::WebSocketTransport, bytes::Vector{UInt8}) = WebSockets.send(t.ws, bytes)

function receive_message(t::WebSocketTransport)
    msg = try
        WebSockets.receive(t.ws)
    catch e
        # How a connection ends is not an error of ours: a close frame (any
        # code), or the socket going away underneath. Everything else is.
        (e isa WebSockets.WebSocketError || e isa Base.IOError || e isa EOFError) ||
            rethrow()
        return nothing
    end
    msg isa AbstractVector{UInt8} ||
        throw(ProtocolError("text message on a WorkerLink connection"))
    return msg isa Vector{UInt8} ? msg : Vector{UInt8}(msg)   # no copy when it already is one
end

# The transport-level kill, not `close(ws)`: a polite close takes the socket's
# send lock, which a send wedged on a full TCP buffer holds forever. Every way a
# connection ends comes through here (the reader seeing it end, a failed send,
# a newer connection taking over, the link dying, a failed handshake).
function close_transport(t::WebSocketTransport)
    try
        t.ws.close_transport!()
    finally
        notify(t.ended)
    end
    return nothing
end

Base.wait(t::WebSocketTransport) = wait(t.ended)

"""
    MemoryTransport

One end of an in-process connection (see [`memory_pair`](@ref)). Used by the
tests, and to run a link inside one process.
"""
struct MemoryTransport <: Transport
    inbox::Base.Channel{Vector{UInt8}}
    outbox::Base.Channel{Vector{UInt8}}
end

"Two connected [`MemoryTransport`](@ref) ends."
function memory_pair()
    a_to_b = Base.Channel{Vector{UInt8}}(Inf)
    b_to_a = Base.Channel{Vector{UInt8}}(Inf)
    return MemoryTransport(b_to_a, a_to_b), MemoryTransport(a_to_b, b_to_a)
end

send_message(t::MemoryTransport, bytes::Vector{UInt8}) = put!(t.outbox, copy(bytes))

function receive_message(t::MemoryTransport)
    try
        return take!(t.inbox)
    catch e
        e isa InvalidStateException || rethrow()
        return nothing
    end
end

# Both directions die together, like a dropped TCP connection.
function close_transport(t::MemoryTransport)
    close(t.inbox)
    close(t.outbox)
    return nothing
end

# Bound a receive that may never return (a peer that accepts the connection and
# then says nothing): after `timeout` seconds the transport is killed, which ends
# the receive.
function receive_message(t::Transport, timeout::Real)
    done = Threads.Atomic{Bool}(false)
    timer = Timer(timeout) do _
        done[] || close_transport(t)
    end
    try
        return receive_message(t)
    finally
        done[] = true
        close(timer)
    end
end
