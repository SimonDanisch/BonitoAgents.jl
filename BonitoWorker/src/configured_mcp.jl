# Worker-local stdio servers. Keep commands/paths here: they belong to this
# machine, and the same ACP session payload is used by every agent provider.
struct ConfiguredMCPServer
    name::String
    command::String
    args::Vector{String}
    env::Dict{String,String}
end

function configured_mcp_servers(config::AbstractDict)
    servers = ConfiguredMCPServer[]
    for (name, spec) in sort!(collect(get(config, "mcp_servers", Dict())); by = first)
        get(spec, "enabled", true) || continue
        name == "btworker" && throw(ArgumentError("mcp_servers: btworker is reserved for BonitoAgents"))
        isempty(strip(name)) && throw(ArgumentError("mcp_servers: a server name cannot be empty"))
        command = String(spec["command"])
        isempty(strip(command)) && throw(ArgumentError("mcp_servers.$name.command cannot be empty"))
        push!(servers, ConfiguredMCPServer(String(name), command,
            String.(get(spec, "args", String[])),
            Dict{String,String}(get(spec, "env", Dict{String,String}()))))
    end
    return servers
end

function worker_mcp_servers(config::AbstractDict; command::AbstractString = "julia",
                            project::AbstractString = something(Base.active_project(), "@bonito-agents"),
                            index::AbstractString = joinpath(config_dir(), "romeodb"))
    # The core is shipped with every worker. User entries can override its
    # launch (e.g. to enable embeddings), or disable it with enabled=false.
    defaults = Dict{String,Any}("btromeodb" => Dict{String,Any}(
        "command" => String(command),
        "args" => ["--project=$project", "--startup-file=no", "--threads=2", "-e",
                   "using RomeoDB; RomeoDB.serve(ARGS[1])", String(index)],
        "env" => Dict{String,String}()))
    merge!(defaults, get(config, "mcp_servers", Dict()))
    return configured_mcp_servers(Dict("mcp_servers" => defaults))
end

function configured_mcp_servers(; command::AbstractString = "julia")
    path = get(ENV, "BONITOAGENTS_MCP_CONFIG", config_path())
    if !isfile(path)
        haskey(ENV, "BONITOAGENTS_MCP_CONFIG") && error("MCP configuration file does not exist: $path")
        return worker_mcp_servers(Dict(); command)
    end
    return worker_mcp_servers(JSON.parse(read(path, String)); command)
end

mcp_payload(s::ConfiguredMCPServer) = Dict{String,Any}(
    "name" => s.name, "command" => s.command, "args" => copy(s.args),
    "env" => [Dict("name" => k, "value" => v) for (k, v) in sort!(collect(s.env); by = first)])
