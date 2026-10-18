"""
    BonitoTodo

The To-do app: one to-do list for the whole server.

The list lives in the server (saved to `<state_dir>/apps/todo/todos.json` on
every change), so every chat's agent can read it, add to it and check items off
(`todo_list`, `todo_add`, `todo_done`), while the app's chat shows it pinned
above its conversation. That chat's agent also starts chats for items: it picks
the folder an item belongs to from the ones the user's chats run in
(`todo_projects`) and opens a new chat there with a prompt for it
(`todo_start_chat`). Such a chat is told which item it works on, so it can check
it off when it is done.

Written the way an app package is, against BonitoAgents' public app interface
only: as a package of its own, `import ..BonitoAgents` becomes
`import BonitoAgents` and nothing else changes.
"""
module BonitoTodo

import ..BonitoAgents
using ..BonitoAgents: AgentApp, AppContext, AppTool, Param, AppChat, AppCall, AppError,
    ChatHeader, ChatNotice, ChatTranscript, ChatComposer, ChatToolbar,
    caller_user, chat_title, chat_folders, find_worker, start_chat!, show_chat!,
    send_message!, atomic_write_json, load_json_tolerant, relative_time_label
using Bonito
using Dates

export TodoApp

struct Todo
    id::Int
    text::String
    created::DateTime
    # Who added it: "" for the user, else the chat whose agent did (its id).
    added_by::String
    done_at::Union{DateTime,Nothing}
    # Who checked it off, the same way.
    done_by::String
    # What the chat that checked it off said about it.
    note::String
    # The chats started for it, oldest first (their ids).
    chats::Vector{String}
end

Todo(id::Int, text::AbstractString, added_by::AbstractString) =
    Todo(id, text, now(UTC), added_by, nothing, "", "", String[])

isdone(t::Todo) = t.done_at !== nothing

# `t` with some fields replaced. An item is never changed in place: a render
# holds the list it was given.
change(t::Todo; kw...) = Todo((get(kw, f, getfield(t, f)) for f in fieldnames(Todo))...)

# What todos.json holds. Ids are never reused: a chat that was told about #5
# must not check off a different #5 after the first was removed.
struct TodoFile
    next_id::Int
    todos::Vector{Todo}
end

# Shared by every tab and every chat's tool calls: the lock guards the list and
# `next_id` together.
mutable struct TodoApp <: AgentApp
    const lock::ReentrantLock
    const ctx::AppContext
    const file::String
    # Every item, in the order they were added; replaced on every change.
    const todos::Observable{Vector{Todo}}
    next_id::Int
end

function TodoApp(ctx::AppContext)
    file = joinpath(ctx.dir, "todos.json")
    saved = something(load_json_tolerant(file, "todos.json", TodoFile), TodoFile(1, Todo[]))
    # A hand-edited file may have added items without counting.
    next_id = max(saved.next_id, maximum((t.id for t in saved.todos); init = 0) + 1)
    return TodoApp(ReentrantLock(), ctx, file, Observable(saved.todos), next_id)
end

BonitoAgents.app_id(::Type{TodoApp}) = "todo"
BonitoAgents.app_title(::TodoApp) = "To-do"
BonitoAgents.app_description(::TodoApp) =
    "One to-do list for every chat: agents check items off, and its chat starts a chat for an item in the right project."
BonitoAgents.app_icon(::TodoApp) = joinpath(@__DIR__, "todo.svg")

# ── the list ────────────────────────────────────────────────────────────────

# Every change goes through here: `f` gets a copy of the list and returns the
# new one, which is saved and then shown.
function update_todos!(f, app::TodoApp)
    lock(app.lock) do
        app.todos.val = f(copy(app.todos[]))
        atomic_write_json(app.file, TodoFile(app.next_id, app.todos[]))
    end
    notify(app.todos)
    return app
end

# One item: `f` gets it and returns its new version, which is returned.
function update_todo!(f, app::TodoApp, id::Int)
    local t
    update_todos!(app) do todos
        i = todo_index(todos, id)
        t = todos[i] = f(todos[i])
        todos
    end
    return t
end

function todo_index(todos::Vector{Todo}, id::Int)
    i = findfirst(t -> t.id == id, todos)
    i === nothing && throw(AppError("there is no to-do #$id"))
    return i
end

