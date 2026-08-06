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
    conn.on_main_update = u -> deliver_update!(conn, updates, u)
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
            if u isa StreamFlush
                # Seal the trailing bubble ONLY. A live tool must survive a
                # boundary — see `seal_message!`.
                seal_message!(st)
                put!(messages, u)      # ... then let the consumer catch up to here
                continue
            end
            # Everything that reaches here is rendered. There is no cancel gate:
            # frames the agent already sent are output it already produced, and
            # discarding them here lost them for good (unparsed, so never stored
            # either) — the user saw a dead chat and only got the backlog on a
            # reload, which replays history from the agent.
            parse_update!(messages, st, u)
        end
    finally
        close(st)
        close(messages)
    end
    return nothing
end

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

# Send a user message. Returns the turn's `PromptSpan`; `wait_turn!` blocks on it
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
function wait_turn!(span::PromptSpan)
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
"""
    session_live(client) -> Bool

Whether the agent has anything running that a cancel could reach.

Cancel targets the SESSION, not one request, and there are two independent
reasons the agent may be working: we asked it to (`active_prompts`), or it woke
itself up after backgrounded work finished (`Unprompted`). Reading only the
first is why stop used to be a no-op for the whole auto-wake window, while the
user watched it run tools.

Exposed separately from [`cancel!`] because the two callers need OPPOSITE
information from the same fact. `cancel!` wants "is there something to send a
cancel to". A UI wants "is my spinner telling the truth" — and if it isn't, the
answer is to reconcile its own state, NOT to discard whatever the user has
queued up behind a turn that already ended.
"""
session_live(client::Client) = is_working(session_activity(client.conn))

function cancel!(client::Client)
    conn = client.conn
    # A no-op when GENUINELY idle (A8) — no prompt open and no un-prompted work
    # since the last request or cancel. That matters: `cancelling` gates the main
    # thread, so latching it true over an idle gap would silently drop the
    # agent's next burst of work until a new prompt cleared it.
    session_live(client) || return false
    # `Cancelling` is a state, not a mute: delivery is untouched (see
    # `deliver_update!`). It ends when the turn it cancelled settles, or
    # immediately if there was no prompt to settle — so cancelling un-prompted
    # work cannot leave the session stuck the way the old latch did.
    # This cancel CONSUMES the work it acted on. Without clearing the recency,
    # `Idle` is not a stable state: `settle` reads a recent `last_work_at` and
    # resurrects `Unprompted` on the next read, so a cancelled un-prompted
    # episode would keep re-reporting itself as live for the whole quiet window.
    # Frames that arrive after this stamp it afresh — an agent that ignores the
    # cancel and keeps streaming is still, correctly, working.
    @atomic conn.last_work_at = 0.0
    @atomic conn.activity = Cancelling()
    settle!(conn)
    send_notification(conn, "session/cancel",
                      Dict("sessionId" => client.session_id))
    return true
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

# Close the connection FIRST (the dispatcher stops, so no further update can be
# delivered), then the main stream — the coalescer drains what's buffered, seals
# its state, and closes `messages`, which ends the consumer. A `deliver_update!`
# racing us finds the channel closed and returns.
function Base.close(client::Client)
    close(client.conn)
    isopen(client.updates) && close(client.updates)
    return nothing
end
