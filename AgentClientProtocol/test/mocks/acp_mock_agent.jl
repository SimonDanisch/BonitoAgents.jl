#!/usr/bin/env julia
#
# A tiny, REAL ACP "agent" subprocess for the AgentClientProtocol test suite.
#
# It speaks JSON-RPC 2.0 over stdio exactly like claude-agent-acp would (one
# JSON object per line on stdout, reads one per line on stdin), but its WHOLE
# behavior is scripted by the test via env vars — so a test can make it answer
# requests, stream N session/update notifications, emit a blank line, return an
# error to initialize, go silent, flood updates, etc.
#
# It is deliberately dependency-free: no JSON package (so spawning is fast and
# needs no precompile in a fresh depot). We hand-roll the *tiny* slice of
# JSON we need — extract an int `id` / a string `method` from an inbound line,
# and emit pre-shaped frames. The client side (the real ACP.Connection) does
# the heavy JSON; here we only need to be wire-correct.
#
# ── Control surface (env vars) ────────────────────────────────────────────────
#   ACP_MOCK_SCENARIO   selects a built-in behavior (see `run_scenario`).
#   ACP_MOCK_N          integer knob a scenario may read (e.g. flood count).
#   ACP_MOCK_READY_FILE if set, the path is `touch`ed once stdin handling is up
#                       (lets a test know the process is live without a frame).
#
# Each scenario is just a function that reads request lines and writes frames.
# Adding a behavior = add a branch in `run_scenario`. No fake transport: this
# is a real OS process the test drives through ACP.SubprocessTransport.

const OUT = stdout
const NL  = "\n"

# Emit one already-JSON-encoded frame string, newline-terminated, flushed.
emit(s::AbstractString) = (print(OUT, s); print(OUT, NL); flush(OUT))

# Minimal field extractors over a raw JSON-RPC line. The client only ever sends
# us numeric ids and simple method strings, so a regex is enough and avoids a
# JSON dependency in the mock.
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
# Connection is live. Returns nothing; reads exactly the two setup requests.
function answer_setup()
    while true
        line = readline(stdin; keep=false)
        isempty(line) && eof(stdin) && return false   # client gone before setup
        isempty(line) && continue
        meth = req_method(line)
        id   = req_id(line)
        if meth == "initialize" && id !== nothing
            emit(result_frame(id, "{\"protocolVersion\":1,\"agentCapabilities\":{}}"))
        elseif meth == "session/new" && id !== nothing
            emit(result_frame(id, "{\"sessionId\":\"s\"}"))
            return true
        elseif id !== nothing
            # Any other request during setup: reply empty so nothing hangs.
            emit(result_frame(id, "{}"))
        end
    end
end

