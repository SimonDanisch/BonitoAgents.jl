module BonitoAgents

# Server-side dashboard package. Public API:
#
#   BonitoAgents.serve(; worker_secret, port=8038, public_url=nothing, ...)
#
# Glues together: Bonito UI + AgentClientProtocol + BonitoMCP (for the bundle
# endpoint) + BonitoWorker (the relay package the workers run).

using Bonito
using AgentClientProtocol
using AgentProviders     # provider descriptors + current_providers/find_provider (SSOT, shared w/ worker)
using HTTP
using JSON
using Markdown
using UUIDs
using Dates
using TOML
using Base64
using SHA
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

include("state.jl")            # WorkerInfo, ProjectInfo, ServerState (single source of truth)
include("progress.jl")         # notify_progress / format_progress_string — shared by sync + import
include("worker_client.jl")    # probe(...), connect_worker(...) — needs ACP
include("transport.jl")        # ACP bring-up payload helpers (mcp list, system prompt)
include("agents.jl")           # WorkerAgent (server-side live agent over the worker WS)
include("styles.jl")
include("plotpane.jl")         # PlotPane handle (window-scoped; built by install_workspace!)
include("taskbar.jl")          # TaskBar component (state-first pin-board)
include("chat.jl")             # message types (UserMsg, AgentMsg, ...)
include("lens.jl")             # lens search: parse + fuzzy filter + saved lenses
include("remote_app.jl")       # eval-result bridge — live worker Bonito results in the browser
include("workspace_stage.jl")  # BonitoWidgets.Workspace stage + app detach controller
include("persistence.jl")
include("overview.jl")         # recent-chats overview cards (dashboard header)
include("dashboard.jl")        # dashboard_app
include("worker_widget.jl")    # WorkerCard widget (stable per worker_id, used by KeyedList)
include("session_widget.jl")   # SessionRow widget (one row per discovered Claude Code session)
include("project_widget.jl")   # ProjectCard widget (stable per project_id, used by KeyedList)
include("file_tree.jl")        # WorkerFileTree — lazy, searchable project file tree (sidebar)
include("sidebar.jl")          # project_sidebar + auto-generated icons
include("github.jl")           # "From GitHub" project template
include("server.jl")           # serve()
include("dev.jl")              # dev_server() — self-contained dev rig

export serve, dev_server
export AgentProvider, BinAgent, WorkerAgent
export ClaudeCodeAgent, MiMoAgent, OpenCodeAgent, MockAgent
export start!, stop!, client, switch_provider!

# Bake the real browser-driven paths captured from the e2e suite: literal
# `precompile(...)` calls (see BonitoAgentsApp/precompile/) that run during
# precompilation and land in this package's pkgimage. Regenerate with
# precompile/generate.jl. Guarded so a fresh checkout without a capture still loads.
isfile(joinpath(@__DIR__, "precompile_statements.jl")) && include("precompile_statements.jl")

end # module BonitoAgents
