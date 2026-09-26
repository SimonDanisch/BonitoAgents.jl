# An MCP process's control channel: the link channel its worker's relay opened
# for it (`accept_worker_channel`). Either a chat's own MCP server, or an EVAL
# HOST serving that chat's Julia from another worker (`host_worker`, see
# remote_eval.jl). Requests sent on it are tracked: a caller waiting for a reply
# fails the moment the channel goes instead of sitting out its timeout, and a
# reply is only taken from the channel its request went out on.
mutable struct MCPChannel
    const state::ServerState
    const channel::WorkerLink.LinkChannel
    const project_id::String
    const host_worker::String     # "" for a chat's own MCP
    const pending::Set{String}
    closed::Bool
end

MCPChannel(state::ServerState, channel::WorkerLink.LinkChannel, project_id::AbstractString,
           host_worker::AbstractString) =
    MCPChannel(state, channel, String(project_id), String(host_worker), Set{String}(), false)

# Where the channel is registered: a chat's MCP under its project, an eval host
# under (project, worker).
mcp_registry(ch::MCPChannel) = isempty(ch.host_worker) ?
    (ch.state.mcp_ctrl, ch.project_id) :
    (ch.state.eval_hosts, eval_host_key(ch.project_id, ch.host_worker))

function HTTP.WebSockets.send(ch::MCPChannel, frame::AbstractString)
    rid = get(JSON.parse(frame), "request_id", nothing)
    lock(ch.state.lock) do
        ch.closed && error("MCP channel is closed")
        rid isa AbstractString && push!(ch.pending, String(rid))
    end
    HTTP.WebSockets.send(ch.channel, frame)
    return nothing
end
Base.isopen(ch::MCPChannel) = !ch.closed
HTTP.WebSockets.isclosed(ch::MCPChannel) = ch.closed

untrack_mcp_request!(ch::MCPChannel, rid) =
    lock(ch.state.lock) do; delete!(ch.pending, String(rid)); end

function Base.close(ch::MCPChannel)
    pending = lock(ch.state.lock) do
        ch.closed && return String[]
        ch.closed = true
        registry, key = mcp_registry(ch)
        get(registry, key, nothing) === ch && delete!(registry, key)
        result = collect(ch.pending)
        empty!(ch.pending)
        result
    end
    for rid in pending
        deliver_rpc_error!(ch.state, rid, "MCP channel closed")
    end
    close(ch.channel)
    return nothing
end

# Serve `ch` for as long as its channel lives. A newer channel for the same key
# (the MCP process restarted) replaces an older one.
function serve_mcp_channel(state::ServerState, ch::MCPChannel)
    registry, key = mcp_registry(ch)
    previous = lock(state.lock) do
        old = get(registry, key, nothing)
        registry[key] = ch
        old
    end
    previous === nothing || close(previous)
    @info "MCP channel connected" project_id = ch.project_id eval_host = ch.host_worker
    try
        for msg in ch.channel
            # Per-frame guard: one malformed frame must not drop the channel.
            try
                d = JSON.parse(String(msg))
                rid = get(d, "request_id", nothing)
                if rid isa AbstractString
                    ours = lock(state.lock) do
                        String(rid) in ch.pending && (delete!(ch.pending, String(rid)); true)
                    end
                    ours || continue
                end
                handle_mcp_ctrl_frame!(state, ch, d, ch.project_id, ch.host_worker)
            catch e
                e isa InterruptException && rethrow()
                @warn "MCP channel frame error" project_id = ch.project_id exception = e
            end
        end
    catch e
        # The channel ended by an abort: the MCP process went away, or the link died.
        e isa HTTP.WebSockets.WebSocketError || rethrow()
    finally
        close(ch)
        @info "MCP channel closed" project_id = ch.project_id eval_host = ch.host_worker
    end
    return nothing
end
