# Control dial-back from THIS process (the stdio MCP server) to the
# BonitoAgents server — the lever that lets the chat's per-tool ⊗ button
# interrupt an in-flight bt_julia_eval WITHOUT cancelling the whole agent
# turn.
#
# Why a separate channel: the eval-ws bridge (RemoteProxy) lives in the Malt
# EVAL worker, the same process that runs the user's code — a busy eval can
# starve its event loop, so it can't be trusted to deliver an interrupt. THIS
# process never runs user code (evals are remote_eval'd into the Malt
# worker), so its tasks stay responsive, and it already owns the stop lever:
# `request_interrupt!` — the same one `bt_julia_interrupt` and the MCP
# `notifications/cancelled` path use.
#
# Wire: one JSON object per WS message.
#   server → us:  {"op": "interrupt_eval", "request_id": id, "env_path"?: p}
#                 {"op": "ping", "request_id": id}
#   us → server:  {"type": "interrupt_result", "request_id": id, "interrupted": n}
#                 {"type": "pong", "request_id": id}
#
# The channel also runs in the OTHER direction, for the dev tools (`tools/dev.jl`):
#   us → server:  {"type": "dev_request", "dev_id": n, "op": "...", "args": {…}}
#   server → us:  {"op": "dev_reply", "dev_id": n, "ok": true,  "result": …}
#                 {"op": "dev_reply", "dev_id": n, "ok": false, "error": "…"}
# The id field is deliberately `dev_id`, NOT `request_id`: the server treats any
# frame carrying `request_id` as the REPLY to one of its own requests, so a
# request of ours using that name would be routed into its pending-RPC table and
# never handled.
#
# The dial is configured by the same env the eval-ws dial-back uses
# (BONITOAGENTS_SERVER_URL from the worker daemon, BONITOAGENTS_SECRET /
# BONITOAGENTS_PROJECT_ID injected by the server into the MCP launch env).
# Standalone BonitoMCP use (no BonitoAgents) has none of them set → no dial,
# zero overhead.

using HTTP.WebSockets: WebSockets

# The MCP process's one control channel to the BonitoAgents server. The live
# value is `SERVER.control` (see context.jl) — this is just its type.
#   task — the dial-loop task; nothing until start_ctrl_dialback! arms it once.
#   stop — test/embedder hook: production never sets it (the channel's lifetime
#          IS the process's). Flipping it exits the dial loop at the next
#          reconnect boundary instead of retrying forever.
#   ws   — the live socket, set only while connected (see ctrl_dial_loop);
#          nothing when no server is attached (then sends no-op).
mutable struct ControlChannel
    task::Union{Task,Nothing}
    stop::Bool
    ws::Any
    # Outbound request bookkeeping for the dev tools: dev_id → reply channel.
    # Empty in every normal MCP process (nothing calls the server), so this costs
    # a dict allocation and nothing else.
    pending::Dict{Int,Channel{Any}}
    pending_lock::ReentrantLock
    next_id::Threads.Atomic{Int}
end
ControlChannel(task, stop, ws) =
    ControlChannel(task, stop, ws, Dict{Int,Channel{Any}}(), ReentrantLock(),
                   Threads.Atomic{Int}(0))

# Best-effort JSON send over the control socket. Returns false (never throws) if
# no socket is up or the send fails — the caller (a live-display forwarder) must
# not care: the stream is a display side-channel, the agent's copy rides the MCP
# response separately. No send lock needed: the stream forwarder sends from the
# pump threads while the dial loop sends replies, but HTTP.WebSockets.send takes
# the socket's own `sendlock`, so concurrent sends are already serialised.
function send_ctrl_frame(payload::AbstractDict)
    ws = SERVER.control.ws
    ws === nothing && return false
    try
        WebSockets.send(ws, JSON.json(payload))
        return true
    catch e
        (e isa WebSockets.WebSocketError || e isa Base.IOError || e isa EOFError) || rethrow()
        return false
    end
end

# Forward a live stdout/stderr chunk of a running eval to the chat. `route` keys
# it to the eval session (see stream_route); the server routes it to the matching
# eval card's tail (handle_mcp_ctrl_ws → route_eval_chunk!).
send_eval_stream_chunk(route::AbstractString, chunk::AbstractString) =
    send_ctrl_frame(Dict("type" => "eval_stream_chunk",
                         "route" => String(route), "chunk" => String(chunk)))

function start_ctrl_dialback!()
    server_url = get(ENV, "BONITOAGENTS_SERVER_URL", "")
    secret     = get(ENV, "BONITOAGENTS_SECRET", "")
    project_id = get(ENV, "BONITOAGENTS_PROJECT_ID", "")
    (isempty(server_url) || isempty(secret) || isempty(project_id)) && return nothing
    SERVER.control.task === nothing || return nothing
    wsurl = replace(rstrip(server_url, '/'), r"^http" => "ws") * "/mcp-ws"
    SERVER.control.task = Base.errormonitor(@async ctrl_dial_loop(wsurl, "$secret $project_id"))
    log_info("control dial-back armed → $wsurl")
    return nothing
end

