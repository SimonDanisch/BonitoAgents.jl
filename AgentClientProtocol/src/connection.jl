# JSON-RPC 2.0 connection over any Transport.
#
# A `Transport` is the long-lived I/O channel underneath: a subprocess, a
# WebSocket, a pair of channels for tests. Each concrete transport
# overloads three verbs:
#
#   send(t::Transport, line::String)  - write one newline-terminated JSON line
#   recv(t::Transport)::String        - blocking; returns "" on clean EOF
#   Base.close(t::Transport)          - release transport resources (idempotent)
#
# `Connection` uses these via dispatch — no callbacks stored on the
# struct. Adding a new transport (e.g. SSH-piped subprocess) is just a
# new struct + three method definitions.

# Raised on any pending `send_request` when the underlying `Connection`
# tears down (transport EOF, peer hang-up, explicit `close(conn)`). The
# typed form lets callers dispatch on `e isa ConnectionClosed` instead of
# parsing `showerror` output.
struct ConnectionClosed <: Exception
    reason::String
end
ConnectionClosed() = ConnectionClosed("")
Base.showerror(io::IO, e::ConnectionClosed) =
    print(io, "ACP connection closed",
              isempty(e.reason) ? "" : ": $(e.reason)")

# Channel buffer for a turn's update stream and for each message's own stream.
# Generous enough that the dispatcher rarely blocks; backpressure still applies
# past it (a slow consumer eventually backpressures the agent over TCP).
const BUF = 256

abstract type Transport end

# Default fallback for transports that don't need extra teardown.
Base.close(::Transport) = nothing

# The single concrete transport is `WorkerTransport` (worker_transport.jl) — the
# worker dial-back WebSocket. The old local `SubprocessTransport` is gone: every
# agent runs behind a worker now, so there's no in-process subprocess transport.

# Default for transports without an explicit EOF signal: rely on the `recv == ""`
# convention. `WorkerTransport` overrides this (a closed WS is a real EOF).
transport_eof(::Transport) = false

# ── Handler protocol ──────────────────────────────────────────────────────────
#
# A `Handler` owns the agent→client RPC verb:
#
#   on_request(h::Handler, method::String, params)   - agent→client RPCs (must
#                                                       return the JSON-serializable
#                                                       result or throw)
#
# Session updates are NOT handled here — they belong to a prompt turn and are
# delivered as a `Channel{SessionUpdate}` from `prompt_updates` (see below), so
# the consumer gets them as a bounded, ordered stream rather than via callback.
#
# Why dispatch instead of a `::Function` field on `Connection`:
#   - The handler's identity shows up in stack traces / `methods(...)` / `@which`;
#     closures stored on the struct are anonymous.
#   - New handlers don't touch `Connection`; they're a new struct + a method.
abstract type Handler end

# Default: warn on agent→client RPCs.
on_request(::Handler, method::AbstractString, ::Any) = warn_unhandled_request(method)

function warn_unhandled_request(method)
    @warn "ACP: unhandled agent request" method
    return nothing
end

# The default handler. Used when callers don't care about either kind of
# message — e.g. one-shot scripts that drive `prompt!` and discard output.
struct DiscardHandler <: Handler end


