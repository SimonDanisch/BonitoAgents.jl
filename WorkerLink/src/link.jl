# ── Link ────────────────────────────────────────────────────────────────────
# The logical connection between one worker and the server. It outlives the
# transports it runs over: when a connection drops, the link is DETACHED and
# every channel waits; a new connection within `grace` seconds resumes it,
# replaying what the peer did not get. After `grace` it is DEAD and every
# channel is aborted.
#
# One writer task per link owns all sending, so nothing ever contends for the
# transport. It picks the next frame by priority at the moment it can send, and
# data is cut into ≤64 KiB pieces, so a control message waits behind at most one
# piece of bulk data.

const MAX_CHUNK = 64 * 1024
const DEFAULT_WINDOW = 1024 * 1024
const NPRIORITIES = 4          # 0 (most urgent) … 3

# Lets a channel name its link's type before `Link` is defined.
abstract type AbstractLink end

"""
    LinkChannel

A bidirectional, message-oriented stream on a [`Link`](@ref). It implements the
subset of `HTTP.WebSocket` its users rely on — `WebSockets.send`,
`WebSockets.receive`, `WebSockets.isclosed`, `close`, iteration — with the same
close semantics, so code written against a websocket runs on it unchanged.
"""
mutable struct LinkChannel
    link::AbstractLink
    id::UInt32
    priority::Int
    header::Vector{UInt8}       # what the opener said this channel is for
    cond::Threads.Condition     # on link.lock: data, credit, close, abort
    sendlock::ReentrantLock     # one message at a time: pieces of two never interleave
    # sending
    outq::Vector{Frame}         # OPEN / DATA / CLOSE, in channel order
    send_credit::Int            # bytes the peer will still accept
    local_closed::Bool
    # receiving
    inbox::Vector{Tuple{Vector{UInt8},Bool,Int}}   # (message, is_text, credit owed on consume)
    assembling::Vector{UInt8}
    assembling_credited::Int    # bytes of `assembling` already credited back
    recv_allowance::Int         # bytes the peer may still send
    grant_pending::Int          # consumed but not yet credited back
    remote_closed::Bool
    aborted::Union{Nothing,String}
end

mutable struct Link <: AbstractLink
    role::Symbol                # :client (odd channel ids) or :server (even)
    id::Vector{UInt8}           # 16 bytes, chosen by the client
    lock::ReentrantLock
    wake::Threads.Condition     # the writer's
    state::Symbol               # :detached, :connected, :dead
    channels::Dict{UInt32,LinkChannel}
    next_channel::UInt32
    ready::Vector{Vector{UInt32}}   # per priority: channels with something to send, round robin
    ctrl::Vector{Frame}         # sequenced frames that jump the channel queues (CREDIT, ABORT)
    urgent::Vector{Vector{UInt8}}   # connection frames (ACK, PING, PONG): never logged
    # the replay log: sequenced frames sent (or about to be) and not yet acknowledged
    next_seq::UInt64
    log::Vector{Tuple{UInt64,Vector{UInt8}}}
    cursor::Int                 # next log entry to put on the current connection
    last_received::UInt64       # highest sequenced frame taken in order
    last_ack_sent::UInt64
    # connection
    transport::Union{Nothing,Transport}
    generation::Int             # bumped per attach/detach: stale tasks know to stop
    last_rx::Float64
    last_ping::Float64
    # How long the last ping took to come back (NaN before the first): what a
    # small message waits behind whatever the connection is carrying, which the
    # priorities here cannot reorder once it is in the socket. Slow ones are
    # logged (`SLOW_PING_S`), at most once a minute (`slow_logged_at`).
    ping_sent::Float64           # when the ping being waited for went out; 0 if none
    ping_rtt::Float64
    slow_logged_at::Float64
    detached_at::Float64
    # The ticker sleeps until its next deadline (`tick!`); this wakes it sooner:
    # an acknowledgement fell due, the connection changed, liveness was retuned.
    tick::Base.Event
    ack_due::Float64             # when the received frames not yet acknowledged must be
    peer_window::Int
    # configuration
    window::Int
    grace::Float64
    ping_interval::Float64
    ping_deadline::Float64
    # Any callable, not just a `Function`: a handler is often a struct.
    on_open::Any                # (ch::LinkChannel) -> anything; a peer opened `ch`
    on_state::Any               # (link, state::Symbol) -> anything
    dead_reason::String
    attached_once::Bool         # a link that was never connected has nothing to reset
    name::String                # who is at the other end, for the log ("" if nobody said)
