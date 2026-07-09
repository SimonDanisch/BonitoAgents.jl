# High-level ACP client: manages one claude-agent-acp subprocess per instance.
#
# Usage:
#   handler = MyCustomHandler(...)   # subtype of Handler with on_update overloads
#   client  = AgentClientProtocol.Client(cwd, handler)
#   AgentClientProtocol.prompt!(client, "hello")   # blocks until end_turn/cancelled
#   AgentClientProtocol.cancel!(client)

# Upper bound on how long the `initialize` / `session/new` setup RPCs may take
# before `Client()` gives up on a wedged agent (A3). Generous: cold node start +
# MCP server bring-up can legitimately take a while, but a hang must not be
# forever.
const SETUP_TIMEOUT_SECONDS = 120.0

struct MCPServer
    name::String
    command::String
    args::Vector{String}
    env::Dict{String,String}
end

MCPServer(name, command; args=String[], env=Dict{String,String}()) =
    MCPServer(name, command, args, env)

mutable struct Client
    conn::Connection
    session_id::String
    cwd::String
    # The raw, untouched session-setup result (`session/new` / `session/load`)
    # — mirrors `ToolCallNotif.raw`. The protocol layer stays lossless and
    # unopinionated here; typed views are FUNCTIONS over this dict (e.g.
    # `parse_config_options`), so agents with different metadata need no
    # Client/transport changes.
    session_result::Dict{String,Any}
end

# Back-compat: existing call sites (and tests) construct without a result.
Client(conn::Connection, session_id::AbstractString, cwd::AbstractString) =
    Client(conn, String(session_id), String(cwd), Dict{String,Any}())

# Normalize whatever JSON gave us (Dict{String,Any} in practice).
_result_dict(r) = r isa AbstractDict ?
    Dict{String,Any}(String(k) => v for (k, v) in r) : Dict{String,Any}()

# Default request handler for the local-subprocess Client. Handles the
# fs/terminal/permission RPCs claude-agent-acp can fire. Holds the cwd so
# `fs/read_text_file` / `fs/write_text_file` can be sandboxed if needed
# later — for now it just uses the path the agent sends.
struct FSRequestHandler <: Handler
    cwd::String
end

# Custom handlers compose with FSRequestHandler by wrapping it: the chat
# layer's ChatHandler delegates its on_request to a FSRequestHandler
# instance. Update handling is per-subtype, see e.g. BonitoAgents.ChatHandler.
function on_request(h::FSRequestHandler, method::AbstractString, params)
    if method == "fs/read_text_file"
        path = get(params, "path", "")
        return Dict("content" => read(path, String))

    elseif method == "fs/write_text_file"
        path = get(params, "path", "")
        content = get(params, "content", "")
        mkpath(dirname(path))
        write(path, content)
        return nothing

    elseif method == "session/request_permission"
        # bypassPermissions should prevent this; auto-allow if it appears anyway.
        options = get(params, "options", [])
        idx = findfirst(o -> get(o, "kind", "") in ("allow_once", "allow_always"), options)
        if idx !== nothing
            return Dict("outcome" => Dict("outcome" => "selected",
                                          "optionId" => options[idx]["optionId"]))
        end
        return Dict("outcome" => Dict("outcome" => "cancelled"))

    elseif method == "terminal/create"
        return Dict("terminalId" => string(rand(UInt32), base=16))
    elseif method == "terminal/output"
        return Dict("output" => "", "exitStatus" => nothing)
    elseif method in ("terminal/release", "terminal/kill", "terminal/wait_for_exit")
        return nothing
    end

    @warn "ACP: unhandled client request" method
    return nothing
end

# Discover the agent binary. We rely solely on the user-installed binary:
# the CLAUDE_AGENT_ACP env var, then PATH. Node installs are user-managed, so
# we deliberately do NOT walk the repo for a vendored node_modules/.bin copy —
# that would re-create a node_modules under e.g. dev/Bonito, which we never want.
function find_agent_bin()
    explicit = get(ENV, "CLAUDE_AGENT_ACP", "")
    !isempty(explicit) && return explicit

    global_bin = Sys.which("claude-agent-acp")
    global_bin !== nothing && return global_bin

    return "claude-agent-acp"  # not on PATH; Client() raises a clear error below
end

