using Bonito
using BonitoAgents
using Documenter

# BonitoAgents documentation, built with the Bonito Documenter writer
# (`Bonito.DocumenterBonito`), the same VitePress-styled, fully
# Bonito-rendered site Bonito's own docs use.

ci = get(ENV, "CI", "false") == "true"

home = (
    name = "BonitoAgents",
    text = "Any coding agent. Every machine you own.",
    tagline = "A self-hosted workspace where Claude Code, Codex, Kimi Code, OpenCode " *
              "and friends work on your machines, and everything they make shows up live.",
    image = "assets/bonitoagents-dark.svg",
    actions = [
        (text = "Get Started", link = "getting-started.html", theme = "brand"),
        (text = "A Day with BonitoAgents", link = "story.html", theme = "alt"),
        (text = "View on GitHub", link = "https://github.com/SimonDanisch/BonitoAgents.jl", theme = "alt"),
    ],
    features = [
        (title = "Bring any agent",
         details = "Claude Code, Codex, Kimi Code, OpenCode, MiMo or any ACP agent. " *
                   "Switch a chat's agent mid-conversation; the conversation comes along.",
         link = "providers.html#Switching-agents"),
        (title = "Every machine, one dashboard",
         details = "Workers dial out from laptops, GPU desktops, Macs, Windows boxes and " *
                   "servers. Drive all of their chats from one browser, phone included.",
         link = "workers.html"),
        (title = "Everything it makes, in place",
         details = "Images, video, Jupyter notebooks, tables, 3D models, PDF and HTML open " *
                   "inside the chat or as editable workspace tabs.",
         link = "chat.html#Media-and-live-apps"),
        (title = "Live apps in the chat",
         details = "Return a Bonito App or WGLMakie figure and use it in place. Interactions " *
                   "round trip to Julia; detach it beside the chat without stopping it.",
         link = "mcp-tools.html"),
        (title = "Julia here or on another worker",
         details = "bt_julia_eval keeps project state warm, streams stdout and runs in the " *
                   "background. Pass worker= to compute on another machine.",
         link = "mcp-tools.html"),
        (title = "Share it with a link",
         details = "Send a report or a live app to anyone. It opens on their phone, and " *
                   "the app keeps computing on your worker.",
         link = "index.html#Share-a-report-or-a-live-app-with-a-link"),
        (title = "Review the git diff together",
         details = "Comment on a changed line or block, ask immediately, or collect " *
                   "several review notes into one instruction for the agent.",
         link = "chat.html#Reviewing-changes"),
        (title = "Yolo, with brakes",
         details = "Let an agent work on its own with your reminders attached. It stops " *
                   "when it is done, stuck, repeating itself or out of credits.",
         link = "chat.html#Staying-in-control"),
        (title = "BonitoAgents can debug itself",
         details = "Open an agent on its own source with live tools for server state, " *
                   "worker logs, memory and controls; inspect, edit and test its own code.",
         link = "development.html#Debugging-BonitoAgents-itself"),
    ],
)

# The release notes live in CHANGELOG.md, which GitHub shows next to the code.
cp(joinpath(@__DIR__, "..", "CHANGELOG.md"), joinpath(@__DIR__, "src", "release-notes.md"); force = true)

makedocs(
    modules = [BonitoAgents],
    sitename = "BonitoAgents",
    authors = "Simon Danisch and contributors",
    warnonly = true,
    format = Bonito.DocumenterBonito(
        repo = "github.com/SimonDanisch/BonitoAgents.jl",
        devbranch = "main",
        devurl = "dev",
        version = "dev",
        logo = "assets/bonitoagents-dark.svg",
        home = home,
    ),
    pages = [
        "Home" => "index.md",
        "A Day with BonitoAgents" => "story.md",
        "Getting Started" => "getting-started.md",
        "Concepts" => "concepts.md",
        "Guide" => [
            "The Chat" => "chat.md",
            "Workers & Machines" => "workers.md",
            "Agent Providers" => "providers.md",
            "Julia Tools & Live Apps" => "mcp-tools.md",
            "Apps" => "apps.md",
        ],
        "Development" => "development.md",
        "API" => "api.md",
        "Release Notes" => "release-notes.md",
    ],
)

if ci
    deploydocs(repo = "github.com/SimonDanisch/BonitoAgents.jl.git"; push_preview = true)
end