# Tear the control channel down and reset it so a later start_ctrl_dialback! can
# re-arm (against a DIFFERENT server). Production never calls this — the channel's
# lifetime is the process's — but a test process stands in for many short-lived
# MCP servers in one process, so it must re-point between them. Waits for the old
# dial loop to fully exit BEFORE clearing `stop`, so there's no resurrection race.
function reset_ctrl_dialback!()
    SERVER.control.stop = true
    w = SERVER.control.ws
    if w !== nothing
        try
            close(w)                            # unblock the receive loop
        catch e
            e isa InterruptException && rethrow()
            @debug "reset_ctrl_dialback!: closing control ws failed (already gone?)" exception = e
        end
    end
    t = SERVER.control.task
    if t !== nothing
        try
            wait(t)                             # loop exits at its next stop check
        catch e
            e isa InterruptException && rethrow()
            @debug "reset_ctrl_dialback!: waiting for dial loop failed" exception = e
        end
    end
    SERVER.control.task = nothing
    SERVER.control.ws   = nothing
    SERVER.control.stop = false
    return nothing
end

# Dial-and-serve until the process exits. A dropped socket (server restart,
# network blip) reconnects with exponential backoff — same shape as
# RemoteProxy.dial_loop.
function ctrl_dial_loop(wsurl::AbstractString, handshake::AbstractString;
                        min_backoff::Float64 = 0.5, max_backoff::Float64 = 8.0)
    backoff = min_backoff
    while !SERVER.control.stop
        connected = false
        try
            WebSockets.open(wsurl) do ws
                WebSockets.send(ws, handshake)
                connected = true
                SERVER.control.ws = ws                       # arm the stream forwarder
                try
                    for msg in ws
                        # Per-frame guard: one malformed frame must not drop the
                        # whole control channel.
                        try
                            handle_ctrl_frame!(ws, JSON.parse(String(msg)))
                        catch e
                            log_info("ctrl frame failed: $(sprint(showerror, e))")
                        end
                    end
                finally
                    # Identity-guarded: a reconnect may already have armed a fresh one.
                    SERVER.control.ws === ws && (SERVER.control.ws = nothing)
                end
            end
        catch e
            log_info("ctrl dial failed (will retry in $(backoff)s): $(sprint(showerror, e))")
        end
        backoff = connected ? min_backoff : min(backoff * 2, max_backoff)
        sleep(backoff)
    end
end

"""
    call_server(op; timeout = 30.0, kw...) -> Any

Ask the BonitoAgents server something over the control channel and wait for the
answer. Backs the dev tools, which are the only thing that talks in this
direction; every other MCP process never calls it.

Throws when there is no server attached (standalone BonitoMCP), when the call
times out, or when the server reports an error — all three are things the tool
should tell the agent about verbatim rather than paper over.
"""
function call_server(op::AbstractString; timeout::Real = 30.0, kw...)
    ctrl = SERVER.control
    ctrl.ws === nothing &&
        error("no control channel to the BonitoAgents server (is this MCP server " *
              "running standalone, or has the server gone away?)")
    id = Threads.atomic_add!(ctrl.next_id, 1)
    ch = Channel{Any}(1)
    lock(ctrl.pending_lock) do; ctrl.pending[id] = ch; end
    try
        send_ctrl_frame(Dict("type" => "dev_request", "dev_id" => id,
                             "op" => String(op),
                             "args" => Dict{String,Any}(String(k) => v for (k, v) in kw))) ||
            error("control channel dropped while sending '$op'")
        Base.timedwait(() -> isready(ch), Float64(timeout)) === :ok ||
            error("server call '$op' timed out after $(timeout)s")
        reply = take!(ch)
        reply isa Exception && throw(reply)
        return reply
    finally
        lock(ctrl.pending_lock) do; delete!(ctrl.pending, id); end
    end
end

function handle_ctrl_frame!(ws, msg::AbstractDict)
    op  = get(msg, "op", "")
    rid = get(msg, "request_id", nothing)
    if op == "dev_reply"
        # The answer to one of OUR requests. `pop!` under the lock so exactly one
        # side ever owns the channel.
        ctrl = SERVER.control
        id = Int(get(msg, "dev_id", -1))
        ch = lock(ctrl.pending_lock) do
            haskey(ctrl.pending, id) ? pop!(ctrl.pending, id) : nothing
        end
        ch === nothing && return nothing
        put!(ch, get(msg, "ok", false) ? get(msg, "result", nothing) :
                 ErrorException(String(get(msg, "error", "unknown server error"))))
        return nothing
    elseif op == "interrupt_eval"
        env_path = get(msg, "env_path", nothing)
        env_path isa AbstractString && isempty(env_path) && (env_path = nothing)
        n = interrupt_in_flight!(env_path isa AbstractString ? String(env_path) : nothing)
        log_info("ctrl interrupt_eval (env=$(env_path)) → interrupted $n in-flight eval(s)")
        WebSockets.send(ws, JSON.json(Dict(
            "type" => "interrupt_result", "request_id" => rid, "interrupted" => n)))
    elseif op == "ping"
        WebSockets.send(ws, JSON.json(Dict("type" => "pong", "request_id" => rid)))
    else
        log_info("ctrl: unknown op '$op'")
    end
    return nothing
end
