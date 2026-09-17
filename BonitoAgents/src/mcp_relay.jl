# An MCP control channel carried by an already-authenticated worker connection.
# Implements the small send/close surface used by the control handlers; there
# is no socket dial-back or second server authentication handshake.
mutable struct WorkerMCPChannel
    state::ServerState
    worker_ws::Any
    id::String
    project_id::String
    host_worker::String
    pending::Set{String}
    closed::Bool
end

function HTTP.WebSockets.send(ch::WorkerMCPChannel, frame::AbstractString)
    msg = JSON.parse(String(frame))
    rid = get(msg, "request_id", nothing)
    lock(ch.state.lock) do
        ch.closed && error("worker MCP channel is closed")
        rid isa AbstractString && push!(ch.pending, String(rid))
    end
    send_control(ch.worker_ws, Dict("type" => "mcp_frame", "channel" => ch.id,
                                   "frame" => String(frame)))
end
Base.isopen(ch::WorkerMCPChannel) = !ch.closed
HTTP.WebSockets.isclosed(ch::WorkerMCPChannel) = ch.closed

untrack_mcp_request!(ws, rid) = nothing
untrack_mcp_request!(ch::WorkerMCPChannel, rid) =
    lock(ch.state.lock) do; delete!(ch.pending, String(rid)); end

function close_mcp_channel!(ch::WorkerMCPChannel; notify_worker::Bool = true)
    pending = lock(ch.state.lock) do
        ch.closed && return String[]
        ch.closed = true
        registry = isempty(ch.host_worker) ? ch.state.mcp_ctrl : ch.state.eval_hosts
        key = isempty(ch.host_worker) ? ch.project_id : eval_host_key(ch.project_id, ch.host_worker)
        get(registry, key, nothing) === ch && delete!(registry, key)
        result = collect(ch.pending)
        empty!(ch.pending)
        result
    end
    for rid in pending
        deliver_rpc_error!(ch.state, rid, "worker MCP channel disconnected")
    end
    if notify_worker
        try
            send_control(ch.worker_ws, Dict("type" => "mcp_close", "channel" => ch.id))
        catch e
            e isa InterruptException && rethrow()
        end
    end
    return nothing
end
Base.close(ch::WorkerMCPChannel) = close_mcp_channel!(ch)

function handle_worker_mcp!(state::ServerState, worker_id::String, ws,
                            channels::AbstractDict, cmd::AbstractDict)
    id = String(get(cmd, "channel", ""))
    isempty(id) && error("MCP relay frame is missing its channel")
    kind = get(cmd, "type", "")
    if kind == "mcp_open"
        haskey(channels, id) && error("duplicate MCP relay channel")
        get(state.worker_control_ws, worker_id, nothing) === ws ||
            error("MCP relay arrived on a replaced worker connection")
        pid = String(get(cmd, "project_id", ""))
        p = get(state.projects[], pid, nothing)
        host = get(cmd, "host", false) === true
        if p === nothing || (host ? !p.remote_eval : p.worker_id != worker_id)
            send_control(ws, Dict("type" => "mcp_close", "channel" => id))
            return nothing
        end
        ch = WorkerMCPChannel(state, ws, id, pid, host ? worker_id : "", Set{String}(), false)
        registry = host ? state.eval_hosts : state.mcp_ctrl
        key = host ? eval_host_key(pid, worker_id) : pid
        previous = lock(state.lock) do
            old = get(registry, key, nothing)
            registry[key] = ch
            channels[id] = ch
            old
        end
        previous === nothing || close(previous)
    elseif kind == "mcp_close"
        ch = pop!(channels, id, nothing)
        ch === nothing || close_mcp_channel!(ch; notify_worker = false)
    else
        ch = get(channels, id, nothing)
        (ch === nothing || ch.closed) && return nothing
        d = JSON.parse(String(cmd["frame"]))
        rid = get(d, "request_id", nothing)
        if rid isa AbstractString
            expected = lock(state.lock) do
                present = String(rid) in ch.pending
                delete!(ch.pending, String(rid))
                present
            end
            expected || return nothing
        end
        handle_mcp_ctrl_frame!(state, ch, d, ch.project_id, ch.host_worker)
    end
    return nothing
end