find_todo(app::TodoApp, id::Int) = (todos = app.todos[]; todos[todo_index(todos, id)])

function todo_text(text::AbstractString)
    t = strip(text)
    isempty(t) && throw(AppError("a to-do needs a text"))
    return String(t)
end

"Add an item and return it. `by` is the chat whose agent added it, \"\" for the user."
function add_todo!(app::TodoApp, text::AbstractString; by::AbstractString = "")
    local t
    update_todos!(app) do todos
        t = Todo(app.next_id, todo_text(text), by)
        app.next_id += 1
        push!(todos, t)
    end
    return t
end

"""
    check_todo!(app, id, done; by = "", note = "") -> Todo

Check an item off (`done = true`) or open it again. `by` is the chat that
checked it off, "" for the user. Checking off a checked item keeps who did it
first.
"""
check_todo!(app::TodoApp, id::Int, done::Bool; by::AbstractString = "", note::AbstractString = "") =
    update_todo!(app, id) do t
        done ? (isdone(t) ? t : change(t; done_at = now(UTC), done_by = by, note = strip(note))) :
               change(t; done_at = nothing, done_by = "", note = "")
    end

edit_todo!(app::TodoApp, id::Int, text::AbstractString) =
    update_todo!(t -> change(t; text = todo_text(text)), app, id)

link_chat!(app::TodoApp, id::Int, chat_id::AbstractString) =
    update_todo!(t -> change(t; chats = vcat(t.chats, chat_id)), app, id)

remove_todo!(app::TodoApp, id::Int) =
    update_todos!(todos -> deleteat!(todos, todo_index(todos, id)), app)

# Who checked `t` off: the user (`you` names them) or a chat, by its title.
done_by(app::TodoApp, t::Todo; you::AbstractString) =
    isempty(t.done_by) ? you : something(chat_title(app.ctx.server, t.done_by), "a closed chat")

# ── what agents see ─────────────────────────────────────────────────────────

const TODO_ID = Param(Int, "The to-do's number (`#3` is 3).")

BonitoAgents.app_tools(::TodoApp) = [
    AppTool(:todo_list,
        "The BonitoAgents to-do list, shared by every chat on this server. Lists the open " *
        "items with their numbers; `include_done` lists the checked-off ones too.",
        (include_done = Param(Bool, "Also list checked-off items.", false),)),
    AppTool(:todo_add,
        "Add an item to the BonitoAgents to-do list (shared by every chat on this server). " *
        "Use it when the user asks for one, or for follow-up work worth remembering.",
        (text = Param(String, "What there is to do, one line."),)),
    AppTool(:todo_done,
        "Check off an item of the BonitoAgents to-do list once its work is done (in this " *
        "chat or elsewhere). `note` says in a sentence what was done.",
        (todo_id = TODO_ID, note = Param(String, "What was done, one sentence.", ""))),
    AppTool(:todo_remove,
        "Remove an item from the to-do list (not done, just no longer wanted).",
        (todo_id = TODO_ID,); scope = AppChat()),
    AppTool(:todo_projects,
        "The folders the user's chats run in, newest activity first: worker, path, and the " *
        "titles of the chats there. Use it to find the project a to-do belongs to.",
        (limit = Param(Int, "At most this many folders.", 40),); scope = AppChat()),
    AppTool(:todo_start_chat,
        "Start a new chat for a to-do, in a folder from `todo_projects`, and send it `prompt` as " *
        "its first message. The new chat is told which to-do it works on, so it can check it off.",
        (todo_id = TODO_ID,
         worker = Param(String, "The worker, as `todo_projects` names it."),
         path = Param(String, "The folder on that worker, as `todo_projects` lists it."),
         prompt = Param(String, "The new chat's first message: the task, with what its agent needs to know."),
         title = Param(String, "The chat's title (default: the to-do's text).", ""));
        scope = AppChat()),
]

BonitoAgents.app_briefing(::TodoApp) = """
# The To-do app

This chat is the BonitoAgents To-do app. Its pane shows the server-wide to-do
list above this conversation; the user edits it there. Every chat's agent can
read the list and check items off (`todo_list`, `todo_add`, `todo_done`); you
also have `todo_remove`, `todo_projects` and `todo_start_chat`.

To start a chat for a to-do (the user's "Start chat" button asks you to):
1. find the folder it belongs to with `todo_projects`: the folders the user's
   chats run in, with their chats' titles. When none clearly fits, ask.
2. call `todo_start_chat` with the worker and path exactly as listed, and a
   prompt that gives the new chat's agent the task and what it needs to know.
Keep your answers short: the list above shows the outcome.

Your working directory is an empty folder for this app. The projects are in
their own folders, on their workers.
"""

