# BonitoAgents apps: permanent parts of the server, each with a chat of its own.
#
# An app lives as long as the server (`ServerState.apps`, started by
# `start_apps!` from the `apps` the server was given), so its state and its
# tools are there whether or not anyone has its chat open. It has three ways in:
#
# - its chat's pane. The app's chat is an ordinary chat (a project on a worker,
#   with an agent), marked with `ProjectInfo.app`. Opening it renders the app's
#   `chat_pane` method instead of the ordinary layout: any DOM, which can place
#   the chat's own widgets (header, transcript, composer) wherever it likes.
# - tools for agents. `app_tools` are added to the MCP of every chat (or only of
#   the app's own chat): BonitoMCP lists them next to its own and forwards each
#   call over the chat's control channel, where `call_tool` runs it here, in the
#   server, with the calling chat known.
# - a briefing for its chat's agent (`app_briefing`), in the system prompt.
#
# Besides its own chat, an app can start more chats of its own, each with a key
# it picks (`start_chat!(...; app, key)`): one per project, say. Their pane and
# briefing are the app's too, and tell them apart by the key (`chat_key`).
#
# An app is written against the public names below and nothing else, so it can
# live in a package of its own (`apps/BonitoTodo/` is built that way).

# ── what an app implements ──────────────────────────────────────────────────

"""
    AppContext

What the server hands an app it starts, as `MyApp(ctx)`: the server (`ctx.server`,
for the platform functions like [`start_chat!`](@ref)) and the directory the app
keeps its files in (`ctx.dir`, `<state_dir>/apps/<app_id>`, created on first
write).
"""
struct AppContext
    server::ServerState
    dir::String
end

"""
    app_id(::Type{<:AgentApp}) -> String

The app's name for the machine: a short lowercase word, unique on the server.
It marks the app's chat (`ProjectInfo.app`), names its directory and should
prefix its tools' names. The one method an app must define, on its TYPE: the
server needs it before the app exists, to find its directory.
"""
function app_id end
app_id(app::AgentApp) = app_id(typeof(app))

"What the app is called in the UI. Defaults to its id."
app_title(app::AgentApp) = app_id(app)

"A few lines about the app: its tile's details on the dashboard, and the setup dialog."
app_description(::AgentApp) = ""

"""
    app_icon(app) -> String | nothing

The app's logo: the path of a square picture file that ships with the app (an
SVG or a PNG, e.g. `joinpath(@__DIR__, "logo.svg")`), shown on its dashboard
tile and as its chat's icon. `nothing` (the default) gives a tile with the first
letter of its title.
"""
app_icon(::AgentApp) = nothing

"The tools the app adds to agents' MCP: a `Vector` of [`AppTool`](@ref)."
app_tools(::AgentApp) = AppTool[]

"Markdown appended to the system prompt of the app chat's agent."
app_briefing(::AgentApp) = ""

"""
    app_briefing(app, key) -> String

The briefing of the app's chat with `key` (see [`start_chat!`](@ref)): by
default `app_briefing(app)` for the app's own chat (key "") and nothing for the
chats it started.
"""
app_briefing(app::AgentApp, key::AbstractString) = isempty(key) ? app_briefing(app) : ""

"""
    app_allowed(app, user) -> Bool

May `user` use `app`: see it on the dashboard, and have its tools in their
chats? Admins only by default: an app's state is the server's, so a member's
agent reading it would read everyone's.
"""
app_allowed(::AgentApp, user::User) = is_admin(user)

"""
    call_tool(app, Val(name), call::AppCall) -> String | Dict

Run the app's tool `name` for `call`, whose `args` are the tool's parameters,
checked and converted. Return the text the agent reads, or a whole MCP
`CallToolResult` dict. Throw [`AppError`](@ref) for a call that cannot be done
as asked.
"""
function call_tool end

# `chat_pane(app, view)` is in chat.jl, next to the ordinary layout and the
# chat's widgets (`ChatHeader`, `ChatTranscript`, ...).

"""
    AppError(msg)

A request an app cannot do as asked: no such item, a folder that isn't there.
An agent gets `msg` as its tool's error; the server log does not, since nothing
went wrong on this side.
"""
struct AppError <: Exception
    msg::String
end
Base.showerror(io::IO, e::AppError) = print(io, e.msg)

# ── tools ───────────────────────────────────────────────────────────────────

