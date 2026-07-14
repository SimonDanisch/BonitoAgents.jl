# A tiny, REAL ACP "agent" for the AgentClientProtocol test suite.
#
# It speaks JSON-RPC 2.0 over the SAME transport production uses — the worker
# dial-back WebSocket (`ACP.WorkerTransport`). There is NO fake Transport: the
# runtests harness stands up a loopback WS server, wraps the server-side socket
# in a real `WorkerTransport`/`Connection`, and this mock runs as the WS *client*
# on the other end (the role a worker-relayed agent plays in production). The old
# stdio `SubprocessTransport` is gone, so the mock is a WS peer, not a subprocess.
#
# One JSON object per WS frame (matching `WorkerTransport.send`, which emits one
# frame per ACP line). The mock's whole behavior is scripted by `run_scenario`'s
# `name` — a test picks a scenario to make it answer requests, stream N updates,
# emit a blank frame, return an error, go silent, flood, etc.
#
# It stays deliberately JSON-light: the client side (the real `ACP.Connection`)
# does the heavy parsing; here we only extract an int `id` / string `method` from
# an inbound frame (regex) and emit pre-shaped frames.

# ── WS frame I/O ──────────────────────────────────────────────────────────────
# Send one already-JSON-encoded frame (no newline — WS message boundaries frame).
emit(cws, s::AbstractString) = HTTP.WebSockets.send(cws, s)

# Receive the next client→agent frame, or `nothing` on a closed peer (the client's
# `Connection` tore down). Mirrors `readline(stdin)+eof` from the old stdio mock.
function recv_frame(cws)
    HTTP.WebSockets.isclosed(cws) && return nothing
    try
        return String(HTTP.WebSockets.receive(cws))
    catch
        return nothing            # WS closed/errored → EOF for the scenario loop
    end
end

# Minimal field extractors over a raw JSON-RPC frame. The client only ever sends
# numeric ids and simple method strings, so a regex is enough (no JSON dep).
function req_id(line::AbstractString)
    m = match(r"\"id\"\s*:\s*(-?\d+)", line)
    m === nothing ? nothing : parse(Int, m.captures[1])
end
function req_method(line::AbstractString)
    m = match(r"\"method\"\s*:\s*\"([^\"]*)\"", line)
    m === nothing ? nothing : m.captures[1]
end

# Frame builders (hand-rolled JSON for the few shapes we emit).
result_frame(id::Integer, body::AbstractString) =
    "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":$body}"
error_frame(id::Integer, code::Integer, msg::AbstractString) =
    "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":$code,\"message\":\"$msg\"}}"

# An `agent_message_chunk` session/update with the given (already-escaped) text.
text_update(text::AbstractString) =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\"," *
    "\"update\":{\"sessionUpdate\":\"agent_message_chunk\"," *
    "\"content\":{\"type\":\"text\",\"text\":\"$text\"}}}}"

# A `tool_call` session/update opening a tool with the given id/status.
tool_call_update(id::AbstractString, status::AbstractString) =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\"," *
    "\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"$id\"," *
    "\"title\":\"t\",\"kind\":\"other\",\"status\":\"$status\"}}}"

# A `tool_call_update` session/update mutating an existing tool's status.
tool_call_status(id::AbstractString, status::AbstractString) =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\"," *
    "\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"$id\"," *
    "\"status\":\"$status\"}}}"

prompt_done(id::Integer, reason::AbstractString="end_turn") =
    result_frame(id, "{\"stopReason\":\"$reason\"}")

# Answer the standard setup handshake (initialize + session/new) so the client's
# Connection is live. Returns false if the client went away before setup.
function answer_setup(cws)
    while true
        line = recv_frame(cws)
        line === nothing && return false           # client gone before setup
        isempty(line) && continue
        meth = req_method(line)
        id   = req_id(line)
        if meth == "initialize" && id !== nothing
            emit(cws, result_frame(id, "{\"protocolVersion\":1,\"agentCapabilities\":{}}"))
        elseif meth == "session/new" && id !== nothing
            emit(cws, result_frame(id, "{\"sessionId\":\"s\"}"))
            return true
        elseif id !== nothing
            emit(cws, result_frame(id, "{}"))      # any other setup req: reply empty
        end
    end
end

# Read+discard client frames until the peer closes (the tail of most scenarios).
function drain_until_close(cws)
    while recv_frame(cws) !== nothing; end
end

