using Bonito
using BonitoAgents
using Documenter

# BonitoAgents documentation, built with the Bonito Documenter writer
# (`Bonito.DocumenterBonito`), the same VitePress-styled, fully
# Bonito-rendered site Bonito's own docs use.

ci = get(ENV, "CI", "false") == "true"

home = (
    name = "BonitoAgents",
    text = "A workspace for coding agents and their results.",
    tagline = "Self-hosted and open source. Run Claude Code, Codex and other coding agents " *
              "on your own computers. Inspect code, plots and live apps beside the conversation, " *
              "and build your own apps without leaving it.",
    actions = [
        (text = "Get started", link = "getting-started.html", theme = "brand"),
        (text = "Watch the workflow", link = "#watch", theme = "alt"),
    ],
)

include("styles.jl")
open(joinpath(@__DIR__, "src", "assets", "site.css"), "w") do io
    show(io, MIME"text/plain"(), docs_styles())
end

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
        assets = ["assets/site.css", "assets/demo.js"],
    ),
    pages = [
        "Home" => "index.md",
        "A Day with BonitoAgents" => "story.md",
        "Getting Started" => "getting-started.md",
        "Build Your Own Apps" => "apps.md",
        "Concepts" => "concepts.md",
        "Guide" => [
            "The Chat" => "chat.md",
            "Workers & Machines" => "workers.md",
            "Agent Providers" => "providers.md",
            "Julia Tools & Live Apps" => "mcp-tools.md",
        ],
        "Development" => "development.md",
        "API" => "api.md",
        "Release Notes" => "release-notes.md",
    ],
)

if ci
    deploydocs(repo = "github.com/SimonDanisch/BonitoAgents.jl.git"; push_preview = true)
end