end

"""
    Link(role; window, grace, ping_interval, ping_deadline, on_open, on_state, id, name)

A link endpoint. `role` is `:client` (the worker, which dials) or `:server`.
`on_open(ch)` runs (in its own task) for every channel the PEER opens;
`on_state(link, state)` for every `:connected` / `:detached` / `:dead` change,
and with `:reset` when a client's link restarts from nothing (see [`connect!`](@ref)).
Channel 0 exists from the start on both sides: see [`control_channel`](@ref).
`name` says who is at the other end in this side's log.
"""
function Link(role::Symbol;
              window::Int = DEFAULT_WINDOW, grace::Real = 300.0,
              ping_interval::Real = 15.0, ping_deadline::Real = 45.0,
              on_open = ch -> abort(ch, "no channels are accepted here"),
              on_state = (link, state) -> nothing,
              id::Vector{UInt8} = rand(UInt8, 16),
              name::AbstractString = "")
    role in (:client, :server) || throw(ArgumentError("role must be :client or :server"))
    lk = ReentrantLock()
    link = Link(role, id, lk, Threads.Condition(lk), :detached,
                Dict{UInt32,LinkChannel}(), role === :client ? UInt32(1) : UInt32(2),
                [UInt32[] for _ in 1:NPRIORITIES], Frame[], Vector{UInt8}[],
                UInt64(1), Tuple{UInt64,Vector{UInt8}}[], 1, UInt64(0), UInt64(0),
                nothing, 0, 0.0, 0.0, 0.0, NaN, 0.0, time(), Base.Event(true), 0.0, window,
                window, Float64(grace), Float64(ping_interval), Float64(ping_deadline),
                on_open, on_state, "", false, String(name))
    lock(lk) do
        link.channels[0] = new_channel(link, UInt32(0), 0, UInt8[])
    end
    errormonitor(Threads.@spawn writer_loop(link))
    errormonitor(Threads.@spawn ticker_loop(link))
    return link
end

# The application's handlers, in the LATEST world. A spawned task inherits its
# parent's world, and the reader and ticker of a link run for as long as it
# lives: a handler redefined since then (Revise) would otherwise never run.
notify_open(link::Link, ch::LinkChannel) = Base.invokelatest(link.on_open, ch)
notify_state(link::Link, st::Symbol) = Base.invokelatest(link.on_state, link, st)

new_channel(link::Link, id::UInt32, priority::Int, header::Vector{UInt8}) =
    LinkChannel(link, id, priority, header, Threads.Condition(link.lock), ReentrantLock(),
                Frame[], link.peer_window, false,
                Tuple{Vector{UInt8},Bool,Int}[], UInt8[], 0, link.window, 0, false, nothing)

"The control channel (id 0): present on both sides from the start, never closed."
control_channel(link::Link) = lock(link.lock) do
    link.state === :dead && throw(LinkDead(link.dead_reason))
    link.channels[0]
end

"`:connected`, `:detached` or `:dead`."
state(link::Link) = lock(() -> link.state, link.lock)

"The link's id: chosen by the client, sent in every hello, the key to resuming."
link_id(link::Link) = link.id

"""
    set_liveness!(link; ping_interval, ping_deadline)

Change how often `link` pings, and how long it waits for traffic before it
drops the connection. Takes effect at the next tick.
"""
function set_liveness!(link::Link; ping_interval::Real, ping_deadline::Real)
    lock(link.lock) do
        link.ping_interval = Float64(ping_interval)
        link.ping_deadline = Float64(ping_deadline)
    end
    notify(link.tick)
    return link
end