"""
    Param(T, description)
    Param(T, description, default)

A parameter of an [`AppTool`](@ref): an argument of Julia type `T` (`String`,
`Int`, `Float64` or `Bool`), required unless it has a default. The tool's JSON
schema is made from it, and the call's argument is checked and converted to `T`
before `call_tool` sees it.
"""
struct Param{T}
    description::String
    default::Union{T,Nothing}      # `nothing`: required
end
Param(::Type{T}, description::AbstractString) where {T} = Param{T}(description, nothing)
Param(::Type{T}, description::AbstractString, default) where {T} =
    Param{T}(description, convert(T, default))

isrequired(p::Param) = p.default === nothing

json_type(::Type{String})  = "string"
json_type(::Type{Int})     = "integer"
json_type(::Type{Float64}) = "number"
json_type(::Type{Bool})    = "boolean"

param_schema(p::Param{T}) where {T} =
    Dict{String,Any}("type" => json_type(T), "description" => p.description)

# A JSON value as `T`, or `nothing` when it isn't one. Agents send whole numbers
# as floats or strings often enough that an `Int` takes both.
arg_value(::Type{String}, v::AbstractString) = String(v)
arg_value(::Type{Bool}, v::Bool) = v
arg_value(::Type{Int}, v::Integer) = Int(v)
arg_value(::Type{Int}, v::AbstractFloat) = isinteger(v) ? Int(v) : nothing
arg_value(::Type{Int}, v::AbstractString) = tryparse(Int, strip(v))
arg_value(::Type{Float64}, v::Real) = Float64(v)
arg_value(::Type, ::Any) = nothing

arg_kind(::Type{String})  = "a string"
arg_kind(::Type{Int})     = "an integer"
arg_kind(::Type{Float64}) = "a number"
arg_kind(::Type{Bool})    = "true or false"

"""
    ToolScope

Which chats' agents get a tool: [`EveryChat`](@ref) or [`AppChat`](@ref). An app
can define its own, with a method of `in_scope(scope, app, chat::ProjectInfo)`.
"""
abstract type ToolScope end

"Every chat's agent gets the tool."
struct EveryChat <: ToolScope end

"Only the app's own chat gets the tool."
struct AppChat <: ToolScope end

"The chats the app started with a key (see [`start_chat!`](@ref)) get the tool; `in_scope` checks the key with `prefix`."
struct AppKeyedChats <: ToolScope
    prefix::String
end
AppKeyedChats() = AppKeyedChats("")

in_scope(::EveryChat, ::AgentApp, ::ProjectInfo) = true
in_scope(::AppChat, app::AgentApp, chat::ProjectInfo) = chat.app == app_id(app) && isempty(chat.app_key)
in_scope(s::AppKeyedChats, app::AgentApp, chat::ProjectInfo) =
    chat.app == app_id(app) && !isempty(chat.app_key) && startswith(chat.app_key, s.prefix)

"""
    AppTool(name, description, params = (;); scope = EveryChat())

A tool an app adds to the agents' MCP: `params` is a `NamedTuple` of
[`Param`](@ref)s, `scope` a [`ToolScope`](@ref). The name must be unique across
the server's apps and BonitoMCP's own tools; prefixing it with the app's id
keeps it so. A call runs `call_tool(app, Val(name), call)`.

```julia
AppTool(:notes_add, "Add a note.", (text = Param(String, "The note."),))
```
"""
struct AppTool
    name::Symbol
    description::String
    params::NamedTuple
    scope::ToolScope
end
AppTool(name, description::AbstractString, params::NamedTuple = (;); scope::ToolScope = EveryChat()) =
    AppTool(Symbol(name), String(description), params, scope)

input_schema(t::AppTool) = Dict{String,Any}(
    "type"       => "object",
    "properties" => Dict{String,Any}(String(k) => param_schema(p) for (k, p) in pairs(t.params)),
    "required"   => [String(k) for (k, p) in pairs(t.params) if isrequired(p)])

"""
    AppCall

One call of an app tool: the server (`call.server`), the chat whose agent called
it (`call.caller`, a `ProjectInfo`) and the arguments (`call.args`, a
`NamedTuple` by the tool's parameters).
"""
struct AppCall{A<:NamedTuple}
    server::ServerState
    caller::ProjectInfo
    args::A
end

