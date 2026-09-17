# ── MCP server process context ──────────────────────────────────────────────
# The stdio MCP server is a process singleton (one server ⇒ one of each of
# these), so its WHOLE mutable runtime lives in one value instead of a scatter of
# module-level Refs/Dicts/Locks:
#   • the eval-session manager (subprocess-per-env_path),
#   • the /mcp-ws control channel (per-tool interrupt + live stdout stream),
#   • the in-flight JSON-RPC bookkeeping (cancel routing + stdout write lock).
# Eagerly built — every part is a cheap empty container.
#
# Deliberately NOT folded in: RemoteProxy.BRIDGE lives in the eval WORKER, a
# different process; and TOOLS is a load-time tool registry, not runtime state.
mutable struct MCPServer
    manager::SessionManager                     # eval sessions, keyed by env_path
    control::ControlChannel                     # /mcp-ws dial-back: interrupt + stdout stream
    inflight::Dict{Any,Union{String,Nothing}}   # in-flight JSON-RPC id → env_path (cancel routing)
    # Evals this chat has running on OTHER workers (tools/eval.jl remote branch):
    # (worker, env_path) while the relayed call is in flight, so a cancel can
    # reach them through the server (`interrupt_remote_inflight!`).
    remote_inflight::Set{Tuple{String,Union{String,Nothing}}}
    inflight_lock::ReentrantLock                # guards `inflight` and `remote_inflight`
    out_lock::ReentrantLock                     # serialises one-line-per-frame stdout writes
end

const SERVER = MCPServer(
    SessionManager(),
    ControlChannel(nothing, false, nothing),
    Dict{Any,Union{String,Nothing}}(),
    Set{Tuple{String,Union{String,Nothing}}}(),
    ReentrantLock(),
    ReentrantLock(),
)

# The eval-session manager. An accessor, not a bare field read: it's the one part
# hit from several call sites (tools/eval.jl, server.jl) and `manager()` reads
# better there than `SERVER.manager`.
manager() = SERVER.manager