"""
    open_channel(link, header; priority = 1) -> LinkChannel

Open a channel to the peer, whose `on_open` gets it with `header` (the opener's
description of what it is for — this package does not interpret it). Lower
`priority` is more urgent: 0 … $(NPRIORITIES - 1).
"""
function open_channel(link::Link, header::Vector{UInt8}; priority::Int = 1)
    0 <= priority < NPRIORITIES || throw(ArgumentError("priority must be in 0:$(NPRIORITIES - 1)"))
    return lock(link.lock) do
        link.state === :dead && throw(LinkDead(link.dead_reason))
        id = link.next_channel
        link.next_channel += UInt32(2)
        ch = new_channel(link, id, priority, header)
        link.channels[id] = ch
        enqueue!(ch, Frame(F_OPEN, id; payload = vcat(UInt8(priority), header)))
        ch
    end
end

"The link is gone for good; nothing on it will work again."
struct LinkDead <: Exception
    reason::String
end
Base.showerror(io::IO, e::LinkDead) = print(io, "WorkerLink: link is dead (", e.reason, ")")

# ── sending ──────────────────────────────────────────────────────────────────

# Queue a channel frame, keeping channel order. Caller holds link.lock.
function enqueue!(ch::LinkChannel, f::Frame)
    link = ch.link::Link
    was_idle = isempty(ch.outq)
    push!(ch.outq, f)
    was_idle && push!(link.ready[ch.priority + 1], ch.id)
    notify(link.wake)
    return nothing
end

# A sequenced frame that must not wait behind channel data. Caller holds the lock.
function enqueue_ctrl!(link::Link, f::Frame)
    push!(link.ctrl, f)
    notify(link.wake)
    return nothing
end

# A connection frame for the current transport only. Caller holds the lock.
function enqueue_urgent!(link::Link, f::Frame)
    link.state === :connected || return nothing
    push!(link.urgent, encode(f))
    notify(link.wake)
    return nothing
end

# The next sequenced frame to put on the wire, by priority, round robin within a
# priority; `nothing` when there is none. Caller holds the lock.
function next_frame!(link::Link)
    isempty(link.ctrl) || return popfirst!(link.ctrl)
    for queue in link.ready
        while !isempty(queue)
            id = popfirst!(queue)
            ch = get(link.channels, id, nothing)
            (ch === nothing || isempty(ch.outq)) && continue
            f = popfirst!(ch.outq)
            isempty(ch.outq) || push!(queue, id)
            f.kind == F_CLOSE && retire_if_done!(ch)
            return f
        end
    end
    return nothing
end

function writer_loop(link::Link)
    while true
        job = lock(link.lock) do
            while true
                link.state === :dead && return nothing
                if link.state === :connected
                    t = link.transport::Transport
                    isempty(link.urgent) || return (t, popfirst!(link.urgent))
                    if link.cursor <= length(link.log)
                        bytes = link.log[link.cursor][2]
                        link.cursor += 1
                        return (t, bytes)
                    end
                    f = next_frame!(link)
                    if f !== nothing
                        seq = link.next_seq
                        link.next_seq += 1
                        bytes = encode(Frame(f.kind, f.flags, f.channel, seq, f.payload))
                        push!(link.log, (seq, bytes))
                        link.cursor = length(link.log) + 1
                        return (t, bytes)
                    end
                end
                # Detached: frames stay in their queues, so priority still
                # applies once a new connection is attached.
                wait(link.wake)
            end
        end
        job === nothing && return nothing
        t, bytes = job
        try
            send_message(t, bytes)
        catch e
            e isa InterruptException && rethrow()
            # The connection is gone. What was being sent stays in the log (or
            # was a connection frame, which dies with the connection anyway).
            connection_lost!(link, t, sprint(showerror, e))
        end
    end
end

# ── receiving ────────────────────────────────────────────────────────────────

function reader_loop(link::Link, t::Transport)
    reason = "connection closed"
    try
        while true
            bytes = receive_message(t)
            bytes === nothing && break
            handle_frame!(link, t, decode(bytes))
        end
    catch e
        e isa InterruptException && rethrow()
        if e isa ProtocolError
            # A bug on one side. Replaying would hit it again: start over clean.
            @error "WorkerLink: protocol error, link reset" exception = (e, catch_backtrace())
            kill!(link, sprint(showerror, e))
            close_transport(t)          # `kill!` only closes the CURRENT connection
            return nothing
        end
        reason = sprint(showerror, e)
    end
    connection_lost!(link, t, reason)
    return nothing
