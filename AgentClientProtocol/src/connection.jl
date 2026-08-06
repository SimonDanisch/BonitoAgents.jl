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
# Session updates are NOT handled here — they are addressed to their owner (the
# session's main thread, or a subagent) and reach it through `on_main_update` /
# `on_owner_update`, which `Client` turns into bounded, ordered streams.
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

# One `session/prompt` in flight: a SPAN over the session's main stream, not a
# container for it.
#
# `flush` is the span's end marker. The dispatcher puts it on the main stream at
# the exact frame the response arrives, so the boundary is stamped where the wire
# says it is — not wherever the caller's task happens to get scheduled. That
# matters during steering: prompt 1 resolves while prompt 2 is already streaming,
# and a marker injected from the caller could land after prompt 2's opening text,
# merging it into prompt 1's bubble.
struct PromptSpan
    id::Int
    response::Channel{Any}
    flush::StreamFlush
end
PromptSpan(id::Int) = PromptSpan(id, Channel{Any}(1), StreamFlush())

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

    # Sink for the session's MAIN THREAD: EVERY untagged `session/update`,
    # whether or not a prompt happens to be in flight. Called as
    # `on_main_update(update::SessionUpdate)` on the dispatcher task — keep it
    # fast + non-throwing. `Client` installs it (one persistent coalescer per
    # session); `nothing` = drop.
    #
    # There is deliberately no per-prompt update stream. The main thread is ONE
    # stream that the agent speaks on continuously: inside a prompt, and also
    # between prompts (the auto-wake it does after backgrounded work finishes —
    # captured live in BonitoAgents/test/fixtures/bg_subagent_wire.jsonl). Those
    # used to be two code paths, which meant two renderers, two notions of
    # liveness, and a whole class of "which turn does this belong to" questions
    # that the wire cannot answer. A prompt is now a SPAN over this stream, not
    # a container for it.
    #
    # Subagent-tagged updates do NOT come here; they are addressed by
    # `parentToolUseId` and go to `on_owner_update` instead.
    on_main_update::Union{Function,Nothing}

    # Sink for updates that NAME their owner. Called as
    # `on_owner_update(owner_id::String, update::SessionUpdate)` for every
    # update carrying a `parentToolUseId` — i.e. everything a subagent emits.
    #
    # Addressed, not routed: a subagent's stream is its own from the first
    # frame, so it never depends on which turn happens to be open, never
    # competes with the main thread's spans, and is not silenced when a
    # main-thread turn is cancelled. The consumer keeps per-owner state and
    # renders it itself, which is what lets a subagent own its whole history
    # instead of folding into a shared bounded feed.
    on_owner_update::Union{Function,Nothing}

    # `toolCallId` → the subagent that owns it, learned from the frames that DO
    # carry `parentToolUseId`.
    #
    # claude-agent-acp does not tag every frame of a subagent's tool. Captured
    # live (BonitoAgents/test/fixtures/bg_subagent_wire.jsonl), one subagent bash
    # arrives: `tool_call`(tagged) → `tool_call_update`(UNTAGGED, and it is the
    # one carrying `toolResponse`) → `tool_call_update`(tagged). Addressing on
    # the tag alone sends that middle frame to the main thread, where the
    # coalescer has never heard of the tool id and drops it — so the subagent
    # silently loses an update, and a tool whose TERMINAL frame is the untagged
    # one never reaches `completed` in its feed.
    #
    # The id is recoverable, so we recover it rather than guess: an untagged
    # frame for a tool we have seen a subagent announce belongs to that subagent.
    # A tool id never seen tagged stays the main thread's — this only ever
    # re-unites frames with an owner the wire already told us about.
    #
    # Forgotten when the tool reports terminal, so it cannot grow unbounded over
    # a long session.
    tool_owners::Dict{String,String}

    # Requests that CAPTURE the update stream for themselves instead of letting
    # it reach `on_main_update`. Exactly one method does this: `session/load`,
    # where the agent re-streams the resumed session's whole history as
    # `session/update` notifications. That replay is not the live conversation
    # and must not render as it — it is the request's own result, arriving in
    # pieces, so the request collects it (`collect_replayed_updates`).
    #
    # `session/prompt` deliberately does NOT capture. A prompt is a span over
    # the main stream, marked by `active_prompts`; its content goes to the one
    # main sink like everything else the main thread says.
    #
    # A load never overlaps another load or a prompt in practice (bring-up
    # completes before the chat's consumer starts), so "the oldest capturing
    # request" is unambiguous here in a way it never was for prompts.
    capture::Vector{Pair{Int,Channel{SessionUpdate}}}

    # The in-flight `session/prompt` spans. NOT a routing table — nothing is
    # routed by it. It answers exactly one question, "is a prompt open", which
    # `cancel!` needs and which is otherwise unknowable, and it carries each
    # span's end-of-turn marker so the dispatcher can stamp the boundary at the
    # exact frame the response arrives (see `PromptSpan`).
    #
    # More than one entry is a real, supported state: claude-agent-acp lets a
    # second `session/prompt` be sent while one is running — the agent injects
    # the new user message into the live turn (steering) and, when the SDK
    # replays it, resolves the FIRST prompt with end_turn and hands the stream
    # to the second (`pendingMessages`/`handedOff` upstream). With one main
    # stream that handoff needs no modelling at all: the agent's words arrive in
    # wire order and are rendered in wire order, whichever prompt is credited
    # with them.
    active_prompts::Vector{PromptSpan}

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

    # What the session is doing — see `SessionActivity`. ONE value, derived by
    # `settle!` from facts we can each observe directly: whether a prompt of
    # ours is open, whether the agent has streamed work, and how long it has
    # been quiet. Atomic for cross-task visibility (written on the dispatcher
    # and the cancel task, read from both plus the UI).
    #
    # This deliberately does NOT gate delivery. An earlier `cancelling` flag
    # made the dispatcher DROP main-thread updates so a token backlog could not
    # keep it from reaching the `cancelled` response — which discarded real
    # output unparsed and, for un-prompted work, never unset. Cancel now costs
    # backlog-drain latency instead of the user's messages.
    @atomic activity::SessionActivity
    # `time()` of the last frame that counted as agent WORK. Bounds `Unprompted`,
    # which the wire gives no end marker for.
    @atomic last_work_at::Float64
    # `time()` of the FIRST cancel for the active turn (0.0 if none). Lets the
    # chat layer tell a deliberate re-cancel ("force it, it's wedged") from an
    # impatient double-click — only the former, after the agent's had a real
    # chance, escalates to a force-close. Reset to 0.0 at each turn start.
    @atomic cancel_at::Float64