mutable struct Connection
    transport::Transport
    pending::Dict{Int,Channel{Any}}
    next_id::Int
    handler::Handler

    # Optional wire tap: called as `on_frame(dir::Symbol, msg::AbstractDict)`
    # with dir ∈ (:in, :out) for every ACP JSON-RPC frame that crosses the
    # connection — and ONLY those (internal events never pass through here).
    # `nothing` = disabled. A throwing tap never breaks the connection
    # (see `notify_frame`).
    on_frame::Union{Function,Nothing}

    # Sink for session/updates arriving with NO turn in flight. The agent DOES
    # stream between turns: a background subagent's parent-tagged activity
    # keeps flowing after end_turn, and when the subagent finishes the main
    # agent auto-wakes and streams an untagged completion message (captured
    # live in BonitoAgents/test/fixtures/bg_subagent_wire.jsonl). Called as
    # `on_orphan_update(update::SessionUpdate)` on the dispatcher task — keep
    # it fast + non-throwing. `nothing` (default) = the old drop behavior.
    on_orphan_update::Union{Function,Nothing}

    # The in-flight streaming turns, OLDEST FIRST. `prompt_updates` appends;
    # the dispatcher feeds every `session/update` into the FIRST entry's
    # channel and closes + removes an entry when its response arrives.
    #
    # More than one entry is a real, supported state: claude-agent-acp lets a
    # second `session/prompt` be sent while one is running — the agent
    # injects the new user message into the live turn (steering) and, when
    # the SDK replays it, resolves the FIRST prompt with end_turn and hands
    # the stream to the second (`pendingMessages`/`handedOff` upstream). This
    # is also the ONLY way to get a turn back from the SDK's
    # background-shell state: with a live background task the SDK never goes
    # idle, so the active prompt never resolves on its own — the next prompt
    # is what releases it. Oldest-first update routing matches the handoff
    # contract: everything streamed before prompt N's response belongs to
    # turn N.
    active_turns::Vector{Pair{Int,Channel{SessionUpdate}}}

    # Single inbox for EVERY inbound frame (notifications, requests,
    # responses). `reader_loop` parses each WS line into a raw JSON-RPC
    # Dict and `put!`s it here; a SINGLE dispatcher task drains and
    # routes by message kind. The key property this gives us:
    #
    #   When a response (e.g. `session/prompt`'s end_turn) is delivered
    #   to its pending channel, EVERY earlier frame in WS order has
    #   already been processed by the same dispatcher.
    #
    # That makes "prompt! returned" a sufficient signal for "every
    # session/update for this turn has been applied" — no external
    # drain barrier needed.
    #
    # Properties:
    #
    #   1. STRICT FIFO ORDER end-to-end. reader_loop parses serially,
    #      put!s serially, dispatcher pops serially.
    #   2. BACKPRESSURE. Bound (1024) is generous for any realistic
    #      agent rate. A slow handler blocks the reader → WS buffer
    #      fills → TCP backpressures the agent. No unbounded memory.
    #   3. CLEAN SHUTDOWN. `Base.close(conn)` closes the transport;
    #      reader_loop sees EOF and closes the inbox; dispatcher drains
    #      whatever remains, then its `finally` unblocks any pending
    #      RPCs with `ConnectionClosed`.
    #
    # Agent→client REQUESTS still spawn `@async` per request (inside
    # `dispatch_message`) — those are independent and can be slow (file
    # I/O, terminal); we don't want them blocking the chunk stream
    # behind them on the dispatcher.
    inbox::Channel{Any}

    lock::ReentrantLock
    reader_task::Union{Task,Nothing}
    dispatcher_task::Union{Task,Nothing}
    closed::Bool

    # Set true by `cancel!` for the active turn. The `prompt!` consumer then
    # fast-discards remaining buffered `session/update`s instead of coalescing +
    # rendering them, so a token backlog can't keep the dispatcher from reaching
    # the `cancelled` response (strict-FIFO head-of-line). Reset to false when
    # the next turn starts (`request_updates`). Atomic for cross-task visibility
    # (set on the cancel task, read in the consumer loop).
    @atomic cancelling::Bool
    # `time()` of the FIRST cancel for the active turn (0.0 if none). Lets the
    # chat layer tell a deliberate re-cancel ("force it, it's wedged") from an
    # impatient double-click — only the former, after the agent's had a real
    # chance, escalates to a force-close. Reset to 0.0 at each turn start.
    @atomic cancel_at::Float64
end

