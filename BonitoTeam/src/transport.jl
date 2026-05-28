# Typed transports for ChatModel. Replaces the old `client_factory :: Any`
# callback hell with concrete structs that hold the parameters needed to
# bring up an ACP session, plus dispatched I/O verbs underneath.
#
# Each concrete transport is an `AgentClientProtocol.Transport`, so the
# generic ACP `Connection` can drive it without knowing whether the
# bytes are going to a local subprocess, a worker WebSocket, or a pair
# of in-memory channels (tests).

const ACP = AgentClientProtocol

"""
    abstract type ChatTransport <: ACP.Transport

The means by which a `ChatModel` reaches its claude-agent-acp session.
Concrete subtypes:

  * `LocalTransport` — spawn `claude-agent-acp` on this server box.
  * `WorkerTransport` — ask a registered worker (over its control WS)
    to spawn `claude-agent-acp` and route ACP frames through the WS the
    worker dials back on `/worker-acp`.
  * `MockTransport` — in-memory loopback used by tests.

Each transport overloads `ACP.send(t, line)`, `ACP.recv(t)`, and
`Base.close(t)` for line-level I/O, and `start_session(t, handler)`
to drive the standard `initialize` + `session/new` (or `session/load`)
sequence and return a live `ACP.Client`. `handler` is an `ACP.Handler`
subtype (see `ChatHandler` in chat.jl) that owns the routing of
agent→client requests and `session/update` notifications.
"""
abstract type ChatTransport <: ACP.Transport end

# ── 1. Local subprocess ────────────────────────────────────────────────────

mutable struct LocalTransport <: ChatTransport
    cwd          :: String
    mcp_servers  :: Vector{ACP.MCPServer}
    agent_type   :: String                # "claude" | "gemini"
    agent_bin    :: String
    agent_args   :: Vector{String}        # CLI args from the agent registry
    agent_env    :: Dict{String,String}
    # Lazily populated by start_session (set to the spawned process'
    # subprocess transport so send/recv/close can delegate).
    inner        :: Ref{Union{ACP.SubprocessTransport,Nothing}}
end

function LocalTransport(cwd::AbstractString;
                        mcp_servers = ACP.MCPServer[],
                        agent_type::AbstractString = "claude",
                        agent_bin   = ACP.find_agent_bin(agent_type),
                        agent_env   = Dict{String,String}())
    spec = ACP.agent_spec(agent_type)
    LocalTransport(String(cwd), collect(ACP.MCPServer, mcp_servers),
                    String(agent_type), String(agent_bin), copy(spec.args),
                    merge(copy(spec.env), agent_env),
                    Ref{Union{ACP.SubprocessTransport,Nothing}}(nothing))
end

ACP.send(t::LocalTransport, line::AbstractString) = ACP.send(t.inner[], line)
ACP.recv(t::LocalTransport)                       = ACP.recv(t.inner[])
Base.close(t::LocalTransport) =
    (t.inner[] === nothing || close(t.inner[]); nothing)

# ── 2. Worker over WebSocket ────────────────────────────────────────────────

mutable struct WorkerTransport <: ChatTransport
    state              :: ServerState
    worker_id          :: String
    worker_path        :: String
    mcp_servers        :: Vector{ACP.MCPServer}
    resume_session_id  :: Union{String,Nothing}
    agent_type         :: String         # "claude" | "gemini"; threaded into open_session frame
    # Set by start_session once the worker dials back the ACP WS.
    ws                 :: Ref{Any}
end

WorkerTransport(state::ServerState, worker_id::AbstractString,
                worker_path::AbstractString;
                mcp_servers = ACP.MCPServer[],
                resume_session_id::Union{String,Nothing} = nothing,
                agent_type::AbstractString = "claude") =
    WorkerTransport(state, String(worker_id), String(worker_path),
                     collect(ACP.MCPServer, mcp_servers),
                     resume_session_id, String(agent_type),
                     Ref{Any}(nothing))

function ACP.send(t::WorkerTransport, line::AbstractString)
    HTTP.WebSockets.send(t.ws[], rstrip(line, '\n'))
    return nothing
end

function ACP.recv(t::WorkerTransport)
    ws = t.ws[]
    HTTP.WebSockets.isclosed(ws) && return ""
    try
        return String(HTTP.WebSockets.receive(ws))
    catch e
        (e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError) && return ""
        rethrow(e)
    end
end

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

# ── 3. Mock loopback (tests) ────────────────────────────────────────────────
# A test sets up `incoming` (frames the agent is "sending" to us) and
# `outgoing` (frames we send back), plus an `on_setup` callback that the
# test uses to install its own JSON-RPC responder. start_session calls
# on_setup with the (outgoing, incoming) pair so the responder can read
# from outgoing and write to incoming.

mutable struct MockTransport <: ChatTransport
    # Mutable + Refs so `start_session` can swap in fresh channels on a
    # re-bring-up (after `restart_chat_session!` calls `close` on the
    # old client, the channels are closed and can't be put!/take!'d).
    incoming :: Channel{String}    # we read from this
    outgoing :: Channel{String}    # we write to this
    on_setup :: Function           # (outgoing, incoming) -> Nothing — install responder
    cwd      :: String             # cosmetic; passed to ACP.Client at the end
    capacity :: Int
end

MockTransport(on_setup::Function; cwd::AbstractString = "/tmp",
              capacity::Int = 64) =
    MockTransport(Channel{String}(capacity), Channel{String}(capacity),
                   on_setup, String(cwd), capacity)

