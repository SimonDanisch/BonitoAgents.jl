# ── LinkChannel: the websocket-shaped API ───────────────────────────────────
# Same contract as `HTTP.WebSocket` where its users depend on it:
#   * `send` sends one message (a String is text, bytes are binary);
#   * `receive` returns the next message as the type it was sent as, returns
#     messages already buffered before reporting a close, then throws
#     `WebSocketError` — `isok` for a clean close, not `isok` for an abort;
#   * a close from the peer is answered with a close, so either side closing
#     ends the channel both ways;
#   * sending on a closed channel throws `WebSocketError(1006)`;
#   * `for msg in ch` stops at a clean close.
# One difference, on purpose: `isclosed` turns true only once every message
# that arrived has been read. A websocket reports closed with messages still
# buffered, and a reader that checks `isclosed` before `receive` loses them.

"What the opener said this channel is for."
header(ch::LinkChannel) = ch.header

"The id of `ch` on its link (0 is the control channel)."
channel_id(ch::LinkChannel) = ch.id

closed_error(code::Integer, reason::AbstractString = "") =
    WebSockets.WebSocketError(WebSockets.CloseFrameBody(code, String(reason)))

# Caller holds the link lock.
function check_sendable(ch::LinkChannel)
    ch.aborted === nothing || throw(closed_error(1006, "channel aborted: $(ch.aborted)"))
    ch.local_closed && throw(closed_error(1006, "websocket is closed"))
    return nothing
end

function WebSockets.send(ch::LinkChannel, x::Union{AbstractString,AbstractVector{UInt8}})
    text = x isa AbstractString
    bytes = text ? Vector{UInt8}(codeunits(x)) : Vector{UInt8}(x)
    typeflag = text ? FLAG_TEXT : 0x00
    link = ch.link::Link
    n = length(bytes)
    lock(ch.sendlock) do
        lock(link.lock) do
            check_sendable(ch)
            if n == 0
                enqueue!(ch, Frame(F_DATA, ch.id; flags = FLAG_EOM | typeflag))
                return nothing
            end
            pos = 1
            while pos <= n
                while ch.send_credit <= 0
                    check_sendable(ch)
                    wait(ch.cond)           # credit from the peer, or a close/abort
                end
                check_sendable(ch)
                len = min(MAX_CHUNK, n - pos + 1, ch.send_credit)
                ch.send_credit -= len
                last = pos + len > n
                enqueue!(ch, Frame(F_DATA, ch.id; flags = (last ? FLAG_EOM : 0x00) | typeflag,
                                   payload = bytes[pos:(pos + len - 1)]))
                pos += len
            end
            return nothing
        end
    end
    return nothing
end

function WebSockets.receive(ch::LinkChannel)
    link = ch.link::Link
    return lock(link.lock) do
        while isempty(ch.inbox)
            ch.aborted === nothing || throw(closed_error(1011, ch.aborted))
            (ch.remote_closed || ch.local_closed) && throw(closed_error(1000))
            wait(ch.cond)
        end
        msg, text, owed = popfirst!(ch.inbox)
        # Credit goes back in batches, but never so late that the peer runs dry.
        ch.grant_pending += owed
        if ch.grant_pending > 0 &&
           (ch.grant_pending >= link.window ÷ 4 || ch.recv_allowance <= link.window ÷ 2)
            grant!(ch, ch.grant_pending)
            ch.grant_pending = 0
        end
        retire_if_done!(ch)
        text ? String(msg) : msg
    end
end

"""
    close(ch::LinkChannel)

Close `ch` cleanly: everything already sent is delivered first, then the peer's
`receive` reports a clean close. Anything still unread here is dropped.
"""
function Base.close(ch::LinkChannel)
    ch.id == 0 && throw(ArgumentError("the control channel ends with the link"))
    link = ch.link::Link
    lock(ch.sendlock) do              # after a message that is mid-send
        lock(link.lock) do
            (ch.local_closed || ch.aborted !== nothing) && return nothing
            ch.local_closed = true
            for (_, _, owed) in ch.inbox
                ch.grant_pending += owed
            end
            empty!(ch.inbox)
            grant!(ch, ch.grant_pending)
            ch.grant_pending = 0
            enqueue!(ch, Frame(F_CLOSE, ch.id))
            notify(ch.cond)
            return nothing
        end
    end
    return nothing
end

"""
    abort(ch, reason = "aborted")

End `ch` at once, both ways: nothing queued is delivered, and the peer's
`receive` throws a (non-`isok`) close carrying `reason`.
"""
function abort(ch::LinkChannel, reason::AbstractString = "aborted")
    ch.id == 0 && throw(ArgumentError("the control channel ends with the link"))
    link = ch.link::Link
    lock(link.lock) do
        ch.aborted === nothing || return nothing
        ch.aborted = String(reason)
        empty!(ch.outq)
        empty!(ch.inbox)
        delete!(link.channels, ch.id)
        enqueue_ctrl!(link, Frame(F_ABORT, ch.id; payload = Vector{UInt8}(codeunits(reason))))
        notify(ch.cond)
        return nothing
    end
    return nothing
end

WebSockets.isclosed(ch::LinkChannel) =
    lock((ch.link::Link).lock) do
        isempty(ch.inbox) && (ch.aborted !== nothing || (ch.local_closed && ch.remote_closed))
    end

Base.isopen(ch::LinkChannel) = !WebSockets.isclosed(ch)

function Base.iterate(ch::LinkChannel, _ = nothing)
    msg = try
        WebSockets.receive(ch)
    catch e
        (e isa WebSockets.WebSocketError && WebSockets.isok(e)) || rethrow()
        return nothing
    end
    return (msg, nothing)
end

Base.IteratorSize(::Type{LinkChannel}) = Base.SizeUnknown()
Base.eltype(::Type{LinkChannel}) = Union{String,Vector{UInt8}}

Base.show(io::IO, ch::LinkChannel) =
    print(io, "LinkChannel(", ch.id, ch.aborted !== nothing ? ", aborted" :
              ch.local_closed || ch.remote_closed ? ", closing" : "", ")")