function todo_line(app::TodoApp, t::Todo)
    line = "#$(t.id) [$(isdone(t) ? "x" : " ")] $(t.text)"
    isempty(t.chats) || (line *= "  (chats: " * join(t.chats, ", ") * ")")
    if isdone(t)
        by = done_by(app, t; you = "the user")
        isempty(t.done_by) || (by = "chat \"$by\" ($(t.done_by))")
        line *= "\n    done $(Dates.format(t.done_at, "yyyy-mm-dd HH:MM")) UTC by $by"
        isempty(t.note) || (line *= ": " * t.note)
    end
    return line
end

function BonitoAgents.call_tool(app::TodoApp, ::Val{:todo_list}, call::AppCall)
    (; include_done) = call.args
    todos = filter(t -> include_done || !isdone(t), app.todos[])
    isempty(todos) && return include_done ? "The to-do list is empty." : "No open to-dos."
    return join((todo_line(app, t) for t in todos), "\n")
end

function BonitoAgents.call_tool(app::TodoApp, ::Val{:todo_add}, call::AppCall)
    t = add_todo!(app, call.args.text; by = call.caller.id)
    return "Added to-do #$(t.id)."
end

function BonitoAgents.call_tool(app::TodoApp, ::Val{:todo_done}, call::AppCall)
    (; todo_id, note) = call.args
    isdone(find_todo(app, todo_id)) && return "To-do #$todo_id was already checked off."
    check_todo!(app, todo_id, true; by = call.caller.id, note)
    return "Checked off to-do #$todo_id."
end

function BonitoAgents.call_tool(app::TodoApp, ::Val{:todo_remove}, call::AppCall)
    remove_todo!(app, call.args.todo_id)
    return "Removed to-do #$(call.args.todo_id)."
end

function BonitoAgents.call_tool(::TodoApp, ::Val{:todo_projects}, call::AppCall)
    (; limit) = call.args
    folders = chat_folders(call.server, caller_user(call))
    isempty(folders) && return "The user has no chats yet, so no project folders are known."
    lines = map(first(folders, limit)) do f
        w = f.worker
        where_ = w === nothing ? "$(f.worker_id) (gone)" : "$(w.name) ($(isopen(w) ? "online" : "offline"))"
        when = f.last_active == 0 ? "" : " · last active $(relative_time_label(f.last_active))"
        titles = join(("\"$(p.title[])\"" for p in first(f.chats, 6)), ", ")
        "- worker: $where_ · path: $(f.path)$when\n  chats: $titles"
    end
    length(folders) > limit && push!(lines, "($(length(folders) - limit) more folders; raise `limit` to see them)")
    return join(lines, "\n")
end

function BonitoAgents.call_tool(app::TodoApp, ::Val{:todo_start_chat}, call::AppCall)
    (; todo_id, worker, path, prompt, title) = call.args
    t = find_todo(app, todo_id)
    # The chat is its owner's: on a worker they may use, and theirs to see.
    owner = caller_user(call)
    w = find_worker(call.server, owner, worker)
    w === nothing && throw(AppError("there is no worker named '$worker'"))
    chat = start_chat!(call.server, owner, w, path;
                       title = isempty(strip(title)) ? t.text : title,
                       prompt = prompt * "\n\n" * todo_footer(t))
    link_chat!(app, t.id, chat.id)
    return "Started chat \"$(chat.title[])\" ($(chat.id)) in $path on $(w.name) for to-do #$(t.id)."
end

todo_footer(t::Todo) = """
(This chat was started for to-do #$(t.id) on the BonitoAgents to-do list:
"$(t.text)". When the work is done, check it off with the `todo_done` tool,
todo_id $(t.id).)"""

# ── the pane ────────────────────────────────────────────────────────────────

# The ordinary chat, with the list pinned between the header and the messages.
BonitoAgents.chat_pane(app::TodoApp, view) = (
    ChatHeader(view), TodoPanel(app, view), ChatNotice(view),
    ChatTranscript(view), ChatComposer(view), ChatToolbar())

