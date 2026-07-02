# Agents — the SERVER-side live agent.
#
# Provider DESCRIPTORS (ClaudeCodeAgent/MiMoAgent/OpenCodeAgent/MockAgent), their
# `provider_name`/`label`/`icon` dispatch, and `current_providers()` /
# `find_provider` live in the AgentProviders package — the single source of truth,
# shared with the worker. This file defines the live agent the SERVER drives:
# `WorkerAgent`, which asks a registered worker to spawn the chosen provider's
# binary and drives ACP over the dialed-back WebSocket.
#
# Public surface (the verbs):
#
#     start!(a; on_frame)  dial + ACP handshake; stores the live client IN a
#     stop!(a)             tear the session down
#     isopen(a)            is the session live (Base.isopen)
#     client(a)            the live ACP.Client (or nothing)
#     replay(a)            session/load history captured at start! (empty for fresh)
#     provider_name/label/icon(a)   read from the agent's provider descriptor
#     agent_cwd(a)         the path the agent sees as its working directory

import AgentProviders: AgentProvider, BinAgent,
                       ClaudeCodeAgent, MiMoAgent, OpenCodeAgent, MockAgent,
                       provider_name, label, icon, resumable_session,
                       current_providers, find_provider

# Replay defaults to empty — only resuming agents (a WorkerAgent with a
# resume_session_id) capture session/load history.
replay(::AgentProvider) = ACP.Message[]

# ── WorkerAgent — the worker path as a first-class agent ──────────────────────
# Instead of spawning a local subprocess, a WorkerAgent asks a registered worker
# (over its control WS) to spawn the chosen provider's binary and dial back the
# ACP frames on `/worker-acp`. The `provider` field is the singleton descriptor
# (a `BinAgent`) the worker should run; `provider_name(provider)` is the string
# sent over the wire. `client`/`ws`/`replay` are populated by `start!`.
mutable struct WorkerAgent <: AgentProvider
    state              :: ServerState
    worker_id          :: String
    worker_path        :: String
    mcp                :: Vector{ACP.MCPServer}
    resume_session_id  :: Union{String,Nothing}
    provider           :: BinAgent                  # which provider the worker spawns
    handler            :: ACP.Handler
    ws                 :: Ref{Any}                  # the dialed-back ACP WebSocket
    client             :: Union{ACP.Client,Nothing}
    replay             :: Vector{ACP.Message}
    # Serialises start!/stop! for THIS agent: a ✕-close (stop_session! → stop!)
    # can land mid-bind and null `ws[]` out from under the half-built connection.
    bind_lock          :: ReentrantLock
    # Set by stop! (under bind_lock): this agent is permanently dead. A turn
    # buffered past a chat's close can still reach start! AFTER stop! already
    # ran on the (lazy, still-unbound) agent — without this flag start! would
    # bind it, spawning an orphaned subprocess nothing reaps. A reopen always
    # builds a FRESH WorkerAgent, so latching this closed is correct.
    closed             :: Bool
end

# Default provider is ClaudeCode, overridable via `BT_DEFAULT_PROVIDER` — set by
# the test harness to "MockCode" so new chats run the mock (and so CI without a
# real claude-agent-acp binary works). Production leaves it unset.
default_provider() = find_provider(get(ENV, "BT_DEFAULT_PROVIDER", "ClaudeCode"))

WorkerAgent(state::ServerState, worker_id::AbstractString, worker_path::AbstractString;
            mcp = ACP.MCPServer[],
            resume_session_id::Union{String,Nothing} = nothing,
            provider::BinAgent = default_provider(),
            handler::ACP.Handler = ACP.DiscardHandler()) =
    WorkerAgent(state, String(worker_id), String(worker_path),
                collect(ACP.MCPServer, mcp), resume_session_id, provider, handler,
                Ref{Any}(nothing), nothing, ACP.Message[], ReentrantLock(), false)

# The agent the worker sees as its cwd is the worker-side path.
agent_cwd(a::WorkerAgent) = a.worker_path
replay(a::WorkerAgent)    = a.replay
client(a::WorkerAgent)    = a.client
Base.isopen(a::WorkerAgent) = a.client !== nothing
provider_name(a::WorkerAgent) = provider_name(a.provider)
label(a::WorkerAgent)         = label(a.provider)
icon(a::WorkerAgent)          = icon(a.provider)

# Share the agent's `ws` Ref so a single socket is the one truth on teardown.
# Typed on `WorkerAgent` so it does NOT collide with `ACP.WorkerTransport`'s
# default `WorkerTransport(::Any)` (the collision broke precompilation).
ACP.WorkerTransport(a::WorkerAgent) = ACP.WorkerTransport(a.ws)

