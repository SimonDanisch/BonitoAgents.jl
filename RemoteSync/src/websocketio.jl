# IO-like adapter that turns a frame-oriented transport (e.g. an
# HTTP.WebSocket) into a byte stream the librsync drive loop and our wire
# protocol can use directly. We present a byte-stream view by buffering the
# latest received frame and serving `read`/`readbytes!` requests out of it.
#
# `WebSocketIO{WS}` stays parametric so callers can plug in any frame-oriented
# transport that implements `send_frame!` / `recv_frame` / `is_closed`. We
# also ship adapters for HTTP.WebSockets.WebSocket inline below; those used to
# live in a package extension, but the extension boundary added complexity
# (load-order races, methods missing in some sessions) without buying us
# anything — every consumer of RemoteSync also pulls in HTTP, so just depend
# on it directly.

using HTTP, HTTP.WebSockets

mutable struct WebSocketIO{WS} <: IO
    ws        :: WS
    inbuf     :: Vector{UInt8}        # bytes from the last received frame
    inpos     :: Int                  # next byte of inbuf to deliver (1-based)
    outbuf    :: IOBuffer             # accumulates writes until `flush`
    closed    :: Bool
    eof_seen  :: Bool                 # true once the peer has closed
    wlock     :: ReentrantLock        # serializes concurrent multi-write messages (Malt _serialize_msg)
    # The read path (`inbuf`/`inpos`) is SINGLE-CONSUMER by contract — frames
    # arrive in order on one ws and `_refill!` mutates shared cursor state with
    # no lock. A second concurrent reader would interleave `inpos` updates and
    # silently corrupt the byte stream. We can't make the read path safe for two
    # readers cheaply (the whole frame-reassembly model assumes one), so instead
    # we DETECT a second concurrent reader and throw, turning latent corruption
    # into a loud, immediate error (R5). `reader` holds the owning task while a
    # read is in progress (reentrant for that task, which lets the higher-level
    # `read(io, n)` delegate to `readbytes!`).
    @atomic reader :: Union{Task,Nothing}
end

WebSocketIO(ws) = WebSocketIO{typeof(ws)}(ws, UInt8[], 1, IOBuffer(), false, false, ReentrantLock(), nothing)

# Enforce the single-consumer read contract (R5): claim the read guard for the
# duration of `f`, throwing if a DIFFERENT task already holds it. Same-task
# reentry is allowed (our `read`/`readbytes!`/`unsafe_read` nest), and only the
# outermost call releases the guard.
function with_read_guard(f, io::WebSocketIO)
    me = current_task()
    owner, won = @atomicreplace io.reader nothing => me
    if !won && owner !== me
        error("WebSocketIO: concurrent read detected — the read path is single-consumer only")
    end
    try
        return f()
    finally
        won && (@atomic io.reader = nothing)
    end
end

# Transport surface: receive the next frame (returns `nothing` on close),
# send one frame, and report whether the underlying transport is closed.
# Generic stubs for non-HTTP transports; HTTP.WebSocket impls follow.
function recv_frame end
function send_frame! end
function is_closed end

function recv_frame(ws::HTTP.WebSockets.WebSocket)
    try
        HTTP.WebSockets.isclosed(ws) && return nothing
        frame = HTTP.WebSockets.receive(ws)
        return frame isa AbstractVector{UInt8} ?
            Vector{UInt8}(frame) :
            Vector{UInt8}(codeunits(String(frame)))
    catch e
        e isa HTTP.WebSockets.WebSocketError && return nothing
        e isa Base.IOError                   && return nothing
        e isa EOFError                       && return nothing
        rethrow()
    end
end

function send_frame!(ws::HTTP.WebSockets.WebSocket, bytes::AbstractVector{UInt8})
    HTTP.WebSockets.send(ws, bytes)
    return nothing
end

# HTTP 2's websocket refuses any single incoming message above 16 MiB: it closes
# the connection with 1009, and the PEER's limit is not ours to raise. To the
# receiver everything we send is one byte stream (`_refill!` concatenates
# messages), so a logical frame may cross in as many messages as it needs. A
# whole-file delta used to go as one message; a 57 MB file then closed the
# socket under the sender, which saw "Broken pipe" while the receiver saw EOF
# (2026-09-15). 1 MiB matches `FILE_CHUNK_BYTES` and bounds the allocation per
# message on both ends.
const MAX_WS_MESSAGE_BYTES = 1 * 1024 * 1024

function send_chunked!(ws, bytes::Vector{UInt8})
    n = length(bytes)
    n <= MAX_WS_MESSAGE_BYTES && return send_frame!(ws, bytes)
    for start in 1:MAX_WS_MESSAGE_BYTES:n
        send_frame!(ws, bytes[start:min(start + MAX_WS_MESSAGE_BYTES - 1, n)])
    end
    return nothing
end

is_closed(ws::HTTP.WebSockets.WebSocket) = HTTP.WebSockets.isclosed(ws)

# ── IO interface ───────────────────────────────────────────────────────────
function _refill!(io::WebSocketIO)
    io.eof_seen && return false
    frame = recv_frame(io.ws)
    if frame === nothing
        io.eof_seen = true
        return false
    end
    io.inbuf = frame
    io.inpos = 1
    return true
end

function Base.eof(io::WebSocketIO)
    io.inpos <= length(io.inbuf) && return false
    return with_read_guard(io) do
        # Re-check after taking the guard: another (single) reader run could
        # have refilled between the fast-path check and here.
        io.inpos <= length(io.inbuf) && return false
        return !_refill!(io)
    end