"""
    TodoPanel(app, view)

The list, for one tab (`view` is its copy of the app's chat): an input to add
an item, a row per item with its checkbox, text (a double click edits it), the
chats started for it and its buttons. The browser module (`todo.js`) draws it
from the items it is sent and sends back what the user does.
"""
struct TodoPanel{V}
    app::TodoApp
    view::V
end

const TodoLib = Bonito.ES6Module(joinpath(@__DIR__, "todo.js"))

function Bonito.jsrender(session::Bonito.Session, panel::TodoPanel)
    app, view = panel.app, panel.view
    # The user's actions, as `[action, id, value]`.
    act = Observable{Any}(nothing)
    on(session, act) do a
        a isa AbstractVector && length(a) == 3 && todo_action!(app, view, a[1], a[2], a[3])
    end
    # The items as the page draws them; this tab's child of the shared list.
    rows = map(todos -> panel_rows(app, todos), session, app.todos)
    bar = DOM.div(DOM.span("To-do"; class = "bt-todo-title"), DOM.span(; class = "bt-todo-counts"),
                  DOM.label(DOM.input(type = "checkbox", class = "bt-todo-showdone"), " show done";
                            class = "bt-todo-toggle");
                  class = "bt-todo-bar")
    form = DOM.form(DOM.input(type = "text", class = "bt-todo-input", placeholder = "Add a to-do…",
                              autocomplete = "off"),
                    DOM.button("Add"; type = "submit", class = "bt-btn bt-btn-secondary bt-btn-sm");
                    class = "bt-todo-add")
    list = DOM.div(; class = "bt-todo-list")
    connect = js"""$(TodoLib).then(lib => lib.connect({bar: $(bar), form: $(form), list: $(list)},
                                                      $(rows), $(act)))"""
    return Bonito.jsrender(session, DOM.div(TodoStyles, bar, form, list, connect; class = "bt-todo"))
end

# The open items in the order they were added, then the checked-off ones, the
# latest first: what `todo.js` draws.
function panel_rows(app::TodoApp, todos::Vector{Todo})
    server = app.ctx.server
    item(t) = Dict{String,Any}(
        "id" => t.id, "text" => t.text,
        "chats" => [Dict("id" => c, "title" => something(chat_title(server, c), c)) for c in t.chats],
        "done_label" => isdone(t) ?
            join(filter(!isempty, ["✓ by " * done_by(app, t; you = "you"),
                                   relative_time_label(datetime2unix(t.done_at)), t.note]), " · ") : "")
    done = sort!(filter(isdone, todos); by = t -> t.done_at, rev = true)
    return Dict{String,Any}("open" => [item(t) for t in todos if !isdone(t)],
                            "done" => [item(t) for t in done])
end

# ── what the pane sends ─────────────────────────────────────────────────────

# The actions the panel sends, checked before one becomes a `Val`.
const TODO_ACTIONS = ("add", "check", "edit", "remove", "open", "start")

# A click in the panel. A stale one (an item another tab just removed) is not
# an error worth more than a line in the log.
function todo_action!(app::TodoApp, view, action::AbstractString, id::Real, value)
    action in TODO_ACTIONS || return @info "to-do action not understood" action
    try
        todo_action!(app, view, Val(Symbol(action)), Int(id), value)
    catch e
        e isa AppError || rethrow()
        @info "to-do action skipped" action id reason = e.msg
    end
    return nothing
end
todo_action!(::TodoApp, view, action, id, value) = @info "to-do action not understood" action id value

todo_action!(app::TodoApp, view, ::Val{:add}, ::Int, text::AbstractString) = add_todo!(app, text)
todo_action!(app::TodoApp, view, ::Val{:check}, id::Int, done::Bool) = check_todo!(app, id, done)
todo_action!(app::TodoApp, view, ::Val{:edit}, id::Int, text::AbstractString) = edit_todo!(app, id, text)
todo_action!(app::TodoApp, view, ::Val{:remove}, id::Int, ::Nothing) = remove_todo!(app, id)
todo_action!(::TodoApp, view, ::Val{:open}, ::Int, chat_id::AbstractString) = show_chat!(view, chat_id)

