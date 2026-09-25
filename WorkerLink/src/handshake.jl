# ── Handshake ───────────────────────────────────────────────────────────────
# The first message in each direction of every new connection:
#
#   HELLO   client → server   "WLK1" 0x01  link id (16)  last received (u64)  window (u64)  app bytes
#   WELCOME server → client   "WLK1" 0x02  resumed (u8)  last received (u64)  window (u64)  app bytes
#   REFUSE  server → client   "WLK1" 0x03  reason (UTF-8)
#
# `last received` is what makes a resume lossless: each side replays everything
# the other has not got. The app bytes are opaque here — the application's own
# hello and its answer (credentials, identity, configuration).

const MAGIC = UInt8['W', 'L', 'K', '1']
const M_HELLO   = 0x01
const M_WELCOME = 0x02
const M_REFUSE  = 0x03

"The server refused the connection; `reason` is its explanation."
struct LinkRefused <: Exception
    reason::String
end
Base.showerror(io::IO, e::LinkRefused) = print(io, "WorkerLink: connection refused: ", e.reason)

"A client's hello, as the server reads it."
struct Hello
    link_id::Vector{UInt8}
    last_received::UInt64
    window::Int
    app::Vector{UInt8}
end

function check_magic(msg::AbstractVector{UInt8}, kind::UInt8)
    length(msg) >= 5 && msg[1:4] == MAGIC ||
        throw(ProtocolError("not a WorkerLink handshake"))
    msg[5] == M_REFUSE && throw(LinkRefused(String(msg[6:end])))
    msg[5] == kind || throw(ProtocolError("expected handshake message $(kind), got $(msg[5])"))
    return nothing
end

"""
    connect!(link, transport, hello; timeout = 30) -> Vector{UInt8}

The client's side of a new connection: send `hello` (application bytes), wait
for the server's answer, and attach. Returns the server's application reply.

If the server does not know this link — it restarted, or the grace period ran
out — the link is RESET first: every channel, the control channel included, is
aborted with "link reset", and the link starts again from nothing. Fetch the new
control channel with [`control_channel`](@ref).

Throws [`LinkRefused`](@ref) when the server says no.
"""
function connect!(link::Link, t::Transport, hello::Vector{UInt8}; timeout::Real = 30)
    link.role === :client || throw(ArgumentError("connect! is the client's side"))
    last, fresh = lock(() -> (link.last_received, !link.attached_once), link.lock)
    reply = try
        send_message(t, vcat(MAGIC, M_HELLO, link.id, u64_bytes(last), u64_bytes(link.window), hello))
        msg = receive_message(t, timeout)
        msg === nothing &&
            throw(ProtocolError("the server did not answer the handshake within $(timeout)s"))
        check_magic(msg, M_WELCOME)
        length(msg) >= 22 || throw(ProtocolError("truncated welcome"))
        Int(read_u64(msg, 15)) == link.window ||
            throw(ProtocolError("window mismatch: server $(read_u64(msg, 15)), client $(link.window)"))
        msg
    catch
        close_transport(t)          # a failed handshake leaves no half-open connection
        rethrow()
    end
    resumed = reply[6] == 0x01
    # A link that never had a connection has nothing the server could have lost.
    (resumed || fresh) || reset!(link, "link reset")
    attach!(link, t, resumed ? read_u64(reply, 7) : UInt64(0))
    return reply[23:end]
end

"""
    read_hello(transport; timeout = 10) -> Hello

The server's first step on a new connection. Throws `ProtocolError` for
anything that is not a hello within `timeout` seconds.
"""
function read_hello(t::Transport; timeout::Real = 10)
    msg = receive_message(t, timeout)
    msg === nothing && throw(ProtocolError("no hello within $(timeout)s"))
    check_magic(msg, M_HELLO)
    length(msg) >= 37 || throw(ProtocolError("truncated hello"))
    return Hello(msg[6:21], read_u64(msg, 22), Int(read_u64(msg, 30)), msg[38:end])
end

"""
    welcome!(link, transport, hello, reply; resumed)

Accept a client: answer with `reply` (application bytes) and attach `link`.
`resumed` is true when `link` is the one this client had before (same id, not
dead); then everything the client missed is replayed. For a new or restarted
client pass a fresh `Link(:server; id = hello.link_id)` and `resumed = false`.
"""
function welcome!(link::Link, t::Transport, hello::Hello, reply::Vector{UInt8}; resumed::Bool)
    link.role === :server || throw(ArgumentError("welcome! is the server's side"))
    hello.window == link.window ||
        throw(ProtocolError("window mismatch: client $(hello.window), server $(link.window)"))
    last = lock(() -> link.last_received, link.lock)
    send_message(t, vcat(MAGIC, M_WELCOME, resumed ? 0x01 : 0x00, u64_bytes(last),
                         u64_bytes(link.window), reply))
    attach!(link, t, resumed ? hello.last_received : UInt64(0))
    return link
end

"Turn a client away with `reason`, and end the connection."
function refuse(t::Transport, reason::AbstractString)
    try
        send_message(t, vcat(MAGIC, M_REFUSE, Vector{UInt8}(codeunits(reason))))
    finally
        close_transport(t)
    end
    return nothing
end

# Start over: the server no longer has our state. Caller must not hold the lock.
function reset!(link::Link, reason::AbstractString)
    lock(link.lock) do
        for ch in values(link.channels)
            ch.aborted = String(reason)
            empty!(ch.outq)
            notify(ch.cond)
        end
        empty!(link.channels)
        for q in link.ready
            empty!(q)
        end
        empty!(link.ctrl)
        empty!(link.urgent)
        empty!(link.log)
        link.cursor = 1
        link.next_seq = UInt64(1)
        link.last_received = UInt64(0)
        link.last_ack_sent = UInt64(0)
        link.next_channel = link.role === :client ? UInt32(1) : UInt32(2)
        link.channels[0] = new_channel(link, UInt32(0), 0, UInt8[])
        return nothing
    end
end
