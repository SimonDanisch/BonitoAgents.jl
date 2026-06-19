# Agents — first-class, dispatchable, self-contained.
#
# An agent IS the whole state: how to spawn (bin/args/env), the context it runs in
# (cwd/handler/mcp), AND its live session (the ACP client) once started. Public
# surface is just the verbs:
#
#     start!(agent)      spawn + ACP handshake; stores the live client IN the agent
#     stop!(agent)       tear the session down
#     isopen(agent)      is the session live (Base.isopen)
#     client(agent)      the live ACP.Client (or nothing)
#
# `BinAgent` is the abstract supertype for "an ACP agent backed by a spawned
# executable": its subtypes carry the standard fields below and inherit the verbs.
# Provider-specific differences (Claude's env, MiMo/OpenCode's `acp` subcommand,
# OpenCode's strict elicitation shape) are construction DATA, not `p == X` predicate
# chains. A new agent = a new subtype + a constructor, not a branch in five functions.
# Override a verb only where an agent genuinely differs (e.g. MockAgent's dial-back).
#
#     Chat(; agents = [ClaudeCodeAgent(), MockAgent(), MiMoAgent(), OpenCodeAgent()])
#
# drives the selection menu; each entry is one of these instances.

abstract type AgentProvider end

# Public surface shared by every agent kind:
#
#   start!(a; on_frame)  spawn/dial + ACP handshake; stores the live client IN a
#   stop!(a)             tear the session down
#   isopen(a)            is the session live (Base.isopen)
#   client(a)            the live ACP.Client (or nothing)
#   replay(a)            session/load history captured at start! (empty for fresh)
#   provider_name(a)     the wire string the worker/UI keys on ("ClaudeCode", …)
#   label(a) / icon(a)   UI display strings (data, not predicate chains)
#   agent_cwd(a)         the path the agent sees as its working directory

# Replay defaults to empty — only resuming agents (WorkerAgent with a
# resume_session_id) capture session/load history.
replay(::AgentProvider) = ACP.Message[]

# The path the *agent* sees as cwd; chat builds its FSRequestHandler against it.
agent_cwd(a::AgentProvider) = a.cwd

# Subtypes MUST carry these fields:
#   bin::String  args::Vector{String}  env::Dict{String,String}  elicitation::Dict{String,Any}
#   cwd::String  handler::ACP.Handler  mcp::Vector{ACP.MCPServer} client::Union{ACP.Client,Nothing}
abstract type BinAgent <: AgentProvider end

# `on_frame` is the optional raw-ACP wire tap (per-session: a fresh Connection
# re-arms it on every start!). A BinAgent is always a fresh `session/new` — no
# resume, no replay, and no server-wide AGENTS.md system prompt (that's a
# WorkerAgent concept), matching the old LocalTransport behaviour.
function start!(a::BinAgent; on_frame::Union{Function,Nothing} = nothing)
    a.client === nothing || return a       # idempotent
    isfile(a.bin) || error("Agent binary not found at: $(a.bin)")
    proc = open(Cmd(`$(a.bin) $(a.args)`; env = a.env, dir = a.cwd), "r+")
    conn = ACP.Connection(ACP.SubprocessTransport(proc), a.handler; on_frame)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict("fs" => Dict("readTextFile" => true, "writeTextFile" => true),
                                     "elicitation" => a.elicitation),
        "clientInfo"         => Dict("name" => "BonitoAgents", "version" => "0.1.0")))
    r = ACP.send_request(conn, "session/new",
                         Dict("cwd" => a.cwd, "mcpServers" => mcp_list_payload(a.mcp)))
    a.client = ACP.Client(conn, r["sessionId"], a.cwd, ACP._result_dict(r))
    return a
end

stop!(a::BinAgent)       = (a.client === nothing || close(a.client); a.client = nothing; a)
Base.isopen(a::BinAgent) = a.client !== nothing
client(a::BinAgent)      = a.client

# Private bin resolvers (env override → PATH → well-known path → bare name) — these are
# construction helpers, NOT a dispatched public API.
function claude_bin()
    e = get(ENV, "CLAUDE_AGENT_ACP", ""); isempty(e) || return e
    b = Sys.which("claude-agent-acp"); b === nothing ? "claude-agent-acp" : b
end
function mimo_bin()
    e = get(ENV, "MIMO_AGENT_ACP", ""); isempty(e) || return e
    b = Sys.which("mimo"); b !== nothing && return b
    p = joinpath(homedir(), ".mimocode", "bin", "mimo"); isfile(p) ? p : "mimo"
