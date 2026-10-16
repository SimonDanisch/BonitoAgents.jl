# Apps

An app is a permanent part of the server with a chat of its own. Its state lives
in the server, so it is there whether or not its chat is open; its chat's pane is
laid out by the app; and it can give every chat's agent tools of its own.

The dashboard's **Apps** card lists them (admins only: an app's state is the
server's). The first **Open** creates the app's chat on the worker the pill
names, in a folder of its own (`bonitoagents-apps/<app>` under the worker's
projects root); after that it opens the same chat. App chats are pinned at the
top of the sidebar, under **Apps**.

## The To-do app

One to-do list for the whole server, shown above its chat's conversation.

- **In the pane**: add an item, check it off, double-click its text to edit it,
  remove it. **Start chat** asks the app chat's agent to start a chat for the
  item: it looks through the folders your chats run in, picks the one the item
  belongs to (or asks), and opens a new chat there with a prompt for it. The new
  chat is linked from the item, and told which item it works on.
- **From any chat**: every agent has `todo_list`, `todo_add` and `todo_done`, so
  "add that as a to-do" or "check off the release notes" works in any chat. The
  list shows which chat checked an item off, and its note.

The list is saved in the server's state directory (`apps/todo/todos.json`).

## Writing an app

An app is an ordinary Julia package. It depends on BonitoAgents (and Bonito for
its UI), uses only BonitoAgents' public names, and defines a subtype of
`AgentApp`:

```julia
module NotesApp

import BonitoAgents
using BonitoAgents: AgentApp, AppContext, AppTool, Param, AppChat, AppCall, AppError,
                    ChatHeader, ChatTranscript, ChatComposer,
                    atomic_write_json, load_json_tolerant
using Bonito

struct Notes <: AgentApp
    ctx::AppContext                 # the server and the app's own directory
    notes::Observable{Vector{String}}
end

# The server starts an app from its type: `Notes(ctx)`.
Notes(ctx::AppContext) = Notes(ctx, Observable(something(
    load_json_tolerant(joinpath(ctx.dir, "notes.json"), "notes.json", Vector{String}), String[])))

BonitoAgents.app_id(::Type{Notes}) = "notes"        # the one required method, on the type
BonitoAgents.app_title(::Notes) = "Notes"

# Tools for the agents. Parameters are typed: the JSON schema is made from them,
# and the call's arguments arrive checked and converted. `scope = AppChat()`
# keeps a tool to the app's own chat.
BonitoAgents.app_tools(::Notes) = [
    AppTool(:notes_add, "Add a note.", (text = Param(String, "The note."),)),
    AppTool(:notes_clear, "Clear all notes.", (;); scope = AppChat()),
]

function BonitoAgents.call_tool(app::Notes, ::Val{:notes_add}, call::AppCall)
    (; text) = call.args
    isempty(text) && throw(AppError("the note is empty"))   # the agent reads this
    app.notes[] = vcat(app.notes[], text)
    atomic_write_json(joinpath(app.ctx.dir, "notes.json"), app.notes[])
    return "Added."
end
BonitoAgents.call_tool(app::Notes, ::Val{:notes_clear}, ::AppCall) = (app.notes[] = String[]; "Cleared.")

# Its chat's pane: any DOM, built from the chat's widgets (components, like
# the app's own `NotesList`).
BonitoAgents.chat_pane(app::Notes, view) =
    (ChatHeader(view), NotesList(app), ChatTranscript(view), ChatComposer(view))

struct NotesList
    app::Notes
end
# Each tab renders its own, from its session's child of the shared list.
Bonito.jsrender(session::Bonito.Session, l::NotesList) =
    Bonito.jsrender(session, DOM.div(map(ns -> DOM.ul(DOM.li.(ns)...), session, l.app.notes)))

end
```

Run a server with it next to the built-in apps:

```julia
using BonitoAgents, NotesApp
BonitoAgents.serve(; apps = (BonitoAgents.BUILTIN_APPS..., NotesApp.Notes))
# or, while developing it: BonitoAgents.dev_server(; apps = (NotesApp.Notes,))
```

What else an app can define, all optional: `app_description` (the dashboard's
line), `app_briefing` (added to its chat agent's system prompt), `app_allowed`
(who may use it; admins by default). A tool's `scope` can also be a
`ToolScope` of the app's own, with a method of `in_scope`.

The chat widgets are components: `ChatHeader(view)`, `ChatNotice(view)`,
`ChatTranscript(view)` (the messages), `ChatComposer(view)` and `ChatToolbar()`.
Each can appear once per pane, anywhere in it. An app's own parts are Bonito
components too: a struct with a `jsrender` method, and for more than a few lines
of browser code an `ES6Module` the component connects to (the To-do list does
that, `src/apps/BonitoTodo/todo.js`). What an app can do with the server: `start_chat!` (a chat in a
folder, with a first prompt), `chat_folders` and `find_worker` (where the user's
chats run), `chat_title`, `app_chat`, `caller_user` (whose chat called a tool),
and from the pane `show_chat!` and `send_message!`.

The To-do app (`BonitoAgents.BonitoTodo`) is built exactly this way, as a
module of BonitoAgents that uses only these names.