end

# How long the main thread must be quiet before an `Unprompted` episode counts
# as over.
#
# `active_prompts` says whether we asked for something; `Unprompted` says the
# agent is saying something anyway. Those stopped being the same question once
# it started auto-waking after backgrounded work: in the captured trace
# (BonitoAgents/test/fixtures/bg_subagent_wire.jsonl) it runs a tool and writes
# three message chunks across 27 s with no prompt open, so reading
# `active_prompts` alone says "idle" while the user watches it work.
#
# The episode's END is the hard part — it is prose and tools that simply stop.
# `AUTONOMOUS_ORIGINS` usually tags the last frame, but claude-agent-acp emits
# that `usage_update` conditionally, so it cannot be the only way out; relying on
# it is what left the spinner running over an idle agent. Quiet is observable
# without the agent's cooperation, which is the property that matters.
#
# Sized off the same trace: the widest gap between consecutive frames of one
# episode is ~19 s (the auto-wake latency after backgrounded work finishes), so
# this sits comfortably past it without making a finished episode linger.
const QUIET_SECONDS = 30.0

"""
    settle(activity, has_prompts, quiet_for) -> SessionActivity

The transition function. Total over the state space, so there is no path that
forgets to clear something — the old bugs were all "set here, cleared there, and
here is a path where the clear never runs".

`quiet_for` is seconds since the last frame that counted as agent WORK. Metadata
(`available_commands_update` right after `session/new`, usage, mode) is the agent
answering about itself, not doing something — see `is_agent_work` — and counting
it made every chat look busy from the moment it bound.
"""
settle(::SessionActivity, has_prompts::Bool, quiet_for::Real) =
    has_prompts ? Prompted() : (quiet_for < QUIET_SECONDS ? Unprompted() : Idle())