ACP.send(t::MockTransport, line::AbstractString) = (put!(t.outgoing, String(line)); nothing)
ACP.recv(t::MockTransport)                       = take!(t.incoming)
# Channel.close is idempotent in Base, so no wrapper is needed.
Base.close(t::MockTransport) = (close(t.outgoing); close(t.incoming); nothing)

# The path the *agent* sees as its working directory. The chat layer uses
# this when constructing the ACP `FSRequestHandler` so server-side fs RPCs
# resolve paths against the right root (server cwd locally, worker path
# for remote sessions). Mock sessions report the cosmetic test cwd.
agent_cwd(t::LocalTransport)  = t.cwd
agent_cwd(t::WorkerTransport) = t.worker_path
agent_cwd(t::MockTransport)   = t.cwd

# ── ACP session bring-up, dispatched per transport ─────────────────────────

# Standard MCP-list serialisation used by both Local and Worker bring-up.
mcp_list_payload(mcp_servers) =
    [Dict("name"    => s.name,
          "command" => s.command,
          "args"    => s.args,
          "env"     => [Dict("name" => k, "value" => v) for (k,v) in s.env])
     for s in mcp_servers]

# 1. Local: spawn the configured agent (claude-agent-acp or gemini), then
#    drive initialize + session/new. Agent-specific env vars come via
#    `t.agent_env` (populated from the spec at LocalTransport-constructor time).
function start_session(t::LocalTransport, handler::ACP.Handler)
    isfile(t.agent_bin) || error("$(t.agent_type) agent binary not found at: $(t.agent_bin)")
    env = merge(Dict(k => v for (k,v) in ENV), t.agent_env)
    proc = open(Cmd(`$(t.agent_bin) $(t.agent_args)`; env, dir = t.cwd), "r+")
    t.inner[] = ACP.SubprocessTransport(proc)

    conn = ACP.Connection(t, handler)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict("fs" => Dict(
            "readTextFile" => true, "writeTextFile" => true)),
        "clientInfo"         => Dict("name"    => "BonitoTeam.LocalTransport",
                                      "version" => "0.1.0")))
    result = ACP.send_request(conn, "session/new",
                              Dict("cwd" => t.cwd,
                                   "mcpServers" => mcp_list_payload(t.mcp_servers)))
    return ACP.Client(conn, result["sessionId"], t.cwd)
end

# 2. Worker: ask the worker to spawn claude-agent-acp and dial back, then
#    drive initialize + session/new (or session/load when resuming).
function start_session(t::WorkerTransport, handler::ACP.Handler)
    haskey(t.state.worker_control_ws, t.worker_id) ||
        error("Worker '$(t.worker_id)' is not connected")

    sid, ch = register_rpc!(t.state)
    mcp_list = mcp_list_payload(t.mcp_servers)

    # Find the project this session belongs to (cosmetic — used in the
    # worker-side log line).
    project_id = ""
    for p in values(t.state.projects[])
        p.worker_id == t.worker_id && p.worker_path == t.worker_path &&
            (project_id = p.id; break)
    end

    send_command(t.state, t.worker_id, Dict(
        "type"       => "open_session",
        "sid"        => sid,
        "project_id" => project_id,
        "agent_type" => t.agent_type,
        "cwd"        => t.worker_path,
        "env"        => Dict{String,String}(),
        "mcpServers" => mcp_list,
    ))

    # Bounded wait for the worker's /worker-acp upgrade. If the worker
    # pre-empted with an `open_session_failed` control frame, the channel
    # carries `{"error" => reason}` instead of the WS — raise immediately so
    # the UI surfaces a clear error in milliseconds instead of the 30s
    # timeout path.
    result = take_pending!(t.state, ch, sid, 30.0,
                          "open_session on '$(t.worker_id)'")
    if result isa AbstractDict && haskey(result, "error")
        error("open_session on '$(t.worker_id)' failed: $(result["error"])")
    end
    t.ws[] = result

    conn = ACP.Connection(t, handler)
    ACP.send_request(conn, "initialize", Dict(
        "protocolVersion"    => 1,
        "clientCapabilities" => Dict("fs" => Dict(
            "readTextFile" => true, "writeTextFile" => true)),
        "clientInfo"         => Dict("name"    => "BonitoTeam.WorkerTransport",
                                      "version" => "0.1.0")))

    session_id = if t.resume_session_id !== nothing
        @info "ACP: resuming session" cwd=t.worker_path resume=t.resume_session_id
        ACP.send_request(conn, "session/load", Dict(
            "sessionId"  => t.resume_session_id,
            "cwd"        => t.worker_path,
            "mcpServers" => mcp_list,
        ))
        t.resume_session_id
    else
        result = ACP.send_request(conn, "session/new",
                                  Dict("cwd" => t.worker_path, "mcpServers" => mcp_list))
        result["sessionId"]
    end

    return ACP.Client(conn, session_id, t.worker_path)
end

# 3. Mock: (re-)open the loopback channels, hand them to the test
#    responder, then drive the standard initialize + session/new sequence.
#    Channels are recreated each call because `restart_chat_session!`
#    closes the old transport (killing the old responder) before bringing
#    up a new one.
function start_session(t::MockTransport, handler::ACP.Handler)
    if !isopen(t.outgoing); t.outgoing = Channel{String}(t.capacity); end
    if !isopen(t.incoming); t.incoming = Channel{String}(t.capacity); end
    t.on_setup(t.outgoing, t.incoming)
    conn = ACP.Connection(t, handler)
    ACP.send_request(conn, "initialize", Dict("protocolVersion" => 1))
    result = ACP.send_request(conn, "session/new",
                              Dict("cwd" => t.cwd, "mcpServers" => []))
    return ACP.Client(conn, result["sessionId"], t.cwd)
end