function Connection(transport::Transport, handler::Handler = DiscardHandler();
                    on_frame::Union{Function,Nothing} = nothing)
    conn = Connection(transport,
                      Dict{Int,Channel{Any}}(), 0,
                      handler,
                      on_frame,
                      nothing,                              # on_orphan_update (set post-bind)
                      Pair{Int,Channel{SessionUpdate}}[],   # active_turns
                      Channel{Any}(1024),
                      ReentrantLock(), nothing, nothing, false,
                      false,                     # cancelling
                      0.0)                       # cancel_at
    conn.dispatcher_task = @async dispatcher_loop(conn)
    conn.reader_task     = @async reader_loop(conn)
    return conn
end

# Feed one frame to the wire tap. Isolated so a throwing tap can never take
# down the reader loop or fail a send — the tap is observability, not flow.
function notify_frame(conn::Connection, dir::Symbol, msg::AbstractDict)
    conn.on_frame === nothing && return nothing
    try
        conn.on_frame(dir, msg)
    catch e
        @warn "ACP frame tap failed" exception=e maxlog=3
    end
    return nothing
end

# Single consumer of the inbox. Drains every inbound frame in wire order
# and routes by kind via `dispatch_message`. Per-frame exceptions are
# caught + logged so one bad frame can't kill the loop. When the inbox
# closes (transport EOF / explicit `close`), the `for` finishes draining
# and the `finally` unblocks any pending RPCs that never got a response.
function dispatcher_loop(conn::Connection)
    try
        for msg in conn.inbox
            try
                dispatch_message(conn, msg)
            catch e
                @warn "ACP dispatch failed" exception=e
            end
        end
    finally
        # Teardown: close any in-flight turn stream so its parse loop ends,
        # then unblock every pending RPC (including the turn's response) with
        # ConnectionClosed so `prompt!` surfaces a dead session. All of this
        # runs under `conn.lock` and flips `conn.closed` so a `send_request`
        # racing teardown either registers before us (and gets failed below) or
        # sees `closed` and throws — it can never park on a channel nobody will
        # ever feed (A1/A2).
        lock(conn.lock) do
            conn.closed = true
            for (_, ch) in conn.active_turns
                close(ch)
            end
            empty!(conn.active_turns)
            for (_, ch) in conn.pending
                put!(ch, ConnectionClosed())
            end
            empty!(conn.pending)
        end
    end
end

# Register a pending RPC under the lock, refusing once the dispatcher has torn
# down (A1/A2). The channel must be created by the caller so the registration +
# the wire send below stay a tight critical section; the actual send happens
# outside the lock so a slow transport write can't serialize against the
# dispatcher's response delivery.
function register_pending!(conn::Connection, id::Int, ch::Channel)
    lock(conn.lock) do
        conn.closed && throw(ConnectionClosed("connection torn down"))
        conn.pending[id] = ch
    end
    return nothing
end

# Same, but also enrolls the request in the streaming-turn queue (oldest
# first). Concurrent turns are deliberate — see the `active_turns` field doc:
# a prompt sent while one runs is the agent's steering/handoff mechanism, and
# the only way to free a turn the SDK holds open for a background shell.
function register_turn!(conn::Connection, id::Int,
                        response::Channel, updates::Channel)
    lock(conn.lock) do
        conn.closed && throw(ConnectionClosed("connection torn down"))
        conn.pending[id] = response
        push!(conn.active_turns, id => updates)
    end
    return nothing
end