end

function handle_frame!(link::Link, t::Transport, f::Frame)
    opened = nothing
    lock(link.lock) do
        link.transport === t || return nothing       # a stale connection's leftovers
        link.last_rx = time()
        k = f.kind
        if k == F_ACK
            trim_log!(link, f.seq)
        elseif k == F_PING
            enqueue_urgent!(link, Frame(F_PONG, 0))
        elseif k == F_PONG
            # Besides `last_rx` above: how long it took. Pongs come back in the
            # order their pings went, so one arriving while a ping is waited for
            # answers that one.
            link.ping_sent > 0.0 && pong_received!(link, link.last_rx)
        elseif is_sequenced(k)
            f.seq <= link.last_received && return nothing   # replayed, already have it
            f.seq == link.last_received + 1 ||
                throw(ProtocolError("frame $(f.seq) after $(link.last_received)"))
            link.last_received = f.seq
            if link.last_received - link.last_ack_sent >= 64
                send_ack!(link)
            elseif link.last_received == link.last_ack_sent + 1
                # The first frame not acknowledged: the ticker acks it shortly.
                link.ack_due = link.last_rx + ACK_DELAY_S
                notify(link.tick)
            end
            opened = apply_sequenced!(link, f)
        else
            throw(ProtocolError("unknown frame kind $(k)"))
        end
        return nothing
    end
    # Outside the lock, in its own task: the handler may block (pairing with a
    # waiting caller, spawning a process) and must never stall the reader.
    opened === nothing || errormonitor(Threads.@spawn notify_open(link, opened))
    return nothing
end

# Returns a channel the peer just opened, or nothing. Caller holds the lock.
function apply_sequenced!(link::Link, f::Frame)
    k = f.kind
    if k == F_OPEN
        isempty(f.payload) && throw(ProtocolError("OPEN without priority"))
        iseven(f.channel) == (link.role === :client) ||
            throw(ProtocolError("peer opened channel $(f.channel) from our id range"))
        haskey(link.channels, f.channel) && throw(ProtocolError("channel $(f.channel) opened twice"))
        ch = new_channel(link, f.channel, Int(min(f.payload[1], NPRIORITIES - 1)), f.payload[2:end])
        link.channels[f.channel] = ch
        return ch
    end
    ch = get(link.channels, f.channel, nothing)
    if ch === nothing
        # We retired it (closed or aborted on our side): data still in flight is
        # dropped, and its credit returned so the peer never blocks on us.
        k == F_DATA && enqueue_ctrl!(link, Frame(F_CREDIT, f.channel; payload = u64_bytes(length(f.payload))))
        return nothing
    end
    if k == F_DATA
        n = length(f.payload)
        ch.recv_allowance -= n
        ch.recv_allowance < 0 &&
            throw(ProtocolError("channel $(ch.id): $(n) bytes beyond the granted window"))
        if ch.aborted !== nothing || ch.local_closed
            grant!(ch, n)                      # nobody will read it; keep the peer moving
            return nothing
        end
        eom = f.flags & FLAG_EOM != 0
        if eom && isempty(ch.assembling)
            # A message in one piece: its payload IS the message, no reassembly copy.
            push!(ch.inbox, (f.payload, f.flags & FLAG_TEXT != 0, length(f.payload)))
            notify(ch.cond)
            return nothing
        end
        append!(ch.assembling, f.payload)
        if eom
            msg = ch.assembling
            owed = length(msg) - ch.assembling_credited
            push!(ch.inbox, (msg, f.flags & FLAG_TEXT != 0, owed))
            ch.assembling = UInt8[]
            ch.assembling_credited = 0
            notify(ch.cond)
        else
            # A message larger than the window would deadlock (the reader waits
            # for its end, the sender for credit), so a growing partial message is
            # credited as it arrives.
            partial = length(ch.assembling) - ch.assembling_credited
            if partial >= link.window ÷ 2
                grant!(ch, partial)
                ch.assembling_credited += partial
            end
        end
    elseif k == F_CREDIT
        ch.send_credit += Int(read_u64(f.payload))
        notify(ch.cond)
    elseif k == F_CLOSE
        ch.remote_closed = true
        # Answered like a websocket close: this side is done sending too. What
        # already arrived stays readable.
        if !ch.local_closed
            ch.local_closed = true
            enqueue!(ch, Frame(F_CLOSE, ch.id))
        end
        notify(ch.cond)
        retire_if_done!(ch)
    elseif k == F_ABORT
        ch.aborted = String(copy(f.payload))
        empty!(ch.outq)
        notify(ch.cond)
        delete!(link.channels, ch.id)
    end
    return nothing