end

Base.isopen(io::WebSocketIO) = !io.closed && !is_closed(io.ws)

function Base.close(io::WebSocketIO)
    io.closed && return
    io.closed = true
    # Flush whatever's still buffered before tearing the socket down. A failure
    # here means the last chunk didn't make it (R4): log it, don't swallow it —
    # the caller's transfer is incomplete and silently "succeeding" hides that.
    # We still proceed to close the ws regardless so the fd is released.
    try
        # `position` rather than `bytesavailable`: after a series of writes,
        # `bytesavailable(IOBuffer)` returns 0 (it counts unread bytes from
        # the current position, not the total writes pending).
        position(io.outbuf) > 0 && send_chunked!(io.ws, take!(io.outbuf))
    catch e
        @warn "WebSocketIO: final flush failed on close (last chunk may be lost)" exception=(e, catch_backtrace())
    end
    # Actually close the underlying socket (R4) — previously the ws was left
    # open until GC. Idempotent-friendly: tolerate an already-closed ws.
    try
        close_ws!(io.ws)
    catch e
        e isa HTTP.WebSockets.WebSocketError && return nothing
        e isa Base.IOError                   && return nothing
        e isa EOFError                       && return nothing
        @warn "WebSocketIO: error closing underlying ws" exception=(e, catch_backtrace())
    end
    return nothing
end

# Block until the PEER closes its end of the connection. A sender calls this
# after writing its last frame instead of closing immediately: closing an
# HTTP.WebSocket can truncate frames the peer hasn't drained yet (proven flaky —
# a small file transfer EOFs the receiver ~90% of the time under load). The
# receiver knows when it has everything and closes first; the sender waits here
# so its own close can't race the tail. Any stray frame the peer sends is
# discarded. Returns when the peer is gone (clean EOF / close errors only).
function wait_peer_close(io::WebSocketIO)
    try
        while !eof(io)                        # blocks in _refill! until a frame or close
            io.inpos = length(io.inbuf) + 1   # discard it (the file protocol sends nothing here)
        end
    catch e
        (e isa EOFError || e isa Base.IOError ||
         e isa HTTP.WebSockets.WebSocketError) || rethrow()
    end
    return nothing
end

# Close the underlying transport. Generic stub for non-HTTP transports; the
# HTTP.WebSocket impl follows.
function close_ws! end
close_ws!(ws::HTTP.WebSockets.WebSocket) = close(ws)

Base.read(io::WebSocketIO, ::Type{UInt8}) = with_read_guard(io) do
    while io.inpos > length(io.inbuf)
        _refill!(io) || throw(EOFError())
    end
    b = io.inbuf[io.inpos]
    io.inpos += 1
    return b
end

Base.readbytes!(io::WebSocketIO, dst::Vector{UInt8}, n = length(dst)) = with_read_guard(io) do
    n = Int(n)
    n > length(dst) && resize!(dst, n)
    written = 0
    while written < n
        avail = length(io.inbuf) - io.inpos + 1
        if avail == 0
            _refill!(io) || break
            avail = length(io.inbuf) - io.inpos + 1
            avail == 0 && break
        end
        take = min(avail, n - written)
        @inbounds copyto!(dst, written + 1, io.inbuf, io.inpos, take)
        io.inpos += take
        written  += take
    end
    return written
end

# Read exactly `n` bytes or throw EOFError. Matches `Base.read(io, n)` shape
# used by our wire protocol's read_frame.
function Base.read(io::WebSocketIO, n::Integer)
    n = Int(n)
    out = Vector{UInt8}(undef, n)
    got = readbytes!(io, out, n)
    got == n || throw(EOFError())
    return out
end

# Buffered writes: librsync makes lots of small writes during signature/delta
# generation. We coalesce them per `flush`, which matches our wire protocol
# (write_frame ends with flush), and split anything over `MAX_WS_MESSAGE_BYTES`.
function Base.write(io::WebSocketIO, b::UInt8)
    write(io.outbuf, b)
    return 1
end

function Base.unsafe_write(io::WebSocketIO, p::Ptr{UInt8}, n::UInt)
    return UInt(unsafe_write(io.outbuf, p, n))
end

function Base.flush(io::WebSocketIO)
    # See note in `close` — must use `position`, not `bytesavailable`.
    position(io.outbuf) == 0 && return nothing
    send_chunked!(io.ws, take!(io.outbuf))
    return nothing
end

# Read exactly `n` bytes into `p`, refilling frames as needed (or throw EOFError).
# Needed by `Serialization.deserialize` and `read(io, ::Type{T})` for bitstypes
# (e.g. the UInt64 message id in the Malt wire protocol).
Base.unsafe_read(io::WebSocketIO, p::Ptr{UInt8}, n::UInt) = with_read_guard(io) do
    nr = 0
    while nr < n
        if io.inpos > length(io.inbuf)
            _refill!(io) || throw(EOFError())
        end
        avail = length(io.inbuf) - io.inpos + 1
        take = min(avail, Int(n) - nr)
        GC.@preserve io unsafe_copyto!(p + nr, pointer(io.inbuf, io.inpos), take)
        io.inpos += take
        nr += take
    end
    return nothing
end

# Lock so concurrent multi-`write` messages (Malt's `_serialize_msg`: type, id,
# serialized payload, boundary, flush) don't interleave into `outbuf`.
Base.lock(io::WebSocketIO)    = lock(io.wlock)
Base.unlock(io::WebSocketIO)  = unlock(io.wlock)
Base.trylock(io::WebSocketIO) = trylock(io.wlock)
