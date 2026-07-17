# JSON-RPC 2.0 over stdio. Each line on stdin is one request / notification;
# each response is one line on stdout. stderr is free for logging.

# Structured logger (stderr) — never write non-MCP content to stdout
log_info(msg) = println(stderr, "[$SERVER_NAME] ", msg)

# How long to give `Malt.interrupt` to land before the nuclear fallback (kill the
# worker). Generous because user code in a `try/catch` may swallow the first
# InterruptException for a bit; the existing `interrupt!` tool uses the same 30s.
const CANCEL_KILL_GRACE = 30.0

const EVAL_TOOL_NAMES = ("bt_julia_eval", "bt_julia_continue", "bt_julia_interrupt")

# `SERVER.inflight` maps an in-flight `tools/call` requestId → the env_path it's
# evaluating in, so `notifications/cancelled` can target ONLY the session the
# cancelled request owns, instead of interrupting every in-flight eval across all
# sessions (M9 — a stop in chat A previously SIGINT'd chat B's computation).
# Populated/cleared in `dispatch!` around the eval-family handlers. `nothing`
# env_path = temp. (Lives on the SERVER context — see context.jl.)
function note_inflight_request!(id, env_path::Union{String,Nothing})
    id === nothing && return nothing
    @lock SERVER.inflight_lock (SERVER.inflight[id] = env_path)
    return nothing
end

function clear_inflight_request!(id)
    id === nothing && return nothing
    @lock SERVER.inflight_lock (haskey(SERVER.inflight, id) && delete!(SERVER.inflight, id))
    return nothing
end

# `tools/call`s are dispatched on their own tasks (so a long eval can't block the
# read loop from a `notifications/cancelled`), so multiple tasks may write a
# response concurrently — `SERVER.out_lock` keeps one line per frame atomic.
function send!(out::IO, payload::AbstractDict)
    lock(SERVER.out_lock) do
        println(out, JSON.json(payload))
        flush(out)
    end
    return nothing
end

function send_response!(out, id, result)
    send!(out, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
end

function send_error!(out, id, code::Integer, message::AbstractString)
    send!(out, Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Dict("code" => code, "message" => message),
    ))
end

# Dispatch one parsed JSON-RPC request. id may be missing (notification).
function dispatch!(out, req::AbstractDict)
    method = get(req, "method", nothing)
    id = get(req, "id", nothing)
    params = get(req, "params", Dict{String,Any}())

    if method == "initialize"
        send_response!(out, id, Dict(
            "protocolVersion" => PROTOCOL_VERSION,
            "capabilities" => Dict("tools" => Dict("listChanged" => false)),
            "serverInfo" => Dict("name" => SERVER_NAME, "version" => SERVER_VERSION),
        ))
    elseif method == "notifications/initialized"
        # Notification, no response
    elseif method == "tools/list"
        tools = [Dict(
            "name" => t.name,
            "description" => t.description,
            "inputSchema" => t.input_schema,
        ) for t in TOOLS]
        send_response!(out, id, Dict("tools" => tools))
    elseif method == "tools/call"
        tool_name = get(params, "name", "")
        args = get(params, "arguments", Dict{String,Any}())
        idx = findfirst(t -> t.name == tool_name, TOOLS)
        if idx === nothing
            send_error!(out, id, -32602, "Unknown tool: $tool_name")
        else
            # Record requestId → env_path for the eval family so a later
            # `notifications/cancelled` can target just this session (M9).
            track = tool_name in EVAL_TOOL_NAMES
            track && note_inflight_request!(id, get(args, "env_path", nothing))
            try
                result = TOOLS[idx].handler(args)
                send_response!(out, id, result)
            catch e
                bt = sprint(showerror, e, catch_backtrace())
                # Tool execution errors come back as a successful response with
                # isError=true so the agent can react to it (per MCP spec).
                send_response!(out, id, Dict(
                    "content" => [Dict("type" => "text",
                                       "text" => "tool handler threw:\n$bt")],
                    "isError" => true,
                ))
            finally
                track && clear_inflight_request!(id)
            end
        end
    elseif method === nothing
        # Malformed; ignore
    else
        if id !== nothing
            send_error!(out, id, -32601, "Method not found: $method")
        end
    end
    return nothing
end

# MCP `notifications/cancelled`: claude-agent-acp asking us to abort an in-flight
# request — how an ACP `session/cancel` reaches a long-running tool.
#
# An arbitrary user eval (`sleep`, `while true`, a blocking fetch) has NO
# cooperative stop — it checks no flag — so the only lever to actually STOP it is
# `Malt.interrupt` (SIGINT). It's unreliable and can crash the worker, so we don't
# use it for OUR OWN loops (those stop via messages); but for stopping user code
# it's the only tool, used deliberately here. A worker-kill fallback
# (`finalize_cancelled_eval!`) covers code that swallows InterruptException so a
# cancelled eval can never orphan-run forever.
#
# We don't take a session's `lock` (the in-flight poll may hold it); `Malt.interrupt`
# is a lock-free signal and the in-flight `await_or_yield` clears `in_flight` when
# the task dies. `requestId` is logged to confirm the agent forwards cancellation.
function handle_cancelled!(req::AbstractDict)
    params = get(req, "params", Dict{String,Any}())
    rid = get(params, "requestId", get(params, "id", nothing))
    # Target ONLY the session the cancelled request owns, when we can map it
    # (M9). If the requestId isn't tracked (unknown id, or a cancel that arrived
    # after the handler cleared it), fall back to interrupting all in-flight
    # evals — never silently fail to stop a runaway computation.
    target_env = rid === nothing ? :unknown :
        @lock SERVER.inflight_lock get(SERVER.inflight, rid, :unknown)
    n = target_env === :unknown ?
        interrupt_in_flight!(nothing) :
        interrupt_in_flight!(target_env; scope_temp = target_env === nothing)
    log_info("notifications/cancelled (requestId=$rid) → interrupted $n in-flight eval(s)")
    return nothing