end

# Give the peer `n` more bytes of window on `ch`. Caller holds the lock.
function grant!(ch::LinkChannel, n::Int)
    n > 0 || return nothing
    ch.recv_allowance += n
    enqueue_ctrl!(ch.link::Link, Frame(F_CREDIT, ch.id; payload = u64_bytes(n)))
    return nothing
end

function send_ack!(link::Link)
    link.last_ack_sent = link.last_received
    enqueue_urgent!(link, Frame(F_ACK, 0; seq = link.last_received))
    return nothing
end

# Drop log entries the peer has. Caller holds the lock.
function trim_log!(link::Link, upto::UInt64)
    n = 0
    while n < length(link.log) && link.log[n + 1][1] <= upto
        n += 1
    end
    n == 0 && return nothing
    deleteat!(link.log, 1:n)
    link.cursor = max(1, link.cursor - n)
    return nothing
end

# Forget a channel once nothing more can happen on it. Caller holds the lock.
function retire_if_done!(ch::LinkChannel)
    link = ch.link::Link
    done = ch.local_closed && ch.remote_closed && isempty(ch.outq) && isempty(ch.inbox)
    done && ch.id != 0 && delete!(link.channels, ch.id)
    return nothing
end

# ── connection lifecycle ─────────────────────────────────────────────────────

"""
    attach!(link, transport, peer_last_received)

Put `link` on a new connection whose handshake is done. The peer said it has
every frame up to `peer_last_received`; everything after that is sent again.
"""
function attach!(link::Link, t::Transport, peer_last_received::UInt64)
    old = lock(link.lock) do
        link.state === :dead && throw(LinkDead(link.dead_reason))
        prev = link.transport
        trim_log!(link, peer_last_received)
        link.cursor = 1
        empty!(link.urgent)
        link.transport = t
        link.generation += 1
        link.state = :connected
        link.attached_once = true
        link.last_rx = time()
        link.last_ping = time()
        link.ping_sent = 0.0          # a ping on the old connection is not coming back
        notify(link.wake)
        prev
    end
    notify(link.tick)
    old === nothing || close_transport(old)
    errormonitor(Threads.@spawn reader_loop(link, t))
    notify_state(link, :connected)
    return link
end

# The connection `t` is gone. Only the CURRENT connection can detach the link:
# a late failure from an earlier one is ignored.
function connection_lost!(link::Link, t::Transport, reason)
    changed = lock(link.lock) do
        link.transport === t || return false
        link.transport = nothing
        link.generation += 1
        link.state = :detached
        link.detached_at = time()
        empty!(link.urgent)
        notify(link.wake)
        true
    end
    notify(link.tick)
    close_transport(t)
    if changed
        @warn "WorkerLink: connection lost; the link waits $(link.grace)s for a reconnect" role = link.role reason = string(reason)
        notify_state(link, :detached)
    end
    return nothing
end

"Drop the current connection (the link stays, detached, and can be resumed)."
function disconnect!(link::Link)
    t = lock(() -> link.transport, link.lock)
    t === nothing || connection_lost!(link, t, "disconnected")
    return nothing
end

"""
    kill!(link, reason)

End the link for good: every channel is aborted with `reason`, the connection
(if any) is closed, and the writer stops.
"""
function kill!(link::Link, reason::AbstractString)
    t = lock(link.lock) do
        link.state === :dead && return nothing
        link.state = :dead
        link.dead_reason = String(reason)
        for ch in values(link.channels)
            ch.aborted = String(reason)
            empty!(ch.outq)
            notify(ch.cond)
        end
        empty!(link.channels)
        empty!(link.log)
        notify(link.wake)
        prev = link.transport
        link.transport = nothing
        prev
    end
    notify(link.tick)
    t === nothing || close_transport(t)
    notify_state(link, :dead)
    return nothing
