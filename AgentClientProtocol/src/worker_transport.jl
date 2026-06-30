# Worker WebSocket line-transport for the ACP `Connection` — the ONE concrete
# transport. An agent runs on a (possibly remote) worker that byte-relays the
# agent subprocess's stdio over the WebSocket it dials back on `/worker-acp`; the
# generic `Connection` drives line-level ACP frames through this transport over
# that socket. (The old local `SubprocessTransport` is gone: every agent now runs
# behind a worker, so the WS is the single transport for the whole stack.)
#
# The `ws` field is a `Ref{Any}` so the owner (a server-side `WorkerAgent`) can
# share the one socket: closing the `Connection`'s transport and the agent tears
# down the same `ws`.

mutable struct WorkerTransport <: Transport
    ws :: Ref{Any}
end

WorkerTransport() = WorkerTransport(Ref{Any}(nothing))

function send(t::WorkerTransport, line::AbstractString)
    ws = t.ws[]
    ws === nothing && return nothing
    # The worker session can end (ws write-closed) between a line being queued
    # and delivered — e.g. a `session/cancel` notification arriving just after
    # the agent's connection dropped ("ACP session ended"). A closed transport
    # has nothing to deliver; the connection's death is detected on the recv
    # side (returns ""), which tears down the read loop and fails any pending
    # requests. So drop the write instead of throwing the bare HTTP
    # `send() requires !(ws.writeclosed)` ArgumentError up through chat_dispatch!.
    HTTP.WebSockets.isclosed(ws) && return nothing
    try
        HTTP.WebSockets.send(ws, rstrip(line, '\n'))
    catch e
        # Race: write side closed between the isclosed check and the send.
        if e isa ArgumentError || e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError
            @debug "WorkerTransport.send: connection closed mid-write, dropping line" exception = e
            return nothing
        end
        rethrow(e)
    end
    return nothing
end

function recv(t::WorkerTransport)
    ws = t.ws[]
    # A nothing ws (never dialed, or `stop!` cleared it under a running reader)
    # is EOF — NOT an error. Without this guard `isclosed(nothing)` would throw a
    # MethodError up through the reader loop and get logged as a spurious "ACP
    # reader failed". Mirrors `send`/`close`/`transport_eof`'s nothing handling.
    ws === nothing && return ""
    HTTP.WebSockets.isclosed(ws) && return ""
    try
        return String(HTTP.WebSockets.receive(ws))
    catch e
        # `recv`'s contract: return "" on a CLEAN end-of-stream, throw on a real
        # failure. A clean WS close (normal / going-away) is EOF → "". Everything
        # else propagates: an IOError (peer reset) is teardown the reader loop
        # already treats as benign, and an ABNORMAL close (protocol error / 1011,
        # `isok` false) is a genuine fault the reader loop should log — NOT mask
        # as a clean disconnect. The old `IOError || WebSocketError → ""` blanket
        # swallowed both, hiding a crashed worker behind a tidy EOF.
        e isa HTTP.WebSockets.WebSocketError && HTTP.WebSockets.isok(e) && return ""
        rethrow(e)
    end
end

# `recv` returns "" both for a dead ws (isclosed) AND, in principle, for an empty
# frame. The `reader_loop` uses `transport_eof` to tell the two apart: without
# this method it falls to `transport_eof(::Transport) = false`, so when the worker
# WS closes (e.g. `stop_session!` → `close(transport)`) `recv` returns "" with no
# block, `reader_loop` `continue`s, and the loop hot-spins at 100% CPU on its
# (sticky, thread-1) task — starving every other server `@async` handler. A closed
# or never-dialed ws yields no more frames, so it IS EOF.
transport_eof(t::WorkerTransport) =
    (ws = t.ws[]; ws === nothing || HTTP.WebSockets.isclosed(ws))

function Base.close(t::WorkerTransport)
    ws = t.ws[]
    ws === nothing && return nothing
    HTTP.WebSockets.isclosed(ws) && return nothing
    try
        close(ws)
    catch e
        # Peer (worker) may have closed concurrently — that's the resource state
        # we want anyway. Only swallow the specific races; anything else is real.
        (e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError) || rethrow()
    end
    return nothing
end
