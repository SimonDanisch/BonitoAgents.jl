# The tools the BonitoAgents server's apps add (BonitoAgents `apps.jl`): the
# To-do app's `todo_done`, say, which every chat's agent can call.
#
# They are not in `TOOLS`. The server owns them and knows which chat may see
# which (some only reach the app's own chat), so `tools/list` asks it over this
# process's control channel, and a call to a name that isn't ours is forwarded
# there and runs in the server. A standalone BonitoMCP, with no server behind
# it, has none.

# Starting a chat for a to-do brings a session up on a worker: seconds, rarely more.
const APP_CALL_TIMEOUT_S = 120.0

"""
    app_tool_specs() -> Vector{Dict}

The apps' tools for this chat, as `tools/list` describes them. Empty without a
server, and when the server cannot be asked: the agent still gets our own
tools, and the reason is in the log.
"""
function app_tool_specs()
    SERVER.control.task === nothing && return Dict{String,Any}[]
    specs = try
        call_server("app_tools"; timeout = 15.0)
    catch e
        e isa InterruptException && rethrow()
        log_info("app tools unavailable: $(sprint(showerror, e))")
        return Dict{String,Any}[]
    end
    return Dict{String,Any}[Dict{String,Any}(s) for s in specs]
end

"""
    call_tool(name, args) -> Dict | nothing

Run the tool `name` with `args` and return its MCP result: one of ours, or an
app's, run by the server. `nothing` when neither has a tool of that name for
this chat. A server that cannot be asked, or fails, comes back as a tool error
with its message.
"""
function call_tool(name::AbstractString, args::AbstractDict)
    tools = available_tools()
    idx = findfirst(t -> t.name == name, tools)
    idx === nothing || return tools[idx].handler(args)
    SERVER.control.task === nothing && return nothing
    reply = try
        call_server("app_call"; timeout = APP_CALL_TIMEOUT_S, tool = String(name),
                    args = Dict{String,Any}(String(k) => v for (k, v) in args))
    catch e
        # No channel, a timeout, or the server's own error: each is something
        # the agent should read as it is (see `call_server`).
        e isa ErrorException || rethrow()
        return tool_error(e.msg)
    end
    get(reply, "found", false) === true || return nothing
    return Dict{String,Any}(reply["result"])
end