# Deliver one streamed update to the active turn's stream, applying BACKPRESSURE
# when the consumer falls behind (a flood of tool calls / a heavy token stream).
#
# We must NOT drop here. Unlike `push_snapshot!` — whose queued entries are all
# the SAME mutated `ToolCall` object, so only the latest matters and dropping is
# safe — these are DISTINCT `SessionUpdate`s for DIFFERENT messages. Dropping the
# oldest loses, e.g., a tool's terminal `tool_call_update`, so that tool's
# per-message `updates` channel never closes and the consumer's
# `for snap in m.updates` blocks FOREVER: a hard deadlock that wedges the whole
# turn (reproducibly, on any turn streaming more than ~`BUF` updates). Blocking
# the dispatcher is safe for liveness — the consumer always drains eventually, so
# space always frees.
#
# The one case the old drop-oldest was protecting (A7: keep the dispatcher free
# to reach a `cancelled` response behind a backlog) is handled by bailing the
# moment `cancelling` flips: the call site already stops delivering once
# cancelling and the consumer fast-discards, so a parked put! can't wedge cancel.
function deliver_update!(conn::Connection, ch::Channel{SessionUpdate}, update::SessionUpdate)
    while true
        lock(ch)
        try
            isopen(ch) || return nothing            # consumer closed it
            if Base.n_avail(ch) < ch.sz_max
                put!(ch, update)
                return nothing
            end
        finally
            unlock(ch)
        end
        # Full: wait for the consumer to take one (backpressure, no data loss).
        # A cancel in flight means we stop rendering this turn anyway — return so
        # the dispatcher stays free to reach the turn's `cancelled` response.
        (@atomic conn.cancelling) && return nothing
        sleep(0.001)
    end
end

# ── Writing ───────────────────────────────────────────────────────────────────

function send_raw(conn::Connection, msg::AbstractDict)
    # Tap outside `conn.lock` — the tap (e.g. a file logger) does its own
    # locking and must not serialize against wire writes.
    notify_frame(conn, :out, msg)
    line = JSON.json(msg) * "\n"
    lock(conn.lock) do
        send(conn.transport, line)
    end
end

function send_request(conn::Connection, method::String, params)::Any
    id = lock(conn.lock) do
        id = conn.next_id
        conn.next_id += 1
        id
    end
    ch = Channel{Any}(1)
    register_pending!(conn, id, ch)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    result = take!(ch)
    result isa Exception && throw(result)
    return result
end

function send_notification(conn::Connection, method::String, params)
    send_raw(conn, Dict("jsonrpc" => "2.0", "method" => method, "params" => params))
end

# Like `send_request`, but gives up after `timeout` seconds (A3). Used by setup
# RPCs (`initialize`, `session/new`) so a wedged agent that never replies can't
# hang `Client()` forever. On timeout we deregister the pending entry under the
# lock (so the dispatcher won't later `put!` into an abandoned channel) and
# raise `ConnectionClosed`; the caller closes the connection and the agent is
# reaped.
function send_request(conn::Connection, method::String, params, timeout::Real)::Any
    id = lock(conn.lock) do
        i = conn.next_id; conn.next_id += 1; i
    end
    ch = Channel{Any}(1)
    register_pending!(conn, id, ch)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))

    # A one-shot timer closes `ch` if no response lands in time. The timer
    # callback is the ONLY thing that closes `ch` on the timeout path, so a
    # closed-on-take means "timed out". `close(timer)` after we get a result
    # cancels a still-pending timer cleanly (no callback runs).
    timer = Timer(_ -> (isopen(ch) && close(ch)), timeout)
    result = try
        take!(ch)
    catch e
        # Channel closed with nothing delivered: timed out (or torn down).
        if e isa InvalidStateException
            lock(conn.lock) do
                delete!(conn.pending, id)
            end
            throw(ConnectionClosed("request `$method` timed out after $(timeout)s"))
        end
        rethrow()
    finally
        close(timer)
    end
    result isa Exception && throw(result)
    return result
end

