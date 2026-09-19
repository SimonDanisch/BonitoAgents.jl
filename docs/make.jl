using Bonito
using BonitoAgents
using Documenter

# BonitoAgents documentation, built with the Bonito Documenter writer
# (`Bonito.DocumenterBonito`), the same VitePress-styled, fully
# Bonito-rendered site Bonito's own docs use.

ci = get(ENV, "CI", "false") == "true"

home = (
    name = "BonitoAgents",
    text = "A visual workspace for coding agents",
    tagline = "Run Julia, inspect rich results, review changes and build live apps " *
              "across every machine you own.",
    image = "assets/bonitoagents-dark.svg",
    actions = [
        (text = "Get Started", link = "getting-started.html", theme = "brand"),
        (text = "View on GitHub", link = "https://github.com/SimonDanisch/BonitoAgents.jl", theme = "alt"),
    ],
    features = [
        (title = "Julia here or on another worker",
         details = "bt_julia_eval keeps project state warm, streams stdout and renders " *
                   "rich MIME results in the chat. Pass worker= to run on another machine.",
         link = "mcp-tools.html"),
        (title = "Live Bonito apps in the chat",
         details = "Return an App or WGLMakie figure and use it in place. Interactions " *
                   "round trip to Julia; detach it beside the chat without stopping it.",
         link = "mcp-tools.html"),
        (title = "Every artifact in place",
         details = "Open markdown, images, video, PDF, notebooks, tables and interactive " *
                   "3D geometry inside the chat or as editable workspace tabs.",
         link = "chat.html"),
        (title = "Review the git diff together",
         details = "Comment on a changed line or block, ask immediately, or collect " *
                   "several review notes into one instruction for the agent.",
         link = "chat.html#Reviewing-changes"),
        (title = "BonitoAgents can debug itself",
         details = "Open an agent on its own source with live tools for server state, " *
                   "worker logs, memory and controls; inspect, edit and test its own code.",
         link = "development.html#Debugging-BonitoAgents-itself"),
        (title = "Any machine, one dashboard",
         details = "Workers dial out from laptops, desktops and servers. Their projects " *
                   "and chats stay together in one browser workspace.",
         link = "workers.html"),
    ],
)

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
        "Getting Started" => "getting-started.md",
        "Concepts" => "concepts.md",
        "Guide" => [
            "The Chat" => "chat.md",
            "Workers & Machines" => "workers.md",
            "Agent Providers" => "providers.md",
            "Julia Tools & Live Apps" => "mcp-tools.md",
        ],
        "Development" => "development.md",
        "API" => "api.md",
    ],
)

if ci
    deploydocs(repo = "github.com/SimonDanisch/BonitoAgents.jl.git"; push_preview = true)
end