function run_scenario(name::AbstractString)
    n = parse(Int, get(ENV, "ACP_MOCK_N", "0"))

    if name == "echo_requests"
        # A1: answer EVERY request with {"ok": <id>}. The client fires many
        # concurrent `ping`s; we reply to each id we read, no setup needed.
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
            isempty(line) && continue
            id = req_id(line)
            id === nothing && continue
            emit(result_frame(id, "{\"ok\":$id}"))
        end

    elseif name == "setup_then_idle"
        # A2 / A8-idle: complete setup, then sit quietly reading stdin until EOF
        # (client closes). We never stream and never answer further requests.
        answer_setup() || return
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "setup_then_swallow"
        # A2 in-flight: complete setup, then READ further requests but never
        # answer them — so a `send_request` after setup stays pending until the
        # client tears the connection down.
        answer_setup() || return
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "concurrent_turns"
        # Two session/prompt turns. Stream one chunk for turn 1, resolve turn 1,
        # stream one chunk for turn 2, resolve turn 2 — exercising oldest-first
        # routing + handoff over a real wire.
        answer_setup() || return
        id1 = nothing; id2 = nothing
        while id1 === nothing || id2 === nothing
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && return
            isempty(line) && continue
            if req_method(line) == "session/prompt"
                id1 === nothing ? (id1 = req_id(line)) : (id2 = req_id(line))
            end
        end
        emit(text_update("for-turn-1"))      # both open → oldest (turn 1)
        emit(prompt_done(id1))               # handoff: turn 1 resolved
        emit(text_update("for-turn-2"))      # now routes to turn 2
        emit(prompt_done(id2))
        # Drain remaining stdin until the client closes.
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "two_turns_hang"
        # teardown closes turns: open two prompts, never resolve them.
        answer_setup() || return
        opened = 0
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
            isempty(line) && continue
            req_method(line) == "session/prompt" && (opened += 1)
        end

    elseif name == "flood_text"
        # A7 backpressure: on the prompt, stream N DISTINCT text chunks ("u1"..),
        # then resolve. The client must receive every one, in order, none lost.
        answer_setup() || return
        pid = nothing
        while pid === nothing
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && return
            isempty(line) && continue
            req_method(line) == "session/prompt" && (pid = req_id(line))
        end
        for i in 1:n
            emit(text_update("u$i"))
        end
        emit(prompt_done(pid))
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "flood_snapshots"
        # A7 push_snapshot! behavioral test: open ONE tool, then flood N
        # `tool_call_update`s mutating that SAME tool (status flips), then mark
        # it completed and resolve. The client coalesces these onto one ToolCall
        # whose per-message `updates` is a drop-oldest snapshot channel — the
        # consumer must keep up, see the latest, and never wedge.
        answer_setup() || return
        pid = nothing
        while pid === nothing
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && return
            isempty(line) && continue
            req_method(line) == "session/prompt" && (pid = req_id(line))
        end
        emit(tool_call_update("tool1", "pending"))
        for _ in 1:n
            emit(tool_call_status("tool1", "in_progress"))
        end
        emit(tool_call_status("tool1", "completed"))   # latest-wins terminal
        emit(prompt_done(pid))
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "blank_line_then_answer"
        # A4: emit a stray BLANK line before answering a request — the client
        # must skip it (not treat it as EOF) and still answer the request.
        # We do this for the FIRST non-setup request the client sends.
        emit("")                                   # stray blank line up front
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
            isempty(line) && continue
            id = req_id(line)
            id === nothing && continue
            emit("")                               # another blank line between frames
            emit(result_frame(id, "{\"ok\":true}"))
        end

    elseif name == "setup_error"
        # A3: return a JSON-RPC error to `initialize`.
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && return
            isempty(line) && continue
            id = req_id(line)
            id === nothing && continue
            emit(error_frame(id, -32000, "boom"))
            break
        end
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "silent"
        # A3 timeout: read stdin but NEVER answer anything. The client's setup
        # RPC must time out on its own bounded timer.
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    elseif name == "replay_history"
        # replay: on session/load, stream an un-terminated tool_call ("open",
        # pending, never completed) followed by N further COMPLETED tool_calls
        # (> BUF), then resolve session/load. Exercises concurrent per-message
        # drain — an open tool must not wedge the >BUF history collection.
        answer_setup() || return
        lid = nothing
        while lid === nothing
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && return
            isempty(line) && continue
            req_method(line) == "session/load" && (lid = req_id(line))
        end
        emit(tool_call_update("open", "pending"))           # never terminated
        for i in 1:n
            emit(tool_call_update("t$i", "completed"))
        end
        emit(result_frame(lid, "{}"))                       # session/load response
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end

    else
        # Unknown scenario: behave like a silent agent so a misconfigured test
        # fails on a bounded timeout, not a hang.
        while true
            line = readline(stdin; keep=false)
            isempty(line) && eof(stdin) && break
        end
    end
    return
end

function main()
    rf = get(ENV, "ACP_MOCK_READY_FILE", "")
    isempty(rf) || touch(rf)
    scenario = get(ENV, "ACP_MOCK_SCENARIO", "silent")
    run_scenario(scenario)
end

main()
