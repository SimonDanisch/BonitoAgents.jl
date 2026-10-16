# ── MCP server process context ──────────────────────────────────────────────
# The stdio MCP server is a process singleton (one server ⇒ one of each of
# these), so its WHOLE mutable runtime lives in one value instead of a scatter of
# module-level Refs/Dicts/Locks:
#   • the eval-session manager (subprocess-per-env_path),
#   • the runs: every eval this chat started, here or on other workers (runs.jl),
#   • the control channel to the server (per-tool interrupt + live stdout stream),
#   • the in-flight JSON-RPC bookkeeping (cancel routing + stdout write lock).
# Eagerly built — every part is a cheap empty container.
#
# Deliberately NOT folded in: RemoteProxy.BRIDGE lives in the eval WORKER, a
# different process; and TOOLS is a load-time tool registry, not runtime state.
mutable struct MCPServer
    manager::SessionManager                     # eval sessions, keyed by env_path
    runs::RunRegistry                           # evals as runs (`r4`), local and on other workers
    control::ControlChannel                     # to the server, via the worker relay: interrupt + stdout stream
    inflight::Dict{Any,Union{String,Nothing}}   # in-flight JSON-RPC id → env_path (cancel routing)
    # FOREGROUND runs this chat has going on OTHER workers while their relayed
    # call is in flight, as (worker, run id), so a cancel can stop them through
    # the server (`interrupt_remote_inflight!`). Background runs are never here:
    # a cancel leaves them alone.
    remote_inflight::Set{Tuple{String,String}}
    inflight_lock::ReentrantLock                # guards `inflight` and `remote_inflight`
    out_lock::ReentrantLock                     # serialises one-line-per-frame stdout writes
end

const SERVER = MCPServer(
    SessionManager(),
    RunRegistry(),
    ControlChannel(),
    Dict{Any,Union{String,Nothing}}(),
    Set{Tuple{String,String}}(),
    ReentrantLock(),
    ReentrantLock(),
)

# The eval-session manager. An accessor, not a bare field read: it's the one part
# hit from several call sites (tools/eval.jl, server.jl) and `manager()` reads
# better there than `SERVER.manager`.
manager() = SERVER.manager