# Begin a request that streams `session/update` notifications back while it runs.
# Both `session/prompt` (live turn) and `session/load` (the agent re-streams the
# resumed session's history) do this. Returns `(updates, response)`:
#   * `updates`  - a Channel{SessionUpdate} carrying this request's session/update
#                  notifications in wire order, CLOSED when the request's response
#                  arrives or the connection tears down.
#   * `response` - a one-shot channel that receives the result (or a
#                  ConnectionClosed on teardown), so the caller can detect a
#                  dead session after draining `updates`.
# Concurrent streaming requests are supported (see `active_turns`): updates
# route to the oldest unresolved one, matching claude-agent-acp's handoff
# contract. (`session/load` still never overlaps a prompt in practice —
# bring-up completes before the prompt consumer starts.)
function request_updates(conn::Connection, method::String, params)
    @atomic conn.cancelling = false   # fresh turn renders normally
    @atomic conn.cancel_at  = 0.0     # fresh turn: no cancel recorded yet
    id = lock(conn.lock) do
        i = conn.next_id; conn.next_id += 1; i
    end
    response = Channel{Any}(1)
    updates  = Channel{SessionUpdate}(BUF)
    register_turn!(conn, id, response, updates)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id,
                        "method" => method, "params" => params))
    return updates, response
end

# A `session/prompt` turn — the original entry point, unchanged for callers.
prompt_updates(conn::Connection, params) = request_updates(conn, "session/prompt", params)

function send_response(conn::Connection, id, result)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
end

function send_error_response(conn::Connection, id, code::Int, message::String)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id,
                        "error" => Dict("code" => code, "message" => message)))
end

# ── Receiving ─────────────────────────────────────────────────────────────────

function dispatch_message(conn::Connection, msg::AbstractDict)
    method = get(msg, "method", nothing)
    has_id = haskey(msg, "id")

    if method !== nothing && has_id
        # Agent→client request — must respond. Spawn off-task so a slow
        # handler (file I/O, terminal RPCs) doesn't hold up the chunk
        # stream behind it on the dispatcher.
        id = msg["id"]
        params = get(msg, "params", nothing)
        # errormonitor so a failure to even send the reply (transport gone) is
        # logged instead of vanishing into a dead bare task — otherwise the
        # agent waits forever for a response that never comes (A5).
        Base.errormonitor(@async begin
            try
                result = on_request(conn.handler, method, params)
                send_response(conn, id, result)
            catch e
                # Handler threw: report the error back so the agent unblocks.
                # If even THAT send fails (transport dead), log loudly rather
                # than swallow.
                try
                    send_error_response(conn, id, -32603, string(e))
                catch e2
                    @warn "ACP: failed to send error response to agent" id exception=(e2, catch_backtrace())
                end
            end
        end)

    elseif method !== nothing
        if method == "session/update"
            params = get(msg, "params", Dict{String,Any}())
            # ACP wraps the actual update object under "update" key
            update_obj = get(params, "update", params)
            update = parse_session_update(update_obj)
            # Belongs to the OLDEST in-flight streaming request (session/prompt
            # or session/load): everything the agent streams before prompt N's
            # response is turn N's content (the handoff contract — see
            # `active_turns`). If none is active (the agent shouldn't stream
            # otherwise), drop it.
            #
            # DROP the moment cancel is requested. This single dispatcher task
            # processes the inbox strictly in order, so if it BLOCKS here on
            # `put!` into a backed-up updates channel (slow browser / heavy token
            # or tool-call stream), it can never reach the `cancelled` response
            # sitting behind the backlog — the turn would look wedged for as long
            # as the browser takes to drain. Once cancel is requested we don't
            # render any more of this turn anyway (the consumer fast-discards),
            # so dropping here keeps the dispatcher free to reach the response
            # immediately, regardless of downstream speed.
            ch = lock(conn.lock) do
                isempty(conn.active_turns) ? nothing : last(first(conn.active_turns))
            end
            if ch !== nothing && !(@atomic conn.cancelling)
                deliver_update!(conn, ch, update)
            elseif ch === nothing && conn.on_orphan_update !== nothing &&
                   !(@atomic conn.cancelling)
                # No turn in flight — but the agent legitimately streams here:
                # background-subagent activity and the auto-wake completion
                # message (see the field doc). Hand it to the orphan sink;
                # a throwing sink must never take the dispatcher down.
                try
                    conn.on_orphan_update(update)
                catch e
                    @warn "on_orphan_update threw" exception = (e, catch_backtrace())
                end
            end
        end
        # Other notifications silently ignored.

    elseif has_id
        # Response to one of our outgoing requests. Because the dispatcher
        # processes the inbox strictly in order, delivering the response here
        # is also a synchronization point: every earlier frame in WS order
        # has already been dispatched.
        id = msg["id"]
        # The active prompt's response ends the turn: close its update stream
        # (its parse loop drains the buffer, then exits). The response itself
        # still flows to the pending channel below so `prompt!` can read the
        # stopReason / surface an rpc error. Both the active-turn slot and the
        # pending table are read/mutated under `conn.lock` (A1) — caller tasks
        # register concurrently, so an unlocked get/delete here could miss an
        # entry mid-insert and hang the caller forever.
        ch = lock(conn.lock) do
            i = findfirst(t -> first(t) == id, conn.active_turns)
            if i !== nothing
                close(last(conn.active_turns[i]))
                deleteat!(conn.active_turns, i)
            end
            c = get(conn.pending, id, nothing)
            c === nothing || delete!(conn.pending, id)
            c
        end
        if ch !== nothing
            if haskey(msg, "error")
                put!(ch, ErrorException(get(msg["error"], "message", "rpc error")))
            else
                put!(ch, get(msg, "result", nothing))
            end
        else
            # No pending entry: a duplicate response, a reply after teardown, or
            # an id we never sent. Correlation failures are otherwise invisible
            # (A6).
            @warn "ACP: response for unknown request id" id maxlog=10
        end
    end
