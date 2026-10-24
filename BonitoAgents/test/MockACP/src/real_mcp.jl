# A deterministic agent client for launch/transport tests. Unlike TestKit's
# in-process tool simulator, this uses ONLY the MCP command/argv/env supplied
# in ACP session/new or session/load and speaks real MCP over subprocess stdio.
const MCP_CONFIG = Ref{Any}(nothing)
const MCP_PROCESS = Ref{Any}(nothing)
const MCP_CALL_ID = Ref(0)

function set_mcp_config!(params)
    config = findfirst(s -> get(s, "name", "") == "btworker", get(params, "mcpServers", []))
    config === nothing && return
    MCP_CONFIG[] = params["mcpServers"][config]
end

function real_mcp_request(method, params)
    proc = MCP_PROCESS[]
    MCP_CALL_ID[] += 1
    id = MCP_CALL_ID[]
    println(proc, JSON.json(Dict("jsonrpc" => "2.0", "id" => id,
                                "method" => method, "params" => params)))
    flush(proc)
    while true
        eof(proc) && error("MCP process exited before replying")
        msg = JSON.parse(readline(proc))
        get(msg, "id", nothing) == id || continue
        haskey(msg, "error") && error(JSON.json(msg["error"]))
        return msg["result"]
    end
end

function real_mcp_call(tool, args; meta = nothing)
    if MCP_PROCESS[] === nothing
        cfg = MCP_CONFIG[]
        cfg === nothing && error("ACP did not supply btworker MCP configuration")
        # Reproduce agents that filter inherited env. Explicit ACP values are
        # authoritative; no test helper supplies missing launch coordinates.
        env = Dict(k => v for (k, v) in ENV if !startswith(k, "BONITOAGENTS_"))
        merge!(env, Dict(String(e["name"]) => String(e["value"]) for e in cfg["env"]))
        cmd = Cmd(Cmd(String[cfg["command"]; cfg["args"]]); env)
        MCP_PROCESS[] = open(cmd, "r+")
        real_mcp_request("initialize", Dict("protocolVersion" => "2025-06-18",
            "capabilities" => Dict(), "clientInfo" => Dict("name" => "launch-test", "version" => "1")))
        println(MCP_PROCESS[], JSON.json(Dict("jsonrpc" => "2.0", "method" => "notifications/initialized")))
        flush(MCP_PROCESS[])
    end
    params = Dict{String,Any}("name" => tool, "arguments" => args)
    meta === nothing || (params["_meta"] = meta)
    return real_mcp_request("tools/call", params)
end

function emit_real_mcp_call(ev)
    tool = String(ev["tool"])
    tid = String(get(ev, "id", "real-mcp"))
    # Claude Code names the tool call on every `tools/call` (its tool_use id, the
    # same id claude-agent-acp gives the ACP tool call); `anonymous = true` plays
    # an agent that sends nothing of the kind.
    anonymous = get(ev, "anonymous", false) === true
    args = Dict(k => v for (k, v) in ev if k ∉ ("type", "tool", "id", "anonymous"))
    meta = Dict("claudeCode" => Dict("toolName" => "mcp__btworker__" * tool))
    upd("tool_call", Dict("toolCallId" => tid, "kind" => "other",
        "title" => "mcp__btworker__" * tool, "status" => "pending",
        "rawInput" => args, "content" => Any[], "_meta" => meta))
    result = try
        real_mcp_call(tool, args; meta = anonymous ? nothing :
                                        Dict("claudecode/toolUseId" => tid))
    catch e
        Dict("isError" => true, "content" => [Dict("type" => "text",
            "text" => "MCP launch/call failed: " * sprint(showerror, e))])
    end
    upd("tool_call_update", Dict("toolCallId" => tid,
        "status" => get(result, "isError", false) ? "failed" : "completed",
        "content" => [Dict("type" => "content", "content" => c) for c in result["content"]],
        "_meta" => meta))
end
