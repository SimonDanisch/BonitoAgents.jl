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

# ── bt_load_app: an app package into the running server ─────────────────────

# The server first waits for a person to approve the load on the chat's card (10
# minutes at most), then loads the package in its own process, which precompiles
# it and whatever it adds to the server's environment: minutes on a cold depot.
const APP_LOAD_TIMEOUT_S = 1800.0

function load_app_handler(args::AbstractDict)
    path = String(strip(String(get(args, "path", ""))))
    isempty(path) && return tool_error("`path` (the app package's folder) is required")
    reply = try
        call_server("app_load"; timeout = APP_LOAD_TIMEOUT_S, path)
    catch e
        # No channel, a timeout, or the server's own error (see `call_server`).
        e isa ErrorException || rethrow()
        return tool_error(e.msg)
    end
    lines = String[]
    for a in reply["apps"]
        tools = a["tools"]
        push!(lines, "Started the app \"$(a["title"])\" ($(a["id"])). Its tile is on the dashboard" *
                     (isempty(tools) ? "." : ", and chats started from now on have its tools: $(join(tools, ", "))."))
    end
    reply["added"] === true &&
        push!(lines, "Added the package to the server's Julia environment, $(reply["environment"]).")
    reply["marked"] === true ||
        push!(lines, "Its Project.toml has no `[bonitoagents] plugin = true`, so the server won't load it " *
                     "again after a restart. Add those two lines to keep the app.")
    return tool_text(join(lines, "\n"))
end

register!(
    "bt_load_app",
    """
    Load a BonitoAgents app package into the running BonitoAgents server, without
    a restart. The user approves every load: the chat shows them a card naming
    the package, and the call waits for their answer (10 minutes at most). Call
    it when the user asked for the app to be loaded. Once loaded, its tile appears
    on the dashboard, and chats started from then on get its tools; its own chat
    opens from the tile. `path` is the package's
    folder (absolute, or relative to the project folder), which the server reads
    on its own machine: this chat's worker has to run there.
    The package registers its app type in `__init__`:
        function __init__()
            BonitoAgents.register_app!(MyApp)
        end
    It is added to the server's Julia environment as a development checkout if
    it isn't in it yet. With `[bonitoagents] plugin = true` in its Project.toml
    the server loads it again whenever it starts. A package loads once per
    server run, so trying changed code needs a server restart. Only an admin's
    chat may load apps.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict("type" => "string", "description" => "The app package's folder (its Project.toml is in it)"),
        ),
        "required" => ["path"],
    ),
    load_app_handler,
)