end

# SIGINT every in-flight eval matching `env_path` and arm the worker-kill
# fallback for each (see `finalize_cancelled_eval!`). Shared by the MCP
# `notifications/cancelled` path and the BonitoAgents control channel's
# `interrupt_eval` op (ctrl_ws.jl). Returns the number of evals interrupted.
#
# `env_path === nothing` means "every in-flight eval" — this process serves
# ONE chat, so that's the right scope when the caller can't name the env.
# A tracked TEMP session (env_path recorded as `nothing`) is addressed with
# `scope_temp = true` instead.
#
# `JuliaSession` isn't defined yet at this file's include time (session.jl
# loads after server.jl), so stay untyped here — runtime values are sessions.
function interrupt_in_flight!(env_path::Union{String,Nothing}; scope_temp::Bool = false)
    m = manager()
    targets = Any[]
    lock(m.lock) do
        for s in values(m.sessions)
            s.in_flight === nothing && continue
            if env_path === nothing && !scope_temp
                push!(targets, s)
            else
                _key(s.env_path) == _key(env_path) && push!(targets, s)
            end
        end
    end
    for s in targets
        # Capture the task being cancelled NOW, before any grace sleep — the
        # finalizer must only ever escalate against THIS eval, never a fresh one
        # that legitimately started during the grace window (M3).
        f = s.in_flight
        try
            is_alive(s) && Malt.interrupt(s.worker)
        catch e
            log_info("interrupt: Malt.interrupt failed: $(sprint(showerror, e))")
        end
        f === nothing || @async finalize_cancelled_eval!(s, f)
    end
    return length(targets)
end

# After the grace: if the interrupt landed, the eval task is done — clear
# `in_flight` (an in-flight `await_or_yield` normally does this, but a cancel can
# abandon the eval with no poll active, so do it here too) so the session stays
# reusable. If the eval is STILL running, it swallowed the interrupt — take the
# worker down so it can't orphan-run forever (that session's loaded state is lost;
# the reliable last step).
# `f` is the SPECIFIC task that was in flight when the cancel arrived (captured
# by `handle_cancelled!` before the grace). We only act on `f` — never on
# whatever `s.in_flight` happens to be after the sleep, which may be an innocent
# NEW eval that started while we waited (the old code SIGKILLed that one; M3).
function finalize_cancelled_eval!(s, f)   # s::JuliaSession, f::Task (typed at call time)
    sleep(CANCEL_KILL_GRACE)
    if istaskdone(f)
        # The cancel landed: clear in_flight iff it's still our task (an
        # await_or_yield may have already cleared it; a new eval may already own
        # the slot — leave that one alone).
        @lock s.lock (s.in_flight === f && (s.in_flight = nothing))
    elseif s.in_flight === f && is_alive(s)
        # Our eval is STILL running after the grace → it swallowed the interrupt.
        # Only escalate if it's still the in-flight one; otherwise a newer eval
        # owns the worker and killing it would destroy innocent work.
        log_info("eval ignored interrupt after $(CANCEL_KILL_GRACE)s → killing worker (session lost)")
        try
            kill_session!(s)
        catch e
            log_info("kill_session! failed: $(sprint(showerror, e))")
        end
    end
    return
end

"""
    run_stdio(; in=stdin, out=stdout)

Run the stdio MCP loop. Blocks until stdin closes.
"""
function run_stdio(; in::IO = stdin, out::IO = stdout)
    log_info("$(SERVER_NAME) v$(SERVER_VERSION) listening on stdio (protocol $(PROTOCOL_VERSION))")
    log_info("Registered $(length(TOOLS)) tool(s): " *
             join((t.name for t in TOOLS), ", "))
    # BonitoAgents-hosted runs get a control dial-back so the chat UI can
    # interrupt in-flight evals per tool (no-op standalone; see ctrl_ws.jl).
    start_ctrl_dialback!()
    for line in eachline(in)
        s = strip(line)
        isempty(s) && continue
        local req
        try
            req = JSON.parse(String(s))
        catch e
            log_info("parse error: $(string(e)) ; line: $s")
            send_error!(out, nothing, -32700, "Parse error")
            continue
        end
        method = get(req, "method", nothing)
        if method == "notifications/cancelled"
            # Process inline + immediately: it must run WHILE a `tools/call` poll
            # is in flight, which is exactly why those are dispatched off-loop.
            try
                handle_cancelled!(req)
            catch e
                log_info("cancelled handler error: $(sprint(showerror, e))")
            end
        elseif method == "tools/call"
            # Off-loop so a long-running eval can't block the read loop from
            # reaching the next line (e.g. the cancel that should yield it).
            Base.errormonitor(@async try
                dispatch!(out, req)
            catch e
                bt = sprint(showerror, e, catch_backtrace())
                log_info("dispatch error: $bt")
                id = get(req, "id", nothing)
                id !== nothing && send_error!(out, id, -32603, "Internal error: $(string(e))")
            end)
        else
            try
                dispatch!(out, req)
            catch e
                bt = sprint(showerror, e, catch_backtrace())
                log_info("dispatch error: $bt")
                id = get(req, "id", nothing)
                id !== nothing && send_error!(out, id, -32603, "Internal error: $(string(e))")
            end
        end
    end
    log_info("stdin closed; exiting")
    return nothing
end
