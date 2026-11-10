# Build Your Own Apps

An app makes BonitoAgents your own. It is an ordinary Julia package that
becomes a permanent part of your server, in three places:

- **A tile on the dashboard and a page of its own.** The page is whatever the
  app lays out, with a chat to the app's own agent built in.
- **Tools for every agent.** An app tool is a Julia function with typed
  parameters. The agents in your chats can call it, whichever agent runs there.
- **State on the server.** The app runs as long as the server does, whether
  its page is open or not, and keeps its files in the server's state directory.

You don't need an editor or a terminal to make one. Describe the app in a chat,
and the agent writes the package, runs it, shows it to you and loads it into
your server, all in that same chat.

## Build an app from a chat

Open a chat in a new folder and say what the app should do:

```text
Build a BonitoAgents app package called ReleaseChecklist, following
https://agents.bonito.sh/stable/apps.html. It keeps one checklist per release,
gives every agent a tool to tick off a step, and shows the list above the
app's chat. Try it in your Julia session, show me the list here, and load it
into the server when I say so.
```

From there the loop stays in the chat:

1. **The agent writes the package** in the chat's folder: an `AgentApp` type,
   its tools and its page, built from the interface in
   [Writing an app](#Writing-an-app). The To-do app in BonitoAgents' source
   (`BonitoAgents/src/apps/BonitoTodo/`) is a complete example to copy from.
2. **It runs the app** in its persistent Julia session. A `ServerState` with
   only this app needs no dashboard and no workers, so the agent can start it,
   call its tools and check what they did.
3. **It shows you the app's views.** A view returned from `bt_julia_eval`
   renders live in the chat and follows the app's state, so a tool call shows
   up in it right away. Detach it into a workspace tab to keep it beside the
   conversation.
4. **You review and steer.** **Review changes** shows the package's code.
   Comment on a line, ask for a change, and the agent edits, reloads with
   Revise and shows the result again.
5. **You approve, and it loads the app into your server.** `bt_load_app` asks
   first: the chat shows a card naming the package, and nothing loads until
   you click **Load**. Then the package loads into the running server, without
   a restart. The tile appears on the dashboard at once, and chats started from
   then on get the app's tools.

The agent's session for steps 2 and 3, for the Notes app from
[Writing an app](#Writing-an-app):

```julia
using BonitoAgents, Bonito, Dates, NotesApp
import BonitoAgents as BA

# A server with only this app, in throwaway folders.
server = BA.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                          apps = (NotesApp.Notes,))
notes = server.apps["notes"]

# A tool call as an agent's call arrives, from a made-up chat.
chat = BA.ProjectInfo("c1", "Try", "w", mktempdir(), "/tmp/try", now(UTC))
BA.call_tool(notes, Val(:notes_add), BA.AppCall(server, chat, (text = "first note",)))

# A view of the app, live in the chat.
App(() -> DOM.div(NotesApp.NotesList(notes)))
```

## Install an app

An app package registers its app when it loads, and carries a marker so the
server loads it again whenever it starts:

```julia
function __init__()
    BonitoAgents.register_app!(ReleaseChecklistApp)
end
```

```toml
[bonitoagents]
plugin = true
```

### From the chat

`bt_load_app(path)` asks the running server to load the package in `path`.
The server asks you first: the chat shows a card with the package's name and
folder, and the agent's call waits for your answer, ten minutes at most. Only a
click on **Load**, in an admin's browser tab, lets it go ahead. **Deny**, or no
answer, and the agent is told so. The agent has no way to answer the card
itself, and its permission settings, Yolo included, play no part.

Once approved, the server adds the package to its Julia environment as a
development checkout of that folder, loads it and starts its apps. Nothing
restarts, and the other chats keep running. The tool's reply says which apps
started, which tools they bring, and whether the marker is missing.

It works when:

- **The chat runs on the server's machine.** The server reads the folder
  itself. A chat on the desktop app's own worker can load apps, and a chat on
  another machine can't.
- **The chat is an admin's.** Loading puts code into the server process.
- **The server can write its Julia environment.** The desktop app's environment
  is in its data folder (`Project.toml` there), and a dev server or a server
  you start from your own environment writes that one. A server set up with
  `install_server.sh` runs as its own service user on your checkout, so it
  can't. Install apps there by hand, as below.

A package loads once per server run. To try changed code in the server, restart
it. The agent's Julia session picks up changes with Revise in the meantime, so
most of the work happens there, before the load.

### By hand

On a server set up with `install_server.sh`, add the package to the BonitoAgents
checkout's environment and run the installer again. It installs the package
for the server's service user and restarts the server with the app:

```bash
cd /path/to/BonitoAgents.jl
julia --project=. -e 'using Pkg; Pkg.add(url = "https://github.com/you/ReleaseChecklist.jl")'
bash BonitoAgents/assets/install_server.sh
```

A server you start yourself with `julia -m BonitoAgents` loads the marked
packages of the environment it runs in. `serve(; apps)` takes the app types
directly and then runs exactly those:

```julia
using BonitoAgents, ReleaseChecklist
BonitoAgents.serve(; apps = (BonitoAgents.BUILTIN_APPS..., ReleaseChecklist.ReleaseChecklistApp))
```

To try an app without touching your server, the agent can start a dev server
with it, `BonitoAgents.dev_server(; apps = (ReleaseChecklist.ReleaseChecklistApp,))`,
and give you its link. It runs on the chat's worker, so the link opens in a
browser on that machine.

BonitoAgents is not in Julia's General registry, so an app package names it in
`[sources]`. That lets the package's own environment resolve it, for its tests
and the agent's session:

```toml
[sources]
BonitoAgents = {url = "https://github.com/SimonDanisch/BonitoAgents.jl.git", subdir = "BonitoAgents"}
```

## Where apps show up

An app is for admins by default, because its state is the server's: only they
see its tile, and only their chats get its tools. An app can let more people
in with `app_allowed`. The dashboard's **Apps** section lists the tiles. The
first click on a tile asks which worker the app's chat runs on and creates it
there, in a folder of its own (`bonitoagents-apps/<app>` under the worker's
projects root). After that the tile opens the same chat. App chats are pinned
at the top of the sidebar, under **Apps**.

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

## A bigger example: BonitoCommunity

[BonitoCommunity](https://github.com/SimonDanisch/BonitoCommunity.jl) runs the
community work around Makie and Bonito as an app. Each video or post gets a
project with its own chat, whose agent drafts the posts for every platform with
the app's tools. The app's page shows the drafts for review, and a click
publishes them, never the agent. The app then collects the replies, and the
agent drafts answers for you to send.

It uses the parts of the interface the Notes example below leaves out: keyed
chats (one per project, `AppKeyedChats`), a scope of its own for tools, the
shared controls, and secrets kept encrypted in the app's directory.

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

To be loaded into a server it also needs the `__init__` and the marker from
[Install an app](#Install-an-app).

What else an app can define, all optional: `app_description` (its tile's
details and setup dialog), `app_icon` (the path of its logo, a square SVG or PNG
that ships with the package, e.g. `joinpath(@__DIR__, "logo.svg")`; without one
its tile shows the first letter of its title), `app_briefing` (added to its chat
agent's system prompt), `app_allowed` (who may use it; admins by default). A
tool's `scope` can also be a `ToolScope` of the app's own, with a method of
`in_scope`.

The chat widgets are components: `ChatHeader(view)`, `ChatNotice(view)`,
`ChatTranscript(view)` (the messages), `ChatComposer(view)` and `ChatToolbar()`.
Each can appear once per pane, anywhere in it. An app's own parts are Bonito
components too: a struct with a `jsrender` method, and for more than a few lines
of browser code an `ES6Module` the component connects to (the To-do list does
that, `src/apps/BonitoTodo/todo.js`). What an app can do with the server:
`start_chat!` (a chat in a folder, with a first prompt), `chat_folders` and
`find_worker` (where the user's chats run), `chat_title`, `app_chat`,
`caller_user` (whose chat called a tool), and from the pane `show_chat!` and
`send_message!`.

The To-do app (`BonitoAgents.BonitoTodo`) is built exactly this way, as a
module of BonitoAgents that uses only these names.

### Shared controls

Use the public `AppButton`, `AppCard`, `AppModal`, and `AppUIStyles` components
to inherit the server's appearance. They use the same BonitoWidgets controls
and `--bw-*` theme variables as the built-in pages, and carry the required
styles when rendered independently.

```julia
using BonitoAgents: AppButton, AppCard, AppModal
using Bonito

opened = Observable(false)
DOM.div(
    AppCard(DOM.h3("Release"), AppButton("Review";
        onclick = js"event => $(opened).notify(true)")),
    AppModal(opened; title = "Review release") do
        DOM.div("Approve each platform before publishing.")
    end)
```

Buttons accept `variant=:primary`, `:secondary`, `:ghost`, or `:danger`, and
`size=:normal` or `:small`. DOM attributes, including observable `disabled`
values and plugin data attributes, pass through unchanged. Cards provide the
shared surface; their content layout and padding belong to the plugin.

The modal builds fresh content on each open and removes it on close. Its close
button, backdrop, and Escape update the supplied `Observable{Bool}`. Plugins
can listen to this observable to cancel pending actions. For credential forms,
keep input values in the browser until the user explicitly submits them.

Include `AppUIStyles` for additional plugin layout using the public `--bw-*`
variables. Do not duplicate the server palette or shared button/modal CSS.
