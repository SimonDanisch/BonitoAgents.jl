# High-level ACP client: manages one claude-agent-acp subprocess per instance.
#
# Usage:
#   handler = MyCustomHandler(...)   # subtype of Handler with on_update overloads
#   client  = AgentClientProtocol.Client(cwd, handler)
#
#   # The session's main thread is ONE stream, for as long as the session lives.
#   @async for m in client.messages
#       m isa AgentClientProtocol.StreamFlush ? AgentClientProtocol.signal_rendered!(m) : render(m)
#   end
#
#   AgentClientProtocol.wait_turn!(AgentClientProtocol.prompt!(client, "hello"))
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

    # ── The session's main thread ────────────────────────────────────────────
    # ONE continuous stream, for the session's whole life. `updates` takes raw
    # main-thread `SessionUpdate`s straight from the dispatcher (plus
    # `StreamFlush` boundary markers); a single coalescer turns them into whole
    # `Message`s on `messages`, which the consumer renders in wire order.
    #
    # Not per-prompt. The agent talks on this stream inside a prompt AND
    # between prompts (the auto-wake after backgrounded work), and it is the
    # same voice either way — giving those two cases separate pipelines meant
    # two renderers that had to be kept in agreement, and they weren't (an
    # auto-wake session used to collapse into one merged bubble with its tools
    # erased). A prompt is a SPAN over this stream: `prompt!` opens it,
    # `StreamFlush` marks where it ends.
    updates::Channel{Any}
    messages::Channel{Message}
    coalescer::Task
end

function Client(conn::Connection, session_id::AbstractString, cwd::AbstractString,
                session_result::Dict{String,Any} = Dict{String,Any}())
    updates   = Channel{Any}(BUF)
    messages  = Channel{Message}(BUF)
    coalescer = Base.errormonitor(@async coalesce_main!(conn, updates, messages))
    client = Client(conn, String(session_id), String(cwd), session_result,
                    updates, messages, coalescer)
    # The main sink is the session's own, installed here rather than by the
    # embedder: there is exactly one main thread per session and it always has
    # somewhere to go. Nothing to forget to wire, nothing to drop.
    conn.main_stream = updates
    return client
end

# Coalesce the main thread's raw updates into whole messages, for as long as the
# session lives. `TurnState` is persistent here — see its docstring: `close` is a
# boundary on this stream, not the end of it.
function coalesce_main!(conn::Connection, updates::Channel{Any},
                        messages::Channel{Message})
    st = TurnState()
    try
        for u in updates
            coalesce!(messages, st, u)
        end
    finally
        close_turn!(messages, st)
        close(messages)
    end
    return nothing
end

# Seal the trailing bubble and let the consumer catch up. A cancelled span also
# releases its live tools: no terminal frame is coming for them.
function coalesce!(messages::Channel{Message}, st::TurnState, u::StreamFlush)
    u.abandoned ? close_turn!(messages, st) : seal_message!(st)
    put!(messages, u)
    return nothing
end

# The agent starts a turn of its own: what came before is sealed, and the
# consumer meets the turn ahead of anything it says.
function coalesce!(messages::Channel{Message}, st::TurnState, u::TurnStarted)
    seal_message!(st)
    put!(messages, u)
    return nothing
end

# Everything else is rendered, cancel or not: it is output the agent already produced.
coalesce!(messages::Channel{Message}, st::TurnState, u::SessionUpdate) = parse_update!(messages, st, u)

# Put a boundary on the main stream and hand back the marker to wait on, or
# `nothing` if the stream is already gone. The CALLER waits (`take!(m.done)`),
# because the caller owns the consumer that signals it.
function flush_main!(client::Client)
    marker = StreamFlush()
    try
        put!(client.updates, marker)
    catch e
        e isa InvalidStateException || rethrow()   # stream torn down
        return nothing
    end
    return marker
end

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