# The arguments of a call, by the tool's parameters: present and of their type,
# or the default. A JSON `null` counts as absent.
function tool_args(t::AppTool, raw::AbstractDict)
    names = keys(t.params)
    return NamedTuple{names}(map(n -> tool_arg(t.params[n], n, raw), names))
end

function tool_arg(p::Param{T}, name::Symbol, raw::AbstractDict) where {T}
    v = get(raw, String(name), nothing)
    v === nothing && return isrequired(p) ? throw(AppError("missing argument `$name`")) : p.default
    x = arg_value(T, v)
    x === nothing && throw(AppError("argument `$name` must be $(arg_kind(T))"))
    return x
end

# What `call_tool` returned, as the MCP result BonitoMCP passes on.
tool_result(text::AbstractString) = BonitoMCP.tool_text(text)
tool_result(result::AbstractDict) = Dict{String,Any}(result)

# ── the apps a server runs ──────────────────────────────────────────────────

"""
    start_apps!(server, apps) -> server

Start the server's apps, each from its type: `A(AppContext(server, dir))`.
Called once, by the `ServerState` constructor.
"""
function start_apps!(server::ServerState, apps)
    for A in apps
        # A plugin package is loaded while `serve` is already executing. Its
        # app-interface methods therefore live in a newer Julia world age than
        # this precompiled function; cross that boundary here, once per app.
        id = Base.invokelatest(app_id, A)
        haskey(server.apps, id) && error("two apps with the id '$id'")
        app = Base.invokelatest(A, AppContext(server, joinpath(server.state_dir, "apps", id)))::AgentApp
        icon = Base.invokelatest(app_icon, app)
        icon === nothing || isfile(icon) || error("the icon of app '$id' is not a file: $icon")
        server.apps[id] = app
    end
    return server
end

# What an <img> shows as the app's logo: its file, or a tile with a letter.
app_icon_src(app::AgentApp) = app_icon_src(app_icon(app), app)
app_icon_src(path::AbstractString, ::AgentApp) = Bonito.Asset(path)
app_icon_src(::Nothing, app::AgentApp) =
    "data:image/svg+xml;base64," * base64encode(letter_icon_svg(app_title(app), app_id(app)))

# The first letter or digit of `title` on a rounded square, coloured by `key`.
function letter_icon_svg(title::AbstractString, key::AbstractString)
    i = findfirst(c -> isletter(c) || isdigit(c), title)
    letter = i === nothing ? "?" : uppercase(string(title[i]))
    hue = hash(key) % 360
    return string(
        "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' viewBox='0 0 64 64'>",
        "<rect width='64' height='64' rx='14' fill='hsl(", hue, ", 55%, 48%)'/>",
        "<text x='32' y='33' text-anchor='middle' dominant-baseline='central' ",
        "font-family='system-ui, sans-serif' font-size='32' font-weight='600' fill='#fff'>",
        letter, "</text></svg>")
end

"The app `p` is the chat of, or `nothing` for an ordinary chat (or an app this server doesn't run)."
app_of(server::ServerState, p::ProjectInfo) = isempty(p.app) ? nothing : get(server.apps, p.app, nothing)

function chat_app(model::ChatModel)
    p = get(model.state.projects[], model.project_id, nothing)
    return p === nothing ? nothing : app_of(model.state, p)
end

"""
    app_chat(server, app) -> ProjectInfo | nothing

The app's chat: the newest one marked with its id and no key ("Continue on"
leaves the original behind), or `nothing` before it was first opened.
"""
function app_chat(server::ServerState, app::AgentApp)
    id = app_id(app)
    chats = lock(() -> [p for p in values(server.projects[]) if p.app == id && isempty(p.app_key)], server.lock)
    return isempty(chats) ? nothing : argmax(p -> p.created, chats)
end

"""
    ensure_app_chat!(server, app; worker_id = "") -> ProjectInfo

The app's chat, created on first use: a project in a folder of its own on the
worker (`bonitoagents-apps/<id>` under the worker's projects root), marked with
the app's id. `worker_id` picks the worker when the chat has to be created (see
`chat_worker`); an existing chat stays where it is.
"""
function ensure_app_chat!(server::ServerState, app::AgentApp; worker_id::AbstractString = "")
    p = app_chat(server, app)
    p === nothing || return p
    id   = app_id(app)
    wid  = chat_worker(server, worker_id; needed_by = "$(app_title(app))'s chat")
    w    = server.workers[][wid]
    root = isempty(w.projects_root) ? w.home : w.projects_root
    path = ensure_worker_dir(server, wid, rstrip(root, ('/', '\\')) * "/bonitoagents-apps/" * id)
    p = ProjectInfo(string(uuid4())[1:8], id, wid, compute_server_path(server, wid, id), path, now(UTC))
    p.app = id
    p.title[] = app_title(app)
    return add_project!(server, p)
