# An EVAL HOST: this same MCP server process, run without stdio, on a worker
# OTHER than the one a chat's agent lives on. "Run this on the MacBook" from a
# chat whose agent sits on the desktop: the chat's own MCP asks the BonitoAgents
# server (`call_server("remote_eval", …)`, tools/eval.jl), the server spawns one
# of these on the MacBook's worker for that chat, and relays the eval to it over
# /mcp-ws — the control channel every MCP process dials, with a handshake that
# names the worker this host runs on and the chat it serves.
#
# Everything below the wire is shared with the stdio server: the same session
# manager (one Malt worker per env_path), the same tool handlers, the same live
# stdout streaming (`eval_stream_chunk` frames the server routes to the chat's
# eval card), the same eval-ws live-render bridge (the host's eval workers dial
# the server for the chat's project, so a plot returned on the MacBook renders
# into the chat on the desktop).
#
# Wire, on top of ctrl_ws.jl's:
#   handshake:      "secret project_id eval_host worker_id"
#   server → host:  {"op": "eval"|"continue"|"interrupt"|"restart"|"sessions",
#                    "request_id", "args": {…the tool's own arguments…}}
#                   {"op": "shutdown", "request_id"}
#   host → server:  {"type": "eval_host_result", "request_id", "result": <tool result>}
#
# Lifetime: the process exits on `shutdown` (the chat's session ended, or the
# user switched remote Julia off), or when the server has been unreachable for
# `HOST_ORPHAN_S` — a host nobody can reach serves nobody. Both paths shut the
# session manager down, which kills the eval workers and what they spawned.

const HOST_ORPHAN_S   = 600.0
const HOST_ENV_WORKER = "BONITOAGENTS_EVAL_HOST_WORKER"
const HOST_OPS        = ("eval", "continue", "interrupt", "restart", "sessions", "shutdown")

# Which worker this process runs on, when it is an eval host ("" otherwise).
host_worker_id() = get(ENV, HOST_ENV_WORKER, "")

"""
    run_eval_host()

Serve evals for one chat from THIS worker until told to shut down. Reads the same
`BONITOAGENTS_*` environment the stdio server uses, plus `$(HOST_ENV_WORKER)`
(the id of the worker this process runs on, set by the BonitoWorker daemon that
spawned it). Blocks; returns after the shutdown.
"""
function run_eval_host()
    server_url = get(ENV, "BONITOAGENTS_SERVER_URL", "")
    secret     = get(ENV, "BONITOAGENTS_SECRET", "")
    project_id = get(ENV, "BONITOAGENTS_PROJECT_ID", "")
    worker_id  = host_worker_id()
    for (k, v) in (("BONITOAGENTS_SERVER_URL", server_url), ("BONITOAGENTS_SECRET", secret),
                   ("BONITOAGENTS_PROJECT_ID", project_id), (HOST_ENV_WORKER, worker_id))
        isempty(v) && error("run_eval_host: $(k) is not set")
    end
    SERVER.control.task === nothing || error("run_eval_host: this process already dials a control channel")
    wsurl = replace(rstrip(server_url, '/'), r"^http" => "ws") * "/mcp-ws"
    log_info("eval host for chat $(project_id) on worker $(worker_id) → $(wsurl)")
    SERVER.control.task = Base.errormonitor(@async ctrl_dial_loop(
        wsurl, "$secret $project_id eval_host $worker_id"))
    watch_host_orphaned()
    shutdown!(manager())
    log_info("eval host exiting")
    return nothing
end

# Block until `shutdown` flips `SERVER.control.stop`, or the server has been
# gone (no live control socket) for HOST_ORPHAN_S. The clock also runs before
# the FIRST connect: a host whose server never answers must not live forever.
function watch_host_orphaned()
    gone_since = time()
    while !SERVER.control.stop
        sleep(1.0)
        if SERVER.control.ws === nothing
            if time() - gone_since > HOST_ORPHAN_S
                log_info("no BonitoAgents server for $(HOST_ORPHAN_S)s; shutting the eval host down")
                SERVER.control.stop = true
            end
        else
            gone_since = time()
        end
    end
    return nothing
end

host_reply(ws, rid, fields::AbstractDict) =
    WebSockets.send(ws, JSON.json(merge(
        Dict{String,Any}("type" => "eval_host_result", "request_id" => rid), fields)))

# One relayed tool call from the server. The eval-family handlers are run
# OFF-LOOP: an `eval`'s soft-timeout wait must not block the read loop that
# carries the `interrupt_eval` meant for it. A handler that throws is answered
# as a tool error — the caller on the other side is waiting on a channel and a
# dropped reply would hang it until its timeout.
function handle_host_op!(ws, msg::AbstractDict)
    op  = String(get(msg, "op", ""))
    rid = get(msg, "request_id", nothing)
    if op == "shutdown"
        log_info("eval host: shutdown requested")
        host_reply(ws, rid, Dict{String,Any}("ok" => true))
        SERVER.control.stop = true
        try
            close(ws)          # ends the dial loop's receive; `stop` keeps it from redialing
        catch e
            e isa InterruptException && rethrow()
            log_info("eval host: closing the control socket failed: $(sprint(showerror, e))")
        end
        return nothing
    end
    raw = get(msg, "args", Dict{String,Any}())
    args = raw isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in raw) : Dict{String,Any}()
    # This IS the worker the eval runs on: a `worker` argument that slipped
    # through would send the call back through the server for ever.
    delete!(args, "worker")
    handler = op == "eval"      ? julia_eval_handler :
              op == "continue"  ? julia_continue_handler :
              op == "interrupt" ? julia_interrupt_handler :
              op == "restart"   ? julia_restart_handler :
              op == "sessions"  ? julia_list_sessions_handler :
              nothing
    if handler === nothing
        host_reply(ws, rid, Dict{String,Any}("error" => "unknown eval host op '$(op)'"))
        return nothing
    end
    Base.errormonitor(@async begin
        result = try
            handler(args)
        catch e
            e isa InterruptException && rethrow()
            Dict{String,Any}(
                "content" => [Dict("type" => "text",
                                   "text" => "tool handler threw:\n" * sprint(showerror, e, catch_backtrace()))],
                "isError" => true)
        end
        try
            host_reply(ws, rid, Dict{String,Any}("result" => result))
        catch e
            e isa InterruptException && rethrow()
            log_info("eval host: reply for '$(op)' failed to send: $(sprint(showerror, e))")
        end
    end)
    return nothing
end