# A cancel we sent outlives the quiet bound: it ends when the turn it cancelled
# actually settles (its response), or when there is no prompt left to settle.
settle(::Cancelling, has_prompts::Bool, ::Real) = has_prompts ? Cancelling() : Idle()

"Recompute and store the session's activity. Returns the new value."
function settle!(conn::Connection; worked::Bool = false)
    now_t = time()
    worked && (@atomic conn.last_work_at = now_t)
    has_prompts = lock(() -> !isempty(conn.active_prompts), conn.lock)
    quiet_for   = now_t - (@atomic conn.last_work_at)
    next = settle((@atomic conn.activity), has_prompts, quiet_for)
    @atomic conn.activity = next
    return next
end

"""
    session_activity(conn) -> SessionActivity

The session's current activity, re-settled on read so a caller never sees a
state the clock has already invalidated. `Unprompted` in particular expires on
quiet, and nothing arrives to trigger that — the whole point is that it needs no
frame from the agent to end.
"""
session_activity(conn::Connection) = settle!(conn)

function Connection(transport::Transport, handler::Handler = DiscardHandler();
                    on_frame::Union{Function,Nothing} = nothing)
    conn = Connection(transport,
                      Dict{Int,Channel{Any}}(), 0,
                      handler,
                      on_frame,
                      nothing,                              # on_main_update  (Client installs)
                      nothing,                              # on_owner_update (set post-bind)
                      Dict{String,String}(),                # tool_owners
                      Pair{Int,Channel{SessionUpdate}}[],   # capture
                      PromptSpan[],                         # active_prompts
                      Channel{Any}(1024),
                      ReentrantLock(), nothing, nothing, false,
                      Idle(),                    # activity
                      0.0,                       # last_work_at
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
        stranded = lock(conn.lock) do
            conn.closed = true
            for (_, ch) in conn.capture
                close(ch)
            end
            empty!(conn.capture)
            spans = copy(conn.active_prompts)
            empty!(conn.active_prompts)
            for (_, ch) in conn.pending
                put!(ch, ConnectionClosed())
            end
            empty!(conn.pending)
            spans
        end
        # A span ALWAYS ends, on exactly one of two events: its response, or
        # this. Callers wait on `span.flush` for "the turn is rendered", so a
        # span that just evaporated on teardown would leave them waiting on a
        # marker nobody will ever send.
        for sp in stranded
            deliver_main!(conn, sp.flush)
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

# Same, but the request also CAPTURES the update stream while it runs — see the
# `capture` field doc. `session/load` only.
function register_capture!(conn::Connection, id::Int,
                           response::Channel, updates::Channel)
    lock(conn.lock) do
        conn.closed && throw(ConnectionClosed("connection torn down"))
        conn.pending[id] = response
        push!(conn.capture, id => updates)
    end
    return nothing
end

# Same, but marks the request as an open prompt span. Concurrent prompts are
# deliberate — see the `active_prompts` field doc: a prompt sent while one runs
# is the agent's steering/handoff mechanism, and the only way to free a turn the
# SDK holds open for a background shell.
function register_prompt!(conn::Connection, span::PromptSpan)
    lock(conn.lock) do
        conn.closed && throw(ConnectionClosed("connection torn down"))
        conn.pending[span.id] = span.response
        push!(conn.active_prompts, span)
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
# A cancel does NOT change this. An earlier `cancelling` flag made both this
# function and the dispatcher bail while a cancel was in flight, so the
# dispatcher could reach the `cancelled` response without waiting for a slow
# browser to drain. That bought latency with the user's output: the skipped
# frames were discarded UNPARSED — never rendered, never stored, recoverable
# only by reloading and replaying history. And because the flag gated the whole
# main thread rather than the cancelled turn, it also silenced background work
# nobody had cancelled.
#
# Cancel now costs backlog-drain latency instead, which is bounded by the
# channel and visible in the UI as `Cancelling`.
function deliver_update!(conn::Connection, ch::Channel, update)
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
        sleep(0.001)   # full: wait for the consumer (backpressure, no data loss)
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

"""
    owner_of(conn, update) -> Union{String,Nothing}

Who this update belongs to: the subagent named by `parentToolUseId`, or — for an
untagged frame about a tool a subagent has already claimed — that same subagent.
`nothing` means the session's main thread.

Learning the tool→owner association is what makes the second case possible; see
`Connection.tool_owners` for the captured wire behaviour that requires it.
"""
function owner_of(conn::Connection, update::SessionUpdate)
    tagged = parent_tool_use_id(update)
    tid    = tool_call_id(update)
    lock(conn.lock) do
        if tagged !== nothing
            # Remember, then forget on the tool's own terminal frame — AFTER this
            # call returns it, so the terminal frame still reaches its owner.
            tid === nothing && return tagged
            tool_is_terminal(update) ? delete!(conn.tool_owners, tid) :
                                       (conn.tool_owners[tid] = tagged)
            return tagged
        end
        tid === nothing && return nothing
        owner = get(conn.tool_owners, tid, nothing)
        owner === nothing && return nothing        # the main thread's own tool
        tool_is_terminal(update) && delete!(conn.tool_owners, tid)
        return owner
    end
end

"""
    deliver_main!(conn, update)

Hand a main-thread update to `on_main_update`. Same discipline as
`deliver_owner!`; see there for why `invokelatest`.
"""
function deliver_main!(conn::Connection, update::Union{SessionUpdate,StreamFlush})
    sink = conn.on_main_update
    sink === nothing && return nothing
    try
        Base.invokelatest(sink, update)
    catch e
        @warn "on_main_update threw" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    deliver_owner!(conn, owner_id, update)

Hand an addressed update to `on_owner_update`. Never blocks the dispatcher and
never lets a throwing sink take it down — the same discipline `deliver_update!`
follows, for the same reason: this task must stay free to reach a pending
response sitting behind the inbox.

`invokelatest` because the sink is assigned after this task exists (the chat
layer wires it post-bind, and Revise redefining its target makes a newer method
still); a direct call would throw a world-age MethodError and every subagent
update would vanish behind the warning below.
"""
function deliver_owner!(conn::Connection, owner_id::AbstractString, update::SessionUpdate)
    sink = conn.on_owner_update
    sink === nothing && return nothing
    try
        Base.invokelatest(sink, String(owner_id), update)
    catch e
        @warn "on_owner_update threw" owner = owner_id exception = (e, catch_backtrace())
    end
    return nothing
end

# Reset the per-request cancel state. Any stray work from before this request
# belongs to it now. `activity` is not assigned here — `settle!` derives it from
# `active_prompts`, which the caller is about to push to.
function reset_turn_state!(conn::Connection)
    @atomic conn.cancel_at = 0.0
    return nothing
end

function next_request_id(conn::Connection)
    lock(conn.lock) do
        i = conn.next_id; conn.next_id += 1; i
    end
end

# Begin a request that CAPTURES the `session/update` stream while it runs, i.e.
# `session/load` (see the `capture` field doc). Returns `(updates, response)`:
#   * `updates`  - a Channel{SessionUpdate} carrying the notifications that
#                  arrive while this request is open, in wire order, CLOSED when
#                  its response lands or the connection tears down.
#   * `response` - a one-shot channel receiving the result (or a
#                  ConnectionClosed on teardown), so the caller can detect a
#                  dead session after draining `updates`.
function request_updates(conn::Connection, method::String, params)
    reset_turn_state!(conn)
    id = next_request_id(conn)
    response = Channel{Any}(1)
    updates  = Channel{SessionUpdate}(BUF)
    register_capture!(conn, id, response, updates)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => id,
                        "method" => method, "params" => params))
    return updates, response
end

# Send a `session/prompt` and open a span over the main stream. Returns the
# `PromptSpan`. The prompt's CONTENT does not come back through here — it is the
# main thread speaking, and it goes to `on_main_update` like everything else the
# main thread says.
function prompt_request(conn::Connection, params)
    reset_turn_state!(conn)
    span = PromptSpan(next_request_id(conn))
    register_prompt!(conn, span)
    send_raw(conn, Dict("jsonrpc" => "2.0", "id" => span.id,
                        "method" => "session/prompt", "params" => params))
    return span
end

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
            # Every update is ADDRESSED, in this order of specificity:
            #
            #   1. `parentToolUseId` names a subagent — it owns the update. It
            #      is not part of any turn, it is not "orphaned" when no prompt
            #      is open, and cancelling the main thread must not silence it
            #      (that coupling is what made background work vanish after a
            #      stop). Straight to the owner sink, before anything else.
            #   2. A `session/load` is capturing — the update is part of that
            #      request's replayed result, not the live conversation.
            #   3. Otherwise it is the session's MAIN THREAD talking, prompt
            #      open or not. One stream, one sink.
            #
            # Nothing is inferred and nothing falls through to a drop.
            owner = owner_of(conn, update)
            if owner !== nothing
                # The INNER update when the wire tagged it: `owner` already names
                # who it belongs to, so the wrapper has done its job and would
                # only make every consumer unwrap it again. An update whose owner
                # we RECOVERED is already unwrapped.
                inner = update isa SubagentUpdate ? update.update : update
                deliver_owner!(conn, owner, inner)
                return nothing        # dispatch_message handles ONE frame; not a loop
            end

            ch = lock(conn.lock) do
                isempty(conn.capture) ? nothing : last(first(conn.capture))
            end
            if ch !== nothing
                deliver_update!(conn, ch, update)
                return nothing
            end

            # Every main-thread frame is DELIVERED, cancel or no cancel. What a
            # cancel changes is the session's `activity`, not what the user gets
            # to see (see `deliver_update!`).
            settle!(conn; worked = is_agent_work(update))
            deliver_main!(conn, update)
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
        ended = nothing
        ch = lock(conn.lock) do
            i = findfirst(t -> first(t) == id, conn.capture)
            if i !== nothing
                close(last(conn.capture[i]))
                deleteat!(conn.capture, i)
            end
            j = findfirst(sp -> sp.id == id, conn.active_prompts)
            if j !== nothing
                ended = conn.active_prompts[j]
                deleteat!(conn.active_prompts, j)
            end
            # Work that streamed INSIDE this prompt was prompted, so an
            # `Unprompted` verdict must not inherit its recency: only frames
            # from here on count (strict FIFO — everything earlier is already
            # dispatched). Without this, ending a turn would leave the session
            # looking un-prompted-busy for the whole quiet window.
            isempty(conn.active_prompts) && (@atomic conn.last_work_at = 0.0)
            c = get(conn.pending, id, nothing)
            c === nothing || delete!(conn.pending, id)
            c
        end
        # The span's END, stamped HERE — in strict FIFO order with the updates,
        # so the coalescer seals the turn's trailing bubble at exactly the frame
        # the agent resolved it, and a concurrent prompt's opening text can't be
        # swept into it. Outside the lock: the sink is a bounded channel put.
        ended === nothing || deliver_main!(conn, ended.flush)
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