end

"""
    open_app_chat!(server, app, current_view; worker_id = "") -> ProjectInfo

Create-or-find the app's chat, bring its session up (which also brings back a
closed one), and show it in this window.
"""
function open_app_chat!(server::ServerState, app::AgentApp, current_view::Observable{String};
                        worker_id::AbstractString = "")
    p = ensure_app_chat!(server, app; worker_id)
    ensure_project_session!(server, p)
    current_view[] = p.id
    return p
end

# ── what apps can do with the server ────────────────────────────────────────

"""
    owner_user(server, name) -> User | nothing

The person a chat's `owner` names, for the visibility rules: the one user of an
open server, or the account behind the login. `nothing` for a name with no
account (removed or disabled since).
"""
owner_user(server::ServerState, name::AbstractString) = owner_user(server.auth, server, name)
owner_user(auth::OpenAuth, ::ServerState, name::AbstractString) =
    auth.user.name == name ? auth.user : nothing
function owner_user(::LoginAuth, server::ServerState, name::AbstractString)
    a = get(server.accounts[], String(name), nothing)
    (a === nothing || a.disabled) && return nothing
    return User(a.name, a.email, a.display_name, a.groups)
end

"""
    caller_user(call) -> User

The person whose chat made `call`. Always known: a chat whose owner has no
account gets no app tools at all.
"""
caller_user(call::AppCall) = owner_user(call.server, call.caller.owner)::User

"The title of chat `pid`, or `nothing` for a chat that is gone."
function chat_title(server::ServerState, pid::AbstractString)
    p = get(server.projects[], String(pid), nothing)
    return p === nothing ? nothing : p.title[]
end

"""
    ChatFolder

A folder chats run in: the worker (`worker`, a `WorkerInfo`, or `nothing` for
one that was removed; `worker_id` either way), the folder on it (`path`), its
chats with the most recently active first (`chats`, `ProjectInfo`s) and when the
last of them was active (`last_active`, unix time, 0 for never).
"""
struct ChatFolder
    worker_id::String
    worker::Union{WorkerInfo,Nothing}
    path::String
    chats::Vector{ProjectInfo}
    last_active::Float64
end

"""
    chat_folders(server, user) -> Vector{ChatFolder}

The folders `user`'s chats run in, the most recently active first. Apps' chats
are left out: their folders are the apps', not the user's projects.
"""
function chat_folders(server::ServerState, user::User)
    by_folder = Dict{Tuple{String,String},Vector{ProjectInfo}}()
    lock(server.lock) do
        for p in values(server.projects[])
            (isempty(p.app) && visible(user, p)) || continue
            push!(get!(Vector{ProjectInfo}, by_folder, project_location_key(p)), p)
        end
    end
    workers = server.workers[]
    folders = map(collect(by_folder)) do ((wid, path), chats)
        active = Dict(p.id => last_active(server, p) for p in chats)
        sort!(chats; by = p -> active[p.id], rev = true)
        ChatFolder(wid, get(workers, wid, nothing), path, chats, active[first(chats).id])
    end
    return sort!(folders; by = f -> f.last_active, rev = true)
end

"""
    find_worker(server, user, name) -> WorkerInfo | nothing

A worker `user` may use, by its id or its name (any case).
"""
function find_worker(server::ServerState, user::User, name::AbstractString)
    workers = [w for w in values(server.workers[]) if visible(user, w)]
    i = something(findfirst(w -> w.worker_id == name, workers),
                  findfirst(w -> lowercase(w.name) == lowercase(strip(name)), workers),
                  Some(nothing))
    return i === nothing ? nothing : workers[i]
end