end
function opencode_bin()
    e = get(ENV, "OPENCODE_AGENT_ACP", ""); isempty(e) || return e
    b = Sys.which("opencode"); b !== nothing && return b
    p = joinpath(homedir(), ".opencode", "bin", "opencode"); isfile(p) ? p : "opencode"
end
function mock_bin()
    e = get(ENV, "MOCK_AGENT_ACP", ""); isempty(e) || return e
    p = joinpath(dirname(@__DIR__), "test", "mocks", "mock_claude_agent_acp")
    isfile(p) ? p : "mock_claude_agent_acp"
end

envdict(extra) = merge(Dict(k => v for (k, v) in ENV), extra)

mutable struct ClaudeCodeAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
    cwd::String; handler::ACP.Handler; mcp::Vector{ACP.MCPServer}; client::Union{ACP.Client,Nothing}
end
ClaudeCodeAgent(; cwd = "", handler = ACP.DiscardHandler(), mcp = ACP.MCPServer[]) =
    ClaudeCodeAgent(claude_bin(), String[],
        envdict(Dict("CLAUDE_PERMISSION_MODE" => "bypassPermissions", "CLAUDE_MAX_TURNS" => "100")),
        Dict{String,Any}("form" => true), cwd, handler, collect(ACP.MCPServer, mcp), nothing)

mutable struct MiMoAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
    cwd::String; handler::ACP.Handler; mcp::Vector{ACP.MCPServer}; client::Union{ACP.Client,Nothing}
end
MiMoAgent(; cwd = "", handler = ACP.DiscardHandler(), mcp = ACP.MCPServer[]) =
    MiMoAgent(mimo_bin(), ["acp"], envdict(Dict{String,String}()),
        Dict{String,Any}("form" => true), cwd, handler, collect(ACP.MCPServer, mcp), nothing)

mutable struct OpenCodeAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
    cwd::String; handler::ACP.Handler; mcp::Vector{ACP.MCPServer}; client::Union{ACP.Client,Nothing}
end
OpenCodeAgent(; cwd = "", handler = ACP.DiscardHandler(), mcp = ACP.MCPServer[]) =
    OpenCodeAgent(opencode_bin(), ["acp"], envdict(Dict{String,String}()),
        Dict{String,Any}("form" => Dict{String,Any}()), cwd, handler, collect(ACP.MCPServer, mcp), nothing)

# MockAgent: a real-spawned agent (the only fake = its behavior). `responses` is a Dict
# (question → reply) or a callback; shipped to the spawned mock over a dial-back control
# channel (wired in a follow-up — today it carries the scenario env).
mutable struct MockAgent <: BinAgent
    bin::String; args::Vector{String}; env::Dict{String,String}; elicitation::Dict{String,Any}
    cwd::String; handler::ACP.Handler; mcp::Vector{ACP.MCPServer}; client::Union{ACP.Client,Nothing}
    responses::Any
end
MockAgent(responses = Dict{String,Any}(); cwd = "", handler = ACP.DiscardHandler(), mcp = ACP.MCPServer[]) =
    MockAgent(mock_bin(), String[], envdict(Dict("BT_MOCK_ACP_SCENARIO" => "normal")),
        Dict{String,Any}("form" => true), cwd, handler, collect(ACP.MCPServer, mcp), nothing, responses)
# TODO: dial-back responses — wire `responses` to the spawned mock over a
# control channel; today it carries the `BT_MOCK_ACP_SCENARIO` env instead.

# ── Per-agent display + protocol data (NOT predicate chains) ──────────────────
# `provider_name` is the wire string the worker keys on when it resolves which
# binary to spawn (see BonitoWorker.handle_open_session: "ClaudeCode"/"MiMoCode"/
# "OpenCode") AND the UI's stable provider identity. `label`/`icon` are the
# human-facing strings (mirror the deleted provider_label/provider_icon tables).
provider_name(::ClaudeCodeAgent) = "ClaudeCode"
provider_name(::MiMoAgent)       = "MiMoCode"
provider_name(::OpenCodeAgent)   = "OpenCode"
provider_name(::MockAgent)       = "MockCode"

label(::ClaudeCodeAgent) = "Claude Code"
label(::MiMoAgent)       = "MiMo Code"
label(::OpenCodeAgent)   = "OpenCode"
label(::MockAgent)       = "Mock Agent"

icon(::ClaudeCodeAgent) = "bt-provider-claude"
icon(::MiMoAgent)       = "bt-provider-mimo"
icon(::OpenCodeAgent)   = "bt-provider-opencode"
icon(::MockAgent)       = "bt-provider-mock"

# The set of agent types offered in the provider-switcher menu. Construction
# data — a new agent joins by appending here (matching the old enum tuple).
const AGENT_KINDS = (ClaudeCodeAgent, MiMoAgent, OpenCodeAgent, MockAgent)