function run_scenario(cws, name::AbstractString, n::Integer = 0)
    if name == "echo_requests"
        # A1: answer EVERY request with {"ok": <id>}. The client fires many
        # concurrent `ping`s; we reply to each id we read, no setup needed.
        while true
            line = recv_frame(cws)
            line === nothing && break
            isempty(line) && continue
            id = req_id(line)
            id === nothing && continue
            emit(cws, result_frame(id, "{\"ok\":$id}"))
        end

    elseif name == "setup_then_idle"
        # A2 / A8-idle / A4b: complete setup, then sit quietly reading frames until
        # the peer closes. We never stream and never answer further requests.
        answer_setup(cws) || return
        drain_until_close(cws)

    elseif name == "setup_then_swallow"
        # A2 in-flight: complete setup, then READ further requests but never answer
        # them — so a `send_request` after setup stays pending until teardown.
        answer_setup(cws) || return
        drain_until_close(cws)

    elseif name == "concurrent_turns"
        # Two session/prompt turns. Stream one chunk for turn 1, resolve turn 1,
        # stream one chunk for turn 2, resolve turn 2 — exercising oldest-first
        # routing + handoff over the real wire.
        answer_setup(cws) || return
        id1 = nothing; id2 = nothing
        while id1 === nothing || id2 === nothing
            line = recv_frame(cws)
            line === nothing && return
            isempty(line) && continue
            if req_method(line) == "session/prompt"
                id1 === nothing ? (id1 = req_id(line)) : (id2 = req_id(line))
            end
        end
        emit(cws, text_update("for-turn-1"))      # both open → oldest (turn 1)
        emit(cws, prompt_done(id1))               # handoff: turn 1 resolved
        emit(cws, text_update("for-turn-2"))      # now routes to turn 2
        emit(cws, prompt_done(id2))
        drain_until_close(cws)

    elseif name == "two_turns_hang"
        # teardown closes turns: open two prompts, never resolve them.
        answer_setup(cws) || return
        drain_until_close(cws)

    elseif name == "flood_text"
        # A7 backpressure: on the prompt, stream N DISTINCT text chunks ("u1"..),
        # then resolve. The client must receive every one, in order, none lost.
        answer_setup(cws) || return
        pid = nothing
        while pid === nothing
            line = recv_frame(cws)
            line === nothing && return
            isempty(line) && continue
            req_method(line) == "session/prompt" && (pid = req_id(line))
        end
        for i in 1:n
            emit(cws, text_update("u$i"))
        end
        emit(cws, prompt_done(pid))
        drain_until_close(cws)

    elseif name == "flood_snapshots"
        # A7 push_snapshot! behavioral test: open ONE tool, then flood N
        # `tool_call_update`s mutating that SAME tool (status flips), then mark it
        # completed and resolve. The client coalesces these onto one ToolCall whose
        # per-message `updates` is a drop-oldest snapshot channel — the consumer
        # must keep up, see the latest, and never wedge.
        answer_setup(cws) || return
        pid = nothing
        while pid === nothing
            line = recv_frame(cws)
            line === nothing && return
            isempty(line) && continue
            req_method(line) == "session/prompt" && (pid = req_id(line))
        end
        emit(cws, tool_call_update("tool1", "pending"))
        for _ in 1:n
            emit(cws, tool_call_status("tool1", "in_progress"))
        end
        emit(cws, tool_call_status("tool1", "completed"))   # latest-wins terminal
        emit(cws, prompt_done(pid))
        drain_until_close(cws)

    elseif name == "blank_line_then_answer"
        # A4: emit a stray BLANK frame before answering a request — the client must
        # skip it (not treat it as EOF) and still answer. We do this for the FIRST
        # non-setup request the client sends.
        emit(cws, "")                                   # stray blank frame up front
        while true
            line = recv_frame(cws)
            line === nothing && break
            isempty(line) && continue
            id = req_id(line)
            id === nothing && continue
            emit(cws, "")                               # another blank between frames
            emit(cws, result_frame(id, "{\"ok\":true}"))
        end

    elseif name == "setup_error"
        # A3: return a JSON-RPC error to `initialize`.
        while true
            line = recv_frame(cws)
            line === nothing && return
            isempty(line) && continue
            id = req_id(line)
            id === nothing && continue
            emit(cws, error_frame(id, -32000, "boom"))
            break
        end
        drain_until_close(cws)

    elseif name == "silent"
        # A3 timeout: read frames but NEVER answer anything. The client's setup RPC
        # must time out on its own bounded timer.
        drain_until_close(cws)

    elseif name == "replay_history"
        # replay: on session/load, stream an un-terminated tool_call ("open",
        # pending, never completed) followed by N further COMPLETED tool_calls
        # (> BUF), then resolve session/load. Exercises concurrent per-message
        # drain — an open tool must not wedge the >BUF history collection.
        answer_setup(cws) || return
        lid = nothing
        while lid === nothing
            line = recv_frame(cws)
            line === nothing && return
            isempty(line) && continue
            req_method(line) == "session/load" && (lid = req_id(line))
        end
        emit(cws, tool_call_update("open", "pending"))      # never terminated
        for i in 1:n
            emit(cws, tool_call_update("t$i", "completed"))
        end
        emit(cws, result_frame(lid, "{}"))                  # session/load response
        drain_until_close(cws)

    else
        # Unknown scenario: behave like a silent agent so a misconfigured test
        # fails on a bounded timeout, not a hang.
        drain_until_close(cws)
    end
    return
end