"""
    start_chat!(server, owner, worker, path; title = "", prompt = "", app = nothing, key = "") -> ProjectInfo

A new chat in folder `path` on `worker`, belonging to `owner`, brought up and
sent `prompt` as its first message. Throws [`AppError`](@ref) for a worker that
isn't connected and for a path that isn't a folder there.

With `app`, the chat is one of that app's, told apart from its others by `key`
(not empty: "" is the app's own chat): its pane is the app's `chat_pane` and its
agent gets the app's briefing for that key ([`app_briefing`](@ref)) and the
tools in scope for it ([`AppKeyedChats`](@ref)). The pane reads the key with
[`chat_key`](@ref).
"""
function start_chat!(server::ServerState, owner::User, worker::WorkerInfo, path::AbstractString;
                     title::AbstractString = "", prompt::AbstractString = "",
                     app::Union{AgentApp,Nothing} = nothing, key::AbstractString = "")
    app === nothing || !isempty(strip(key)) ||
        throw(AppError("a chat an app starts needs a key: \"\" is the app's own chat"))
    isopen(worker) || throw(AppError("worker '$(worker.name)' is not connected"))
    st = stat_worker_path(server, worker.worker_id, path)
    st.exists || throw(AppError("there is no folder $path on $(worker.name)"))
    st.isdir  || throw(AppError("$path on $(worker.name) is a file, not a folder"))
    p = create_project_from_worker!(server, worker.worker_id, normalize_worker_path(st.path);
                                    start_session = false)
    p.owner = owner.name
    if app !== nothing
        p.app = app_id(app)
        p.app_key = String(strip(key))
    end
    isempty(strip(title)) || (p.title[] = first(strip(title), TITLE_MAX_CHARS))
    isempty(prompt) || (p.auto_prompt = String(prompt))
    lock(server.lock) do; save_projects!(server); end
    # The bring-up sends the prompt (`fire_auto_prompt!`).
    ensure_project_session!(server, p)
    return p
end

"""
    chat_key(view) -> String

The key of the app chat `view` shows ("" for the app's own chat), for a
`chat_pane` that lays out several chats of one app (see [`start_chat!`](@ref)).
"""
function chat_key(view::ChatModel)
    p = get(view.state.projects[], view.project_id, nothing)
    return p === nothing ? "" : p.app_key
end

"""
    chat_file_url(view, path) -> String

The URL a browser loads file `path` from, on the worker the chat `view` shows
runs on: for a pane that shows files, e.g. as `media_element(url, mime, is_video)`.
"""
function chat_file_url(view::ChatModel, path::AbstractString)
    p = view.state.projects[][view.project_id]
    return worker_file_url(view.state, p.worker_id, String(path))
end

"""
    show_chat!(view, pid)

Show chat `pid` in the window `view` (a tab's view of a chat, as `chat_pane`
gets it) is open in.
"""
function show_chat!(view::ChatModel, pid::AbstractString)
    view.plotpane === nothing || (view.plotpane.navigate[] = String(pid))
    return nothing
end

# ── tools: what BonitoMCP lists and forwards ────────────────────────────────

"""
    visible_tools(server, caller) -> Vector{Pair{AgentApp,AppTool}}

Every app tool `caller`'s agent gets, in a stable order (by app id): those of
the apps its owner may use, in scope for the chat. None for a channel that names
no known chat, or a chat whose owner has no account.
"""
visible_tools(::ServerState, ::Nothing) = Pair{AgentApp,AppTool}[]
function visible_tools(server::ServerState, caller::ProjectInfo)
    out = Pair{AgentApp,AppTool}[]
    user = owner_user(server, caller.owner)
    user === nothing && return out
    for id in sort!(collect(keys(server.apps)))
        app = server.apps[id]
        app_allowed(app, user) || continue
        for t in app_tools(app)
            in_scope(t.scope, app, caller) && push!(out, app => t)
        end
    end
    return out
end

caller_project(server::ServerState, caller::AbstractString) =
    isempty(caller) ? nothing : get(server.projects[], String(caller), nothing)

# The tools as MCP's `tools/list` describes them.
dev_op(server::ServerState, ::Val{:app_tools}, ::AbstractDict, caller::String) =
    [Dict{String,Any}("name" => String(t.name), "description" => t.description,
                      "inputSchema" => input_schema(t))
     for (_, t) in visible_tools(server, caller_project(server, caller))]

# One call. `found = false` for a name no app offers this chat, so BonitoMCP can
# answer it as the unknown tool it is.
function dev_op(server::ServerState, ::Val{:app_call}, args::AbstractDict, caller::String)
    name = String(get(args, "tool", ""))
    project = caller_project(server, caller)
    tools = visible_tools(server, project)
    i = findfirst(at -> String(last(at).name) == name, tools)
    i === nothing && return Dict{String,Any}("found" => false)
    app, t = tools[i]
    result = try
        call = AppCall(server, project, tool_args(t, get(args, "args", Dict{String,Any}())))
        tool_result(call_tool(app, Val(t.name), call))
    catch e
        e isa AppError || rethrow()
        BonitoMCP.tool_error(e.msg)
    end
    return Dict{String,Any}("found" => true, "result" => result)