# The worker's I/O is an `ACP.WorkerTransport` (the dialed-back WS) so the generic
# ACP `Connection` can drive line-level frames over it. The WorkerAgent owns one;
# `start!` wires its `ws` Ref to the agent's.
function start!(a::WorkerAgent; on_frame::Union{Function,Nothing} = nothing)
    a.client === nothing || return a       # fast idempotent path
    lock(a.bind_lock)
    try
    a.client === nothing || return a       # re-check under the lock
    a.closed && return a                    # stop! already ran: dead agent (a turn buffered
                                            # past close); don't re-bind — a reopen makes a fresh one
    haskey(a.state.worker_control_ws, a.worker_id) ||
        error("Worker '$(a.worker_id)' is not connected")

    mcp_list = mcp_list_payload(a.mcp)

    # Find the project this session belongs to (cosmetic — worker log line).
    project_id = ""
    for p in values(a.state.projects[])
        p.worker_id == a.worker_id && p.worker_path == a.worker_path &&
            (project_id = p.id; break)
    end

    pname = provider_name(a)
    # Only Claude honours the `_meta.systemPrompt.preset` append. The appendix
    # is the BUILT-IN house rules + the user's editable AGENTS.md.
    prompt_meta = a.provider isa ClaudeCodeAgent ?
        system_prompt_meta(agents_prompt_appendix(a.state)) : Dict{String,Any}()

    sid, ch = register_rpc!(a.state)
    send_command(a.state, a.worker_id, Dict(
        "type"       => "open_session",
        "sid"        => sid,
        "project_id" => project_id,
        "cwd"        => a.worker_path,
        "env"        => Dict{String,String}(),
        "mcpServers" => mcp_list,
        "provider"   => pname,
    ))

    # Bounded wait for the worker's /worker-acp upgrade. The transport shares the
    # agent's `ws` Ref, so this populates `a.ws[]` too (one socket, one truth).
    transport = ACP.WorkerTransport(a)
    a.ws[] = take_pending!(a.state, ch, sid, 30.0,
                           "open_session on '$(a.worker_id)'")

    conn = ACP.Connection(transport, a.handler; on_frame)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true),
            "elicitation" => a.provider.elicitation),
        "clientInfo"         => Dict("name"    => "BonitoAgents.WorkerAgent",
                                     "version" => "0.1.0")))

    # Resuming → `session/load` (the agent re-streams history as session/update
    # notifications; `replay_history` captures them). Fresh → `session/new`, no
    # replay. The response carries the session-config blocks either way. Only
    # Claude honours the `_meta.systemPrompt.preset` AGENTS.md append.
    session_id, msgs, result = if a.resume_session_id !== nothing
        @info "ACP: resuming session" cwd=a.worker_path resume=a.resume_session_id
        rmsgs, load_result = ACP.replay_history(conn, merge(Dict(
            "sessionId"  => a.resume_session_id,
            "cwd"        => a.worker_path,
            "mcpServers" => mcp_list,
        ), prompt_meta))
        a.resume_session_id, rmsgs, load_result
    else
        new_result = ACP.send_request(conn, "session/new",
            merge(Dict("cwd" => a.worker_path, "mcpServers" => mcp_list), prompt_meta))
        new_result["sessionId"], ACP.Message[], new_result
    end

    a.client = ACP.Client(conn, session_id, a.worker_path, ACP._result_dict(result))
    a.replay = msgs
    return a
    finally
        unlock(a.bind_lock)
    end
end

function stop!(a::WorkerAgent; permanent::Bool = false)
    # Hold bind_lock so a mid-bind stop! WAITS for the bind to finish (then a.client
    # is set and we close cleanly) instead of nulling ws[] under the half-built conn.
    lock(a.bind_lock) do
        # `permanent=true` (stop_session! on a CLOSED/evicted chat) latches the
        # agent dead so a turn buffered past close can't lazily re-bind it into an
        # orphaned subprocess. Done UNDER bind_lock so it races cleanly with a
        # concurrent start!: either start! already holds the lock (we wait, then
        # close the freshly-bound client → reaped) or it runs after us (sees
        # `closed` → aborts). Restart / worker-reconnect pass permanent=false:
        # they stop! then re-bind the SAME agent, so they must NOT latch.
        permanent && (a.closed = true)
        a.client === nothing || close(a.client)
        a.client = nothing
        a.replay = ACP.Message[]
        a.ws[] = nothing
    end
    # Belt-and-suspenders reap (permanent close only): the acp-ws teardown above
    # SHOULD make the worker's relay exit and kill the agent subprocess, but a
    # bind that raced with this close can leave the dial-back ws half-open — the
    # worker blocks in `receive` and never reaps, orphaning the subprocess. Tell
    # the worker to kill it explicitly over the reliable control ws (idempotent
    # with the relay's own kill). Keyed by worker_path = the worker-side cwd.
    if permanent && haskey(a.state.worker_control_ws, a.worker_id)
        try
            send_command(a.state, a.worker_id,
                         Dict("type" => "close_session", "cwd" => a.worker_path))
        catch e
            @debug "WorkerAgent.stop!: close_session send failed" exception = e
        end
    end
    return a
end