# Build a fresh agent INSTANCE of `kind`, carrying over a chat's context
# (cwd/handler/mcp). Used by `switch_provider!` to swap the live agent without a
# `kind == X` branch chain.
new_agent(kind::Type{<:BinAgent}; cwd = "", handler = ACP.DiscardHandler(), mcp = ACP.MCPServer[]) =
    kind(; cwd, handler, mcp)

# ── WorkerAgent — the worker path as a first-class agent ──────────────────────
# Instead of spawning a local subprocess, a WorkerAgent asks a registered worker
# (over its control WS) to spawn the chosen provider's binary and dial back the
# ACP frames on `/worker-acp`. The `kind` field is the CONCRETE BinAgent type the
# worker should run (ClaudeCodeAgent/MiMoAgent/…); `provider_name(kind())` is the
# string sent over the wire. `client`/`ws`/`replay` are populated by `start!`.
mutable struct WorkerAgent <: AgentProvider
    state              :: ServerState
    worker_id          :: String
    worker_path        :: String
    mcp                :: Vector{ACP.MCPServer}
    resume_session_id  :: Union{String,Nothing}
    kind               :: Type{<:BinAgent}          # which provider the worker spawns
    handler            :: ACP.Handler
    ws                 :: Ref{Any}                  # the dialed-back ACP WebSocket
    client             :: Union{ACP.Client,Nothing}
    replay             :: Vector{ACP.Message}
end

WorkerAgent(state::ServerState, worker_id::AbstractString, worker_path::AbstractString;
            mcp = ACP.MCPServer[],
            resume_session_id::Union{String,Nothing} = nothing,
            kind::Type{<:BinAgent} = ClaudeCodeAgent,
            handler::ACP.Handler = ACP.DiscardHandler()) =
    WorkerAgent(state, String(worker_id), String(worker_path),
                collect(ACP.MCPServer, mcp), resume_session_id, kind, handler,
                Ref{Any}(nothing), nothing, ACP.Message[])

# The agent the worker sees as its cwd is the worker-side path.
agent_cwd(a::WorkerAgent) = a.worker_path
replay(a::WorkerAgent)    = a.replay
client(a::WorkerAgent)    = a.client
Base.isopen(a::WorkerAgent) = a.client !== nothing
provider_name(a::WorkerAgent) = provider_name(a.kind())
label(a::WorkerAgent)         = label(a.kind())
icon(a::WorkerAgent)          = icon(a.kind())

# Share the agent's `ws` Ref so a single socket is the one truth on teardown.
# Typed on `WorkerAgent` so it does NOT collide with the struct's default
# `WorkerTransport(::Any)` (the collision broke precompilation).
WorkerTransport(a::WorkerAgent) = WorkerTransport(a.ws)

# The worker's I/O is a `ChatTransport` (transport.jl) so the generic ACP
# `Connection` can drive line-level frames over the dialed-back WS. The
# WorkerAgent owns one; `start!` wires its `ws` Ref to the agent's.
function start!(a::WorkerAgent; on_frame::Union{Function,Nothing} = nothing)
    a.client === nothing || return a       # idempotent
    haskey(a.state.worker_control_ws, a.worker_id) ||
        error("Worker '$(a.worker_id)' is not connected")

    sid, ch = register_rpc!(a.state)
    mcp_list = mcp_list_payload(a.mcp)

    # Find the project this session belongs to (cosmetic — worker log line).
    project_id = ""
    for p in values(a.state.projects[])
        p.worker_id == a.worker_id && p.worker_path == a.worker_path &&
            (project_id = p.id; break)
    end

    pname = provider_name(a)
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
    transport = WorkerTransport(a)
    a.ws[] = take_pending!(a.state, ch, sid, 30.0,
                           "open_session on '$(a.worker_id)'")

    conn = ACP.Connection(transport, a.handler; on_frame)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => true),
            "elicitation" => a.kind().elicitation),
        "clientInfo"         => Dict("name"    => "BonitoAgents.WorkerAgent",
                                     "version" => "0.1.0")))

    # Resuming → `session/load` (the agent re-streams history as session/update
    # notifications; `replay_history` captures them). Fresh → `session/new`, no
    # replay. The response carries the session-config blocks either way. Only
    # Claude honours the `_meta.systemPrompt.preset` AGENTS.md append.
    prompt_meta = a.kind === ClaudeCodeAgent ?
        system_prompt_meta(global_agents_md(a.state)) : Dict{String,Any}()
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
end

function stop!(a::WorkerAgent)
    a.client === nothing || close(a.client)
    a.client = nothing
    a.replay = ACP.Message[]
    a.ws[] = nothing
    return a
end