end

# ── the app chat's system prompt ────────────────────────────────────────────

"The system-prompt part an app chat's agent gets, or \"\" for an ordinary chat."
function app_prompt_appendix(server::ServerState, p::ProjectInfo)
    app = app_of(server, p)
    return app === nothing ? "" : app_briefing(app, p.app_key)
end

# ── the dashboard's Apps section ────────────────────────────────────────────

"""
    apps_section(session, state, current_view, busy) -> DOM | nothing

The dashboard's apps, as a grid of tiles: logo and title, with the details on
hover. A click opens the app's chat. Before the chat exists a dialog asks first
which worker it runs its agent on; after, the click just opens it. Opening
reports into `busy`, the window's progress card.
"""
function apps_section(session::Bonito.Session, state::ServerState,
                      current_view::Union{Observable{String},Nothing}, busy::Observable)
    current_view === nothing && return nothing
    # The server's own view (no user, tests' standalone dashboards) is an admin's.
    allowed(app) = state.user === nothing || app_allowed(app, state.user)
    apps = [state.apps[id] for id in sort!(collect(keys(state.apps))) if allowed(state.apps[id])]
    isempty(apps) && return nothing
    tiles = [app_tile(session, state, app, current_view, busy) for app in apps]
    # The dialogs outside the grid: a tile's hover state must not reach them.
    return DOM.div(AppsStyles,
                   DOM.div(first.(tiles); class = "bt-apps"),
                   last.(tiles))
end

# One app's tile and its setup dialog.
function app_tile(session::Bonito.Session, state::ServerState, app::AgentApp,
                  current_view::Observable{String}, busy::Observable)
    title = app_title(app)
    # The worker its chat runs on, by name, or "" before it has one.
    runs_on = map(session, state.projects, state.workers) do _, workers
        p = app_chat(state, app)
        p === nothing ? "" : last(worker_label(workers, p))
    end
    status = map(w -> isempty(w) ? "Not set up" : "on $w", session, runs_on)

    setting_up = Observable(false)
    chosen = Observable("")   # the dialog's worker; "" is the first connected one by name
    clicked = Observable(false)
    on(session, clicked) do _
        if app_chat(state, app) === nothing
            chosen[] = ""
            setting_up[] = true
        else
            launch_app!(state, app, current_view, busy)
        end
    end
    start = Observable(false)
    on(session, start) do _
        setting_up[] = false
        launch_app!(state, app, current_view, busy; worker_id = chosen[])
    end
    dialog = Modal(setting_up; title = "Set up $title") do
        app_setup(session, state, app, chosen, start, setting_up)
    end

    tile = DOM.div(
        DOM.button(
            DOM.img(; src = app_icon_src(app), alt = "", class = "bt-app-logo", draggable = "false"),
            DOM.span(title; class = "bt-app-title"),
            DOM.span(status; class = "bt-app-status");
            type = "button", class = "bt-app-launch",
            onclick = js"event => $(clicked).notify(true)"),
        app_details(session, app, runs_on);
        class = "bt-app-tile", dataApp = app_id(app),
        # Near the window's right edge the details open leftwards.
        onmouseenter = js"""event => {
            const t = event.currentTarget, d = t.querySelector('.bt-app-details');
            t.classList.toggle('bt-app-flip',
                t.getBoundingClientRect().left + d.offsetWidth > document.documentElement.clientWidth - 8);
        }""")
    return tile => dialog
end

# What the tile tells on hover: the app's description, the tools it gives
# agents, and where its chat runs.
function app_details(session::Bonito.Session, app::AgentApp, runs_on::Observable{String})
    parts = Any[DOM.div(app_title(app); class = "bt-app-details-title")]
    desc = app_description(app)
    isempty(desc) || push!(parts, DOM.p(desc; class = "bt-app-details-desc"))
    tools = app_tools(app)
    isempty(tools) || push!(parts,
        DOM.div(DOM.div("Tools for agents"; class = "bt-app-details-label"),
                DOM.div((DOM.code(String(t.name)) for t in tools); class = "bt-app-details-tools")))
    push!(parts, DOM.div(map(session, runs_on) do w
        isempty(w) ? "Not set up yet: a click picks the worker its chat runs on." :
                     "Its chat runs on $w."
    end; class = "bt-app-details-where"))
    return DOM.div(parts; class = "bt-app-details", role = "tooltip")
