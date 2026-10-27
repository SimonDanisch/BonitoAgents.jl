module BonitoAgents

# Server-side dashboard package. Public API:
#
#   BonitoAgents.serve(; auth, port=8038, public_url=nothing, ...)
#
# Glues together: Bonito UI + AgentClientProtocol + BonitoMCP (for the bundle
# endpoint) + BonitoWorker (the relay package the workers run).

using Bonito
using AgentClientProtocol
using AgentProviders     # provider descriptors + current_providers/find_provider (SSOT, shared w/ worker)
using HTTP
using JSON
using MsgPack
using Markdown
using UUIDs
using Dates
using TOML
using Base64
using SHA
import Random
import Colors          # distinguishable_colors: one clearly different color per worker
import Sockets
import WorkerLink      # one multiplexed, resumable connection per worker (always qualified)
# Used by `current_bonito_install_spec()` to parse `[sources]` out of the
# active project file so the install.jl template ships workers the exact
# Bonito url+rev the server is itself running. Stdlib — zero cost.
import Pkg

# CommonMark for the chat-message renderer. Used in `chat.jl :: markdown_html`
# (strict CommonMark fixes Julia's stdlib bug where `foo_bar_baz` italicizes
# everything between the intraword `_`s) AND in `persistence.jl` for the
# `+++` front-matter parse on chat.md. Hoisted here so the `const` parser in
# chat.jl can resolve at include time — chat.jl is included before persistence.jl.
import CommonMark as CM

import BonitoBook       # MonacoEditor / DiffEditor / Collapsible for tool rendering
import BonitoMCP        # shipped to workers, also used by the bundle build
import BonitoWorker     # ditto
using BonitoWidgets     # Workspace / Panel / FloatingWindow — the VSCode-style layout

# Asset under `assets/`, path resolved at RUNTIME via pkgdir — NOT @__DIR__,
# which bakes the precompile-time path and 404s in a relocated app bundle.
bonito_asset(parts::AbstractString...) =
    Bonito.Asset(joinpath(pkgdir(@__MODULE__)::String, "assets", parts...))

include("identity.jl")         # User, LocalAuth/ProxyAuth: who is on the other end (the proxy authenticates)
include("state.jl")            # WorkerInfo, ProjectInfo, ServerState (single source of truth)
include("tunnel.jl")           # behind a tunnel: the login gate before every route
include("progress.jl")         # notify_progress + the window's ONE progress card (BusyState)
include("worker_client.jl")    # probe(...), connect_worker(...) — needs ACP
include("transport.jl")        # ACP bring-up payload helpers (mcp list, system prompt)
include("agents.jl")           # WorkerAgent (server-side live agent over the worker WS)
include("styles.jl")
include("plotpane.jl")         # PlotPane handle (window-scoped; built by install_workspace!)
include("taskbar.jl")          # TaskBar component (state-first pin-board)
include("code_view.jl")        # CodeView / DiffView: read-only code as static DOM, highlighted by Monaco
include("chat.jl")             # message types (UserMsg, AgentMsg, ...)
include("chat_export.jl")      # "Export as Markdown": the chat as a .md that is also a BonitoBook notebook
include("measured_sizes.jl")   # body heights + media sizes the browser measured, sent with later renders
include("chat_queue.jl")       # pending submissions and delivery modes
include("session_notices.jl")  # recovery and durable dismissal of provider notices
include("file_view.jl")        # FileView / FilePanel — the one rich file renderer (bt_show + file tabs)
include("review.jl")           # change-review tab: git diff + per-line ask / batched feedback
include("lens.jl")             # lens search: parse + fuzzy filter + saved lenses
include("mcp_relay.jl")
include("remote_app.jl")       # eval-result bridge — live worker Bonito results in the browser
include("eval_runs.jl")        # Julia runs (`r4`): cards that outlive their call, task bar, finish notes
include("workspace_stage.jl")  # BonitoWidgets.Workspace stage + app detach controller
include("persistence.jl")
include("chat_icons.jl")        # durable, user-controlled chat image identities
include("overview.jl")         # recent-chats overview cards (dashboard header)
include("dashboard.jl")        # dashboard_app
include("worker_widget.jl")    # WorkerCard widget (stable per worker_id, used by KeyedList)
include("accounts.jl")         # worker credentials, accounts, adapter versions: the admin's controls
include("passkeys.jl")         # passkeys made and kept on our own pages (behind a tunnel)
include("session_widget.jl")   # SessionRow widget (one row per discovered Claude Code session)
include("chat_title.jl")       # chat_title_input — the one editor over ProjectInfo.title
include("file_tree.jl")        # WorkerFileTree — lazy, searchable project file tree (sidebar)
include("sidebar.jl")          # project_sidebar + auto-generated icons
include("github.jl")           # "From GitHub" project template
include("dev_api.jl")          # inspection API + the "Debug BonitoAgents" chat
include("diagnostics.jl")      # timings, browser tabs and their consoles, for the dev tools
include("apps.jl")             # apps: permanent server parts with a chat, a pane and MCP tools of their own
include("apps/BonitoTodo/BonitoTodo.jl")  # the To-do app, written like an app package: public API only
include("remote_eval.jl")      # bt_julia_eval(worker = …): eval hosts on other workers, the per-chat switch
include("remote_values.jl")    # remote_session(…): Julia values between a chat's session and another worker's
include("processes.jl")        # the record of every process a chat runs; a restart ends them all
include("shares.jl")           # shared links: a markdown file or a Bonito app for anyone with the link
include("crash_recovery.jl")   # continue the chats a worker crash cut off mid-turn
include("server.jl")           # serve()
include("dev.jl")              # dev_server() — self-contained dev rig

"The apps a server runs unless told otherwise (`serve(; apps)`)."
const BUILTIN_APPS = (BonitoTodo.TodoApp,)

export serve, dev_server
export AgentProvider, BinAgent, WorkerAgent
export ClaudeCodeAgent, MiMoAgent, OpenCodeAgent, KimiAgent, CodexAgent, MockAgent
export start!, stop!, client, switch_provider!
# Viewers that render in any Bonito session (a chat, a shared page, your own app).
export MeshViewer, media_element
# The app interface (apps.jl): what an app implements, the chat widgets its pane
# is built from, and what it can do with the server. An app package uses these
# names and nothing else.
public AgentApp, AppContext, AppTool, Param, ToolScope, EveryChat, AppChat, AppKeyedChats, in_scope,
       AppCall, AppError,
       app_id, app_title, app_description, app_icon, app_tools, call_tool, chat_pane, app_briefing,
       app_allowed,
       ChatHeader, ChatNotice, ChatTranscript, ChatComposer, ChatToolbar,
       ServerState, ProjectInfo, WorkerInfo, User, ChatFolder,
       caller_user, app_chat, chat_title, chat_folders, find_worker, start_chat!,
       chat_key, chat_file_url, show_chat!, send_message!,
       atomic_write_json, load_json_tolerant, relative_time_label,
       BUILTIN_APPS

# Bake the real browser-driven paths captured from the e2e suite: literal
# `precompile(...)` calls (see BonitoAgentsApp/precompile/) that run during
# precompilation and land in this package's pkgimage. Regenerate with
# precompile/generate.jl. Guarded so a fresh checkout without a capture still loads.
isfile(joinpath(@__DIR__, "precompile_statements.jl")) && include("precompile_statements.jl")

end # module BonitoAgents
