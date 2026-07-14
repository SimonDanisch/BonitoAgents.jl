using Bonito
using BonitoAgents
using Documenter

# BonitoAgents documentation, built with the Bonito Documenter writer
# (`Bonito.DocumenterBonito`) — the same VitePress-styled, fully
# Bonito-rendered site Bonito's own docs use.

ci = get(ENV, "CI", "false") == "true"

home = (
    name = "BonitoAgents",
    text = "Your self-hosted control center for coding agents",
    tagline = "Run Claude Code (and friends) on every machine you own — steer them " *
              "all from one dashboard, in any browser, phone included.",
    image = "assets/bonitoagents-dark.svg",
    actions = [
        (text = "Get Started", link = "getting-started.html", theme = "brand"),
        (text = "View on GitHub", link = "https://github.com/SimonDanisch/BonitoAgents.jl", theme = "alt"),
    ],
    features = [
        (title = "Every machine, one dashboard",
         details = "Workers dial out from your laptops and servers; projects and " *
                   "chats from all of them live side by side, reachable from any browser.",
         link = "workers.html"),
        (title = "Rich sessions, not scrollback",
         details = "Streaming chat with Monaco diffs, terminal output, inline media, " *
                   "a project file tree and a real editor.",
         link = "chat.html"),
        (title = "Live, interactive results",
         details = "Agents hand back running Bonito apps — sliders slide, plots " *
                   "orbit — embedded straight into the conversation.",
         link = "mcp-tools.html"),
        (title = "Julia superpowers built in",
         details = "Persistent per-project Julia sessions as MCP tools: warm state, " *
                   "disciplined output, figures as images.",
         link = "mcp-tools.html"),
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