end

# The setup dialog: what the app is, and the worker its chat will run on.
function app_setup(session::Bonito.Session, state::ServerState, app::AgentApp,
                   chosen::Observable{String}, start::Observable{Bool}, setting_up::Observable{Bool})
    title = app_title(app)
    online(workers) = sort([w for w in values(workers) if isopen(w) && visible(state, w)]; by = w -> w.name)
    choices = map(session, state.workers, chosen) do workers, wid
        ws = online(workers)
        isempty(ws) && return DOM.div("No worker is connected. Connect one to set up $title.";
                                      class = "bt-app-noworker")
        i = something(findfirst(w -> w.worker_id == wid, ws), 1)
        DOM.div((DOM.button(DOM.span(w.name; class = "bt-app-choice-name"),
                            DOM.span(w.hostname; class = "bt-app-choice-host");
                            type = "button", class = k == i ? "bt-app-choice bt-on" : "bt-app-choice",
                            var"aria-pressed" = string(k == i),
                            onclick = js"event => $(chosen).notify($(w.worker_id))")
                 for (k, w) in enumerate(ws));
                class = "bt-app-choices", role = "group", var"aria-label" = "Worker")
    end
    none_online = map(ws -> isempty(online(ws)), session, state.workers)
    desc = app_description(app)
    return DOM.div(
        DOM.div(DOM.img(; src = app_icon_src(app), alt = "", class = "bt-app-logo", draggable = "false"),
                DOM.div(DOM.div(title; class = "bt-app-setup-title"),
                        (isempty(desc) ? () : (DOM.p(desc; class = "bt-app-setup-desc"),)));
                class = "bt-app-setup-head"),
        DOM.div("Its chat runs an agent, on the worker you pick:"; class = "bt-app-setup-label"),
        choices,
        DOM.div("It stays there. From then on a click on its tile opens it."; class = "bt-app-setup-note"),
        DOM.div(DOM.button("Cancel"; type = "button", class = "bw-btn bw-btn-secondary",
                           onclick = js"event => $(setting_up).notify(false)"),
                DOM.button("Set up and open"; type = "button", class = "bw-btn bt-app-start",
                           disabled = none_online, onclick = js"event => $(start).notify(true)");
                class = "bt-form-actions");
        class = "bt-app-setup")
end

# Open the app's chat (made first, on `worker_id`, if it has none) with the
# window's progress card up meanwhile.
function launch_app!(state::ServerState, app::AgentApp, current_view::Observable{String},
                     busy::Observable; worker_id::AbstractString = "")
    busy_start!(busy, "Opening $(app_title(app))…")
    Base.errormonitor(@async try
        open_app_chat!(state, app, current_view; worker_id)
        # Its chat on screen is the outcome.
        busy_clear!(busy)
    catch e
        e isa InterruptException && rethrow()
        @warn "opening an app's chat failed" app = app_id(app) exception = (e, catch_backtrace())
        busy_fail!(busy, "Could not open $(app_title(app))", error_detail(e, catch_backtrace()))
    end)
    return nothing
end