function Client(cwd::String, handler::Handler = FSRequestHandler(cwd);
                mcp_servers::Vector{MCPServer} = MCPServer[],
                agent_env::Dict{String,String} = Dict{String,String}(),
                agent_bin::String = find_agent_bin())

    isfile(agent_bin) || error(
        "claude-agent-acp not found (resolved to: $agent_bin).\n" *
        "Install it yourself and put it on PATH, e.g.\n" *
        "    npm install -g @agentclientprotocol/claude-agent-acp\n" *
        "or point CLAUDE_AGENT_ACP at the binary / pass agent_bin=.")

    env = merge(Dict(k => v for (k,v) in ENV),
                Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions",
                     "CLAUDE_MAX_TURNS"        => "100"),
                agent_env)

    proc = open(Cmd(`$agent_bin`; env, dir=cwd), "r+")
    conn = Connection(proc, handler)

    # Any setup failure (RPC error, agent that never replies / wedges, a throw
    # while building the session) must close the connection — which kills the
    # subprocess and unblocks the reader/dispatcher — and rethrow, so we never
    # leak an orphaned claude-agent-acp process or hang forever on a dead agent
    # (A3). The setup RPCs carry a timeout for the same reason.
    try
        # NOTE: no `elicitation` capability here — the standalone Client has
        # no UI to render a question form, and advertising it would re-enable
        # claude's AskUserQuestion only to auto-skip every question. UI
        # frontends (BonitoAgents's transports) advertise it themselves.
        send_request(conn, "initialize", Dict(
            "protocolVersion"    => 1,
            "clientCapabilities" => Dict(
                "fs" => Dict("readTextFile" => true, "writeTextFile" => true)
            ),
            "clientInfo" => Dict("name" => "AgentClientProtocol.jl", "version" => "0.1.0")
        ), SETUP_TIMEOUT_SECONDS)

        mcp_list = [Dict("name"    => s.name,
                         "command" => s.command,
                         "args"    => s.args,
                         "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
                    for s in mcp_servers]

        result = send_request(conn, "session/new",
                              Dict("cwd" => cwd, "mcpServers" => mcp_list),
                              SETUP_TIMEOUT_SECONDS)
        session_id = result["sessionId"]

        return Client(conn, session_id, cwd, _result_dict(result))
    catch e
        close(conn)
        rethrow()
    end
end

# One attached image for a multimodal prompt.
#   data:     raw bytes (will be base64-encoded for transport)
#   mime:     e.g. "image/png", "image/jpeg"
struct ImageAttachment
    data::Vector{UInt8}
    mime::String
end

# Send a user message; returns a `Channel{Message}` of the whole, ordered
# messages that make up this turn (agent text, thoughts, tool calls, plans).
# Each streaming message carries its own `updates` channel; iterate the
# returned channel and drain each message's `updates` to render it. The
# channel closes when the turn ends (end_turn / cancelled); if the connection
# dies mid-turn, draining the channel rethrows `ConnectionClosed`.
#
# The whole turn is ONE bounded loop: a local `TurnState` coalesces the raw
# update stream into messages and is `close`d when the stream ends. Nothing
# outlives the turn.
#
# `images` are appended after the text as ACP image content blocks.
#
# `on_subagent` is the turn's out-of-band sink for subagent-tagged updates
# (`_meta.claudeCode.parentToolUseId`): called with each `SubagentActivity`
# straight from the coalescer task, so a live parent-Task feed keeps moving
# even while the message consumer is parked inside another message's drain.
# `nothing` drops subagent updates (they never reach the message channel).
function prompt!(client::Client, text::String;
                 images::Vector{ImageAttachment} = ImageAttachment[],
                 on_subagent::Union{Function,Nothing} = nothing)
    blocks = Any[Dict("type" => "text", "text" => text)]
    for img in images
        push!(blocks, Dict(
            "type"     => "image",
            "data"     => Base64.base64encode(img.data),
            "mimeType" => img.mime,
        ))
    end
    params = Dict("sessionId" => client.session_id, "prompt" => blocks)
    updates, response = prompt_updates(client.conn, params)
    conn = client.conn
    return Channel{Message}(BUF) do messages
        st = TurnState(on_subagent)
        try
            for u in updates
                # Once cancel is issued, stop coalescing/rendering and just
                # drain the backlog so the dispatcher can reach the `cancelled`
                # response and end the turn promptly. `close(st)` below still
                # seals whatever was rendered up to the cancel point.
                (@atomic conn.cancelling) && continue
                parse_update!(messages, st, u)
            end
        finally
            close(st)                 # finish the trailing message + any open tools
        end
        result = take!(response)      # end_turn / cancelled — or ConnectionClosed on teardown
        result isa Exception && throw(result)
    end
end

# Drive `session/load` and collect the resumed session's replayed history as a
# flat, ordered, fully-materialized `Vector{Message}` (same coalescing the live
# `prompt!` loop uses — `parse_update!`/`TurnState`). The agent re-streams the
# session's jsonl as `session/update` notifications during the load; we feed them
# through the coalescer in a task and drain each message's own stream as it
# closes (so a long message can't deadlock on the bounded per-message channel).
#
# `params` is the `session/load` params dict (`sessionId`, `cwd`, `mcpServers`).
# Returns `(msgs, result)` after the load response arrives (the whole replay is
# drained) — `result` is the raw `session/load` response, which carries the same
# session-config blocks as `session/new` (models/modes/configOptions). Throws
# the rpc error / ConnectionClosed if the load fails.
function replay_history(conn::Connection, params)
    updates, response = request_updates(conn, "session/load", params)
    return collect_replayed_updates(updates, response)
end

# Collect a session/load update stream into the resumed history. Split out of
# `replay_history` so it can be driven with synthetic channels in tests.
#
# Each message owns a bounded delta channel; we drain them CONCURRENTLY (one
# task per message), NOT sequentially. A message the agent leaves open mid-
# stream — e.g. a tool whose terminal `tool_call_update` is never re-sent during
# session/load — must not block the `out` consumer. If it did, then on any
# history longer than `BUF` the feeder backs up on the bounded `out`, stops
# draining `updates`, the single dispatcher can never deliver the session/load
# response sitting behind that backlog, `updates` never closes, and the whole
# resume deadlocks ("restoring the conversation…" forever). `close(TurnState)`
# at stream end force-terminates + closes every still-open channel, so the
# concurrent drainers all finish. (The previous sequential `for m in out;
# drain_message!(m)` is what wedged on large resumed sessions.)
function collect_replayed_updates(updates, response)
    out = Channel{Message}(BUF)
    feeder = Base.errormonitor(@async begin
        st = TurnState()
        try
            for u in updates
                parse_update!(out, st, u)
            end
        finally
            close(st)
            close(out)
        end
    end)
    msgs     = Message[]
    drainers = Task[]
    for m in out
        push!(msgs, m)                                          # preserve wire order
        push!(drainers, Base.errormonitor(@async drain_message!(m)))
    end
    foreach(wait, drainers)
    wait(feeder)
    result = take!(response)
    result isa Exception && throw(result)
    return msgs, result
end

# Cancel the active turn (notification, non-blocking).
#
# Two things happen: (1) we flip the connection's `cancelling` flag so the
# `prompt!` consumer stops coalescing/rendering and just drains the buffered
# update backlog — otherwise the agent's `cancelled` response is stuck behind
# that backlog in strict-FIFO order and the turn looks wedged; (2) we send the
# `session/cancel` notification so the agent actually winds the turn down and
# resolves the prompt with `stopReason: cancelled`.
function cancel!(client::Client)
    conn = client.conn
    # No-op when idle (A8): cancelling between turns would otherwise leave
    # `cancelling` latched true and poison the NEXT turn (its consumer would
    # fast-discard every update). Only flip the flag + send the notification
    # when a turn is actually in flight. Checked under `conn.lock` so we read a
    # consistent view of `active_turns`.
    has_turn = lock(() -> !isempty(conn.active_turns), conn.lock)
    has_turn || return nothing
    @atomic conn.cancelling = true
    send_notification(conn, "session/cancel",
                      Dict("sessionId" => client.session_id))
    return nothing
end

# Set one of the session's configurable options (model / mode / effort / …).
# Wire method: `session/set_config_option` with `{sessionId, configId, value}`,
# per the ACP SDK (zSetSessionConfigOptionRequest) and claude-agent-acp's
# setSessionConfigOption handler. Returns the agent's response result, which —
# for claude-agent-acp 0.42.0 — carries the COMPLETE updated `configOptions`
# (the new value applied, or the actual value if the agent clamped/rejected the
# request). So the response is the authoritative post-set state; callers should
# read it back rather than assume the value took. Throws on rpc error.
function set_config_option!(client::Client, config_id::AbstractString,
                            value::AbstractString)
    return send_request(client.conn, "session/set_config_option",
        Dict("sessionId" => client.session_id,
             "configId"  => String(config_id),
             "value"     => String(value)))
end

Base.close(client::Client) = close(client.conn)