# Asking is the user's own message to this chat's agent: it shows in the
# transcript as theirs, and the agent does the rest with its tools.
function todo_action!(app::TodoApp, view, ::Val{:start}, id::Int, ::Nothing)
    t = find_todo(app, id)
    send_message!(view, "Start a chat for to-do #$(t.id): \"$(t.text)\". Find the project it " *
                        "belongs to (`todo_projects`), then start the chat there (`todo_start_chat`).")
    return nothing
end

todo_action!(::TodoApp, view, action::Val, id::Int, value) =
    @info "to-do action not understood" action id value

const TodoStyles = Styles(
    # Pinned between the header and the messages: as tall as its items, at most
    # under half the pane, scrolling inside past that.
    CSS(".bt-todo",
        "flex" => "0 1 auto", "max-height" => "45%", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column",
        "border-bottom" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)"),
    CSS(".bt-todo-bar",
        "display" => "flex", "align-items" => "center", "gap" => "var(--bt-space-3)",
        "padding" => "var(--bt-space-2) var(--bt-space-4) 0"),
    CSS(".bt-todo-title", "font-weight" => "600"),
    CSS(".bt-todo-counts, .bt-todo-toggle, .bt-todo-empty",
        "color" => "var(--bt-text-muted)", "font-size" => "var(--bt-text-sm)"),
    CSS(".bt-todo-toggle", "margin-left" => "auto", "cursor" => "pointer", "user-select" => "none"),
    CSS(".bt-todo-add",
        "display" => "flex", "gap" => "var(--bt-space-2)",
        "padding" => "var(--bt-space-2) var(--bt-space-4)", "margin" => "0"),
    CSS(".bt-todo-input",
        "flex" => "1 1 auto", "min-width" => "0",
        "padding" => "var(--bt-space-1) var(--bt-space-2)",
        "border" => "1px solid var(--bt-border)", "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-bg)", "color" => "var(--bt-text)", "font" => "inherit"),
    CSS(".bt-todo-list",
        "overflow-y" => "auto", "min-height" => "0",
        "padding" => "0 var(--bt-space-4) var(--bt-space-2)"),
    CSS(".bt-todo-empty", "padding" => "var(--bt-space-1) 0"),
    CSS(".bt-todo-item",
        "display" => "flex", "align-items" => "flex-start", "gap" => "var(--bt-space-2)",
        "padding" => "var(--bt-space-1) 0", "border-top" => "1px solid var(--bt-border)"),
    CSS(".bt-todo-item:first-child", "border-top" => "none"),
    CSS(".bt-todo-check", "margin" => "var(--bt-space-1) 0 0", "cursor" => "pointer"),
    CSS(".bt-todo-body", "flex" => "1 1 auto", "min-width" => "0"),
    CSS(".bt-todo-line", "display" => "flex", "gap" => "var(--bt-space-1)", "align-items" => "baseline"),
    CSS(".bt-todo-id", "color" => "var(--bt-text-faint)", "font-size" => "var(--bt-text-xs)",
        "font-variant-numeric" => "tabular-nums"),
    CSS(".bt-todo-text", "overflow-wrap" => "anywhere", "outline" => "none"),
    CSS(".bt-todo-text[contenteditable='plaintext-only']",
        "box-shadow" => "0 0 0 1px var(--bt-accent)", "border-radius" => "var(--bt-radius-sm)"),
    CSS(".bt-todo-item-done .bt-todo-text",
        "text-decoration" => "line-through", "color" => "var(--bt-text-muted)"),
    CSS(".bt-todo-meta",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "var(--bt-space-1)",
        "margin-top" => "var(--bt-space-1)",
        "font-size" => "var(--bt-text-xs)", "color" => "var(--bt-text-muted)"),
    # A chat started for the item: a link to it.
    CSS(".bt-todo-chat",
        "border" => "1px solid var(--bt-border)", "border-radius" => "999px",
        "background" => "var(--bt-surface-2)", "color" => "var(--bt-text)",
        "padding" => "0 var(--bt-space-2)", "font" => "inherit", "cursor" => "pointer",
        "max-width" => "240px", "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-todo-chat:hover", "border-color" => "var(--bt-accent)"),
    CSS(".bt-todo-actions", "display" => "flex", "gap" => "var(--bt-space-1)", "flex-shrink" => "0"),
)

end # module BonitoTodo