const AppsStyles = Styles(
    # Tiles of one size, as many as fit a row; on a phone two or three.
    CSS(".bt-apps", "display" => "grid",
        "grid-template-columns" => "repeat(auto-fill, minmax(116px, 1fr))",
        "gap" => "var(--bw-space-3)"),
    CSS(".bt-app-tile", "position" => "relative", "min-width" => "0"),
    CSS(".bt-app-launch",
        "appearance" => "none", "font" => "inherit", "color" => "inherit",
        "width" => "100%", "height" => "100%",
        "display" => "flex", "flex-direction" => "column", "align-items" => "center",
        "gap" => "6px", "padding" => "16px 8px 12px",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius)",
        "box-shadow" => "var(--bw-shadow-sm)", "cursor" => "pointer",
        "transition" => "box-shadow 120ms ease, border-color 120ms ease, transform 120ms ease"),
    CSS(".bt-app-launch:hover",
        "border-color" => "var(--bw-border-strong)", "box-shadow" => "var(--bw-shadow-md)",
        "transform" => "translateY(-1px)"),
    CSS(".bt-app-launch:focus-visible",
        "outline" => "2px solid var(--bw-accent)", "outline-offset" => "2px"),
    CSS(".bt-app-logo", "width" => "52px", "height" => "52px", "flex-shrink" => "0",
        "border-radius" => "12px", "object-fit" => "contain", "user-select" => "none"),
    CSS(".bt-app-title, .bt-app-status",
        "max-width" => "100%", "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-app-title", "font-weight" => "600", "font-size" => "var(--bw-font-size-ui)", "margin-top" => "4px"),
    CSS(".bt-app-status", "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-muted)"),

    # The details: under the tile, after a short pause so a passing pointer
    # doesn't flash them; not on touch screens, which have no hover (the setup
    # dialog says the same).
    CSS(".bt-app-details",
        "position" => "absolute", "top" => "calc(100% + 6px)", "left" => "0", "z-index" => "30",
        "width" => "min(300px, calc(100vw - 32px))", "box-sizing" => "border-box",
        "padding" => "12px 14px",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border-strong)", "border-radius" => "var(--bw-radius)",
        "box-shadow" => "var(--bw-shadow-md)",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "1.45",
        "opacity" => "0", "visibility" => "hidden", "pointer-events" => "none",
        "transition" => "opacity 120ms ease, visibility 0s linear 120ms"),
    CSS(".bt-app-tile:hover .bt-app-details, .bt-app-tile:focus-within .bt-app-details",
        "opacity" => "1", "visibility" => "visible",
        "transition" => "opacity 120ms ease 300ms, visibility 0s linear 300ms"),
    CSS(".bt-app-flip .bt-app-details", "left" => "auto", "right" => "0"),
    CSS("@media (hover: none)", CSS(".bt-app-details", "display" => "none")),
    CSS(".bt-app-details-title", "font-weight" => "600", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-app-details-desc", "margin" => "4px 0 0", "color" => "var(--bw-text)"),
    CSS(".bt-app-details-label", "margin-top" => "8px", "color" => "var(--bw-text-muted)",
        "font-size" => "var(--bw-font-size-xs)"),
    CSS(".bt-app-details-tools", "display" => "flex", "flex-wrap" => "wrap", "gap" => "4px",
        "margin-top" => "3px"),
    CSS(".bt-app-details-tools code",
        "font-size" => "var(--bw-font-size-xs)", "padding" => "1px 5px", "border-radius" => "4px",
        "background" => "var(--bw-bg-subtle)", "border" => "1px solid var(--bw-border)"),
    CSS(".bt-app-details-where", "margin-top" => "8px", "color" => "var(--bw-text-muted)"),

    # The setup dialog.
    CSS(".bt-app-setup", "display" => "flex", "flex-direction" => "column",
        "gap" => "var(--bw-space-3)", "padding-top" => "12px"),
    CSS(".bt-app-setup-head", "display" => "flex", "gap" => "var(--bw-space-3)",
        "align-items" => "flex-start"),
    CSS(".bt-app-setup-title", "font-weight" => "600", "font-size" => "var(--bw-font-size-lg)"),
    CSS(".bt-app-setup-desc", "margin" => "4px 0 0", "color" => "var(--bw-text-muted)",
        "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.45"),
    CSS(".bt-app-setup-label", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-app-setup-note", "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)"),
    CSS(".bt-app-choices", "display" => "flex", "flex-direction" => "column", "gap" => "6px"),
    CSS(".bt-app-choice",
        "appearance" => "none", "font" => "inherit", "color" => "inherit", "text-align" => "left",
        "display" => "flex", "align-items" => "baseline", "gap" => "8px",
        "padding" => "10px 12px", "cursor" => "pointer",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border-strong)", "border-radius" => "var(--bw-radius-sm)"),
    CSS(".bt-app-choice:hover", "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-app-choice.bt-on",
        "border-color" => "var(--bw-accent)", "box-shadow" => "0 0 0 1px var(--bw-accent)"),
    CSS(".bt-app-choice-name", "font-weight" => "600", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-app-choice-host", "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)",
        "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "min-width" => "0"),
    CSS(".bt-app-noworker", "color" => "var(--bw-text-muted)", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-app-start:disabled", "opacity" => "0.5", "cursor" => "not-allowed"),
)