# Send a user message. Returns the turn's `PromptTurn`; `wait_turn!` blocks on it
# for the stopReason (`end_turn` / `cancelled`) and rethrows a `ConnectionClosed`
# if the session died. `span.flush` is put on the main stream at the response
# frame, so a renderer sees the turn's boundary exactly where the agent drew it.
#
# The turn's CONTENT does not come back through here. It is the session's main
# thread talking, and it arrives on `client.messages` like everything else the
# main thread says — before this call, during it, and after it. Render that
# stream continuously; use `flush_main!` to find out when everything up to a
# point has landed.
#
# `images` are appended after the text as ACP image content blocks.
function prompt!(client::Client, text::String;
                 images::Vector{ImageAttachment} = ImageAttachment[])
    blocks = Any[Dict("type" => "text", "text" => text)]
    for img in images
        push!(blocks, Dict(
            "type"     => "image",
            "data"     => Base64.base64encode(img.data),
            "mimeType" => img.mime,
        ))
    end
    params = Dict("sessionId" => client.session_id, "prompt" => blocks)
    return prompt_request(client.conn, params)
end

# Block until the turn settles; returns the stopReason result, throws on an rpc
# error or a torn-down connection.
function wait_turn!(span::PromptTurn)
    result = take!(span.response)
    result isa Exception && throw(result)
    return result
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
# Replay has no UI to stream into: we want each message whole. Nothing here has
# to drain anything for that — every message folds its own stream through its own
# pump — so this collects in wire order and then waits for those pumps to finish.
#
# That is the whole reason `MessageStream` exists. The channel-per-message design
# this replaces needed a `drain_message!` method for EVERY message type, since an
# unread bounded channel backs the feeder up on `out`, the single dispatcher then
# never delivers the `session/load` response sitting behind that backlog, and the
# resume hangs on "restoring the conversation…". Three types never got a method,
# and every resume that replayed one died on the `MethodError` instead.
#
# `close_turn!` at stream end closes every still-open message (a tool whose
# terminal `tool_call_update` the agent never re-sent during load), so every pump
# reaches its end and `wait` returns.
function collect_replayed_updates(updates, response)
    out = Channel{Message}(BUF)
    feeder = Base.errormonitor(@async begin
        st = TurnState()
        try
            for u in updates
                parse_update!(out, st, u)
            end
        finally
            close_turn!(out, st)
            close(out)
        end
    end)
    msgs = Message[]
    for m in out
        push!(msgs, m)                                          # preserve wire order
    end
    wait(feeder)
    # Every streaming message is complete once its pump has drained what the
    # feeder sent. A message with no stream (config, mode, usage, a plan) has
    # nothing to wait for, which is the case that used to need a method nobody
    # remembered to write.
    for m in msgs
        m isa StreamingMessage && wait(m.stream)
    end
    result = take!(response)
    result isa Exception && throw(result)
    return msgs, result
end

"""
    open_turns(client) -> Vector{Turn}

The turns open right now (see `open_turns(::Connection)`): empty when the agent
is not working.
"""
open_turns(client::Client) = open_turns(client.conn)

# Whether the client's connection can still carry a prompt. Not whether the
# agent is working (`open_turns`): whether it is reachable.
Base.isopen(client::Client) = isopen(client.conn)

"""
    cancel!(client) -> Vector{Turn}

Ask the agent to stop: a `session/cancel`, which reaches every open turn, ours
and the agent's own. Returns those turns; each is over when the agent says so,
like any turn (`wait`, `wait_over`). Nothing open, nothing sent: the empty list.

The frames the agent already sent are still delivered. Stamps `cancel_at` on
the first cancel since the last request.
"""
function cancel!(client::Client)
    conn = client.conn
    turns = open_turns(conn)
    isempty(turns) && return turns
    (@atomic conn.cancel_at) > 0 || (@atomic conn.cancel_at = time())
    send_notification(conn, "session/cancel",
                      Dict("sessionId" => client.session_id))
    return turns
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
                            value::AbstractString; timeout::Real = 30.0)
    return send_request(client.conn, "session/set_config_option",
        Dict("sessionId" => client.session_id,
             "configId"  => String(config_id),
             "value"     => String(value)), timeout)
end

# Close the connection FIRST (the dispatcher stops, so no further update can be
# delivered), then the main stream — the coalescer drains what's buffered, seals
# its state, and closes `messages`, which ends the consumer. A `deliver_update!`
# racing us finds the channel closed and returns.
#
# The connection's own teardown closes the main stream too, so this is not the
# only way it ends (that is the point — a severed transport must end it with
# nobody calling anything). Doing it here as well makes an explicit close
# immediate rather than dependent on the dispatcher task getting scheduled.
function Base.close(client::Client)
    close(client.conn)
    isopen(client.updates) && close(client.updates)
    return nothing
end
