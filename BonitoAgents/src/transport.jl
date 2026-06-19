# Worker WebSocket line-transport for the ACP `Connection`.
#
# Agents are first-class (see agents.jl). A `WorkerAgent` runs the chosen
# provider on a remote worker and routes ACP frames over the WS the worker
# dials back on `/worker-acp`. The generic ACP `Connection` drives line-level
# I/O through a `ChatTransport`; `WorkerTransport` is that transport for the
# worker path — a thin `ACP.Transport` over the dialed-back WS, owned by the
# `WorkerAgent` that built it. (The old in-process `LocalTransport` /
# `MockTransport` and the `@enum AgentProvider` + its predicate tables are
# gone — that logic is now construction DATA on the agent subtypes.)

const ACP = AgentClientProtocol

"""
    abstract type ChatTransport <: ACP.Transport

Line-level I/O the generic ACP `Connection` drives. The only concrete subtype
left is `WorkerTransport` (the worker dial-back WS); local/mock sessions are
handled by `BinAgent` subtypes spawning a real `SubprocessTransport` directly.
Overloads `ACP.send`/`ACP.recv`/`Base.close`/`ACP.transport_eof`.
"""
abstract type ChatTransport <: ACP.Transport end

# Standard MCP-list serialisation, shared by every agent bring-up.
mcp_list_payload(mcp_servers) =
    [Dict("name"    => s.name,
          "command" => s.command,
          "args"    => s.args,
          "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
     for s in mcp_servers]

# Server-global system prompt (state_dir/AGENTS.md) as the `_meta` extension
# claude-agent-acp honors on `session/new` / `session/load`:
# `{_meta: {systemPrompt: {type: "preset", preset: "claude_code", append}}}` —
# the text is APPENDED to claude's stock system prompt, so it composes with
# (never replaces) the per-project CLAUDE.md hierarchy. Empty file ⇒ empty
# dict ⇒ the params stay byte-identical to before.
function system_prompt_meta(text::AbstractString)
    isempty(text) && return Dict{String,Any}()
    return Dict{String,Any}("_meta" => Dict{String,Any}(
        "systemPrompt" => Dict{String,Any}(
            "type"   => "preset",
            "preset" => "claude_code",
            "append" => String(text))))
end

# ── Worker over WebSocket ────────────────────────────────────────────────────
# A `WorkerTransport` is the line-I/O wrapper a `WorkerAgent.start!` builds once
# it has the dialed-back ACP WS. The `ws` Ref is shared with the agent so a
# `close(client)` (which closes the Connection's transport) tears the same
# socket down. There is no provider/session state here anymore — that lives on
# the `WorkerAgent`.

mutable struct WorkerTransport <: ChatTransport
    ws :: Ref{Any}
end

WorkerTransport() = WorkerTransport(Ref{Any}(nothing))
# The `WorkerTransport(agent::WorkerAgent)` convenience (shares the agent's `ws`
# Ref so teardown is one socket) lives in agents.jl, where `WorkerAgent` is known —
# typed so it doesn't collide with the struct's default `WorkerTransport(::Any)`.

function ACP.send(t::WorkerTransport, line::AbstractString)
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

function ACP.recv(t::WorkerTransport)
    ws = t.ws[]
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
# frame. The ACP `reader_loop` uses `transport_eof` to tell the two apart: without
# this method it falls to `transport_eof(::Transport) = false`, so when the worker
# WS closes (e.g. `stop_session!` → `close(transport)`) `recv` returns "" with no
# block, `reader_loop` `continue`s, and the loop hot-spins at 100% CPU on its
# (sticky, thread-1) task — starving every other server `@async` handler. A closed
# or never-dialed ws yields no more frames, so it IS EOF.
ACP.transport_eof(t::WorkerTransport) =
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