end

# Pings, acknowledgements that would otherwise wait, the liveness deadline, and
# the grace period of a detached link.
"""
    ping_rtt(link) -> Float64

How long the link's last ping took to come back, in seconds (`NaN` before the
first): the time a small message currently waits behind what the connection
carries.
"""
ping_rtt(link::Link) = lock(() -> link.ping_rtt, link.lock)

const SLOW_PING_S = 2.0

# Caller holds the lock.
function pong_received!(link::Link, now::Float64)
    rtt = now - link.ping_sent
    link.ping_sent = 0.0
    link.ping_rtt = rtt
    if rtt > SLOW_PING_S && now - link.slow_logged_at > 60.0
        link.slow_logged_at = now
        @warn "WorkerLink: slow connection: a ping took $(round(rtt; digits = 1))s to come back; " *
              "every request on it waits about as long" role = link.role peer = link.name
    end
    return nothing
end

# How long a received frame may go unacknowledged (`ACK_DELAY_S`), unless 64
# more arrive first: the peer keeps everything unacknowledged for a replay.
const ACK_DELAY_S = 0.1

# The ticker sleeps until the next thing is due (`tick!` says when) instead of
# waking ten times a second: an idle link wakes about once per ping interval.
# A periodic wakeup costs more the more threads the process runs, since the
# idle ones spin up to look for work: a 100 ms ticker cost 3% of a core in a
# 24-thread server, for every link.
function ticker_loop(link::Link; stall::Real = 1.0)
    due = time()
    while true
        action, t, due = @lock link.lock tick!(link, due; stall)
        action === :stop && return nothing
        action === :lost && connection_lost!(link, t, "no traffic for $(link.ping_deadline)s")
        action === :expired && kill!(link, "no connection for $(link.grace)s")
        wait_until(link, due)
    end
end

# Until `due`, or until something makes an earlier deadline (`link.tick`).
function wait_until(link::Link, due::Float64)
    delay = due - time()
    delay > 0 || return nothing
    timer = Timer(_ -> notify(link.tick), delay)
    try
        wait(link.tick)
    finally
        close(timer)
    end
    return nothing
end

# One tick, which was due at `due`. Returns the action, the connection it is
# about, and when the next tick is due. Caller holds the lock.
function tick!(link::Link, due::Float64; stall::Real = 1.0)
    now = time()
    link.state === :dead && return (:stop, nothing, now)
    if link.state === :connected
        # Woken this late, this process did not run (or the lock was held).
        now - due > stall && stalled!(link, now, now - due)
        now - link.last_rx > link.ping_deadline && return (:lost, link.transport, now)
        if now - link.last_ping >= link.ping_interval
            link.last_ping = now
            link.ping_sent == 0.0 && (link.ping_sent = now)
            enqueue_urgent!(link, Frame(F_PING, 0))
        end
        unacked = link.last_received > link.last_ack_sent
        unacked && now >= link.ack_due && (send_ack!(link); unacked = false)
        next = min(link.last_ping + link.ping_interval, link.last_rx + link.ping_deadline)
        return (:none, nothing, unacked ? min(next, link.ack_due) : next)
    end
    now - link.detached_at > link.grace && return (:expired, nothing, now)
    return (:none, nothing, link.detached_at + link.grace)
end

# This link's tasks did not run for `gap` seconds: a long GC pause, a frozen
# machine. The reader stopped with the ticker, so what the peer sent meanwhile
# may be waiting unread in the socket, and "no traffic" would blame the peer for
# our own pause. Its silence counts again from a ping sent now, which it gets
# `ping_interval` to answer. Caller holds the lock.
function stalled!(link::Link, now::Float64, gap::Float64)
    fresh = now - link.ping_deadline + link.ping_interval
    link.last_rx >= fresh && return nothing     # the deadline is not near anyway
    link.last_rx = fresh
    link.last_ping = 0.0        # ping at once
    link.ping_sent = 0.0        # and do not time a ping across the pause
    @warn "WorkerLink: this process did not run for $(round(gap; digits = 1))s; " *
          "the peer gets a ping before its silence counts" role = link.role peer = link.name
    return nothing
end