end

function reader_loop(conn::Connection)
    try
        while !conn.closed
            line = recv(conn.transport)
            if isempty(line)
                # A genuinely empty line is ambiguous: real EOF, or a stray
                # blank line the agent emitted between frames. Only tear the
                # connection down on a real EOF; otherwise skip and keep reading
                # (A4) so one blank line can't kill a live session.
                transport_eof(conn.transport) && break
                # Defense-in-depth: if a transport's `recv` returns "" WITHOUT
                # blocking and its `transport_eof` is (wrongly) false, this skip
                # path is a hot loop. `reader_loop` runs on a sticky `@async`
                # task, so without a yield it would monopolize thread 1 and
                # livelock the whole process (every other server `@async` handler
                # starves). The yield turns that into a recoverable busy loop.
                yield()
                continue
            end
            local msg
            try
                msg = JSON.parse(line)
            catch e
                @warn "ACP: failed to parse line" exception=e line
                continue
            end
            notify_frame(conn, :in, msg)
            put!(conn.inbox, msg)
        end
    catch e
        # EOFError / IOError = subprocess or socket EOF; InvalidStateException =
        # a channel-based transport closed under us. And `conn.closed` means WE
        # initiated the teardown (close(conn)), so ANY reader error here — incl. a
        # WebSocket 1006 abnormal-close as the socket drops — is expected teardown,
        # not a failure. Only warn when the connection was supposed to be live (a
        # genuine crash: protocol error / unexpected drop while open).
        if !conn.closed && !(e isa EOFError || e isa Base.IOError || e isa InvalidStateException)
            @warn "ACP reader failed" exception=e
        end
    finally
        # The agent may have closed stdout but kept running (or the loop is
        # exiting for any other reason): close the transport so the subprocess
        # is actually reaped instead of leaking (A4). Idempotent with
        # `close(conn)`.
        close(conn.transport)
        # Closing the inbox lets the dispatcher's `for msg in inbox`
        # finish draining any in-flight messages, then its `finally`
        # cleans up pending RPCs with ConnectionClosed.
        close(conn.inbox)
    end
end

function Base.close(conn::Connection)
    conn.closed = true
    # Cascade: close(transport) → reader_loop's recv returns "" → loop
    # exits → reader_loop.finally closes inbox → dispatcher.for finishes
    # → dispatcher.finally drains pending RPCs. One call, full teardown.
    close(conn.transport)
    return nothing
end
