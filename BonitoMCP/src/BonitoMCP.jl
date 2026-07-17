module BonitoMCP

# Standalone Julia stdio MCP server for Claude Code and other MCP clients.
#
# Protocol: Model Context Protocol 2025-06-18 over stdio with JSON-RPC 2.0.
# Spec mirror: docs/external/mcp-spec-*.md
#
# Run (this is exactly how the BonitoAgents worker launches it — a plain
# `julia` process with an argv array, no shell wrapper, cross-platform):
#   julia --project=@bonito-agents -e 'using BonitoMCP; BonitoMCP.run_stdio()'

using JSON

const PROTOCOL_VERSION = "2025-06-18"
const SERVER_NAME = "BonitoMCP"
const SERVER_VERSION = "0.1.0"

# Tool registry: every tool registers itself at module-init time via register!
struct Tool
    name::String
    description::String
    input_schema::Dict{String,Any}
    handler::Function          # (args::Dict)::Dict (CallToolResult shape)
end

const TOOLS = Tool[]

function register!(name::AbstractString, description::AbstractString,
                   input_schema::AbstractDict, handler)
    push!(TOOLS, Tool(String(name), String(description),
                      Dict{String,Any}(input_schema), handler))
    return nothing
end

include("server.jl")
include("session.jl")          # JuliaSession + SessionManager (subprocess-per-env)
include("ctrl_ws.jl")          # control dial-back to BonitoAgents (per-tool interrupt)
include("context.jl")          # the one MCPServer value (SERVER) owning all process state
include("tools/eval.jl")
include("tools/show.jl")       # bt_show — rich MIME render, audience-tagged

# `RemoteProxy.jl` is NOT included here — it references `Bonito.*` types and
# BonitoMCP intentionally has no Bonito dep (cf. `eval_ws.jl`). The worker
# `include`s it from `session.jl`'s `ensure_eval_dialed!` after `using Bonito`.
# Runtime (pkgdir), not @__DIR__: @__DIR__ bakes the precompile-time path, gone
# in a relocated app bundle (built in a staging dir, run from elsewhere).
remote_proxy_path() = joinpath(pkgdir(@__MODULE__)::String, "src", "RemoteProxy.jl")

end # module BonitoMCP
