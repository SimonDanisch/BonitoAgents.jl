using Test, BonitoWorker
import JSON

# Exercise the actual WS → stdio relay, including newline framing. The sink is
# a file because the relay closes stdin on EOF, just as it does in production.
mutable struct MCPEnvFrames
    frames::Vector{String}
end
BonitoWorker.WebSockets.isclosed(ws::MCPEnvFrames) = isempty(ws.frames)
BonitoWorker.WebSockets.receive(ws::MCPEnvFrames) = popfirst!(ws.frames)

@testset "MCP dial-back URL survives filtered agent environments" begin
    url = "https://worker-visible.example:8443/bonito"
    own = Dict{String,Any}("name" => "btworker", "command" => "julia",
        "args" => ["--startup-file=no"], "env" => Any[
            Dict("name" => "BONITOAGENTS_SECRET", "value" => "test-secret"),
            Dict("name" => "BONITOAGENTS_PROJECT_ID", "value" => "test-chat"),
            Dict("name" => "BONITOAGENTS_DEV_TOOLS", "value" => "1")])
    other = Dict("name" => "other", "command" => "other-mcp", "env" => Any[])
    http = Dict("name" => "btworker", "type" => "http", "url" => "https://other.example")
    for method in ("session/new", "session/load", "session/fork", "session/resume")
        msg = Dict("jsonrpc" => "2.0", "id" => 7, "method" => method,
            "params" => Dict("cwd" => "/project", "sessionId" => "session-1",
                             "mcpServers" => [deepcopy(own), other, http]))
        input = JSON.json(msg)
        mktemp() do path, io
            BonitoWorker.relay_ws_to_proc(MCPEnvFrames([input]), (; in = io); server_url = url)
            output = read(path, String)
            @test endswith(output, '\n')
            decoded = JSON.parse(output)
            servers = decoded["params"]["mcpServers"]
            # Simulate an agent forwarding ONLY the explicit ACP env, as Codex
            # does: all four required values must be present without inheritance.
            env = Dict(e["name"] => e["value"] for e in servers[1]["env"])
            @test env == Dict("BONITOAGENTS_SERVER_URL" => url,
                "BONITOAGENTS_SECRET" => "test-secret",
                "BONITOAGENTS_PROJECT_ID" => "test-chat", "BONITOAGENTS_DEV_TOOLS" => "1")
            @test servers[2] == other
            @test servers[3] == http
            servers[1]["env"] = own["env"]
            @test decoded == msg
        end
        # A resumed entry with an old URL gets the current worker's address,
        # exactly once, even if the same frame passes through twice.
        once = BonitoWorker.inject_mcp_server_url(input, "http://old.example")
        twice = BonitoWorker.inject_mcp_server_url(once, url)
        @test BonitoWorker.inject_mcp_server_url(twice, url) == twice
        entries = JSON.parse(twice)["params"]["mcpServers"][1]["env"]
        @test only(filter(e -> e["name"] == "BONITOAGENTS_SERVER_URL", entries))["value"] == url
        @test BonitoWorker.inject_mcp_server_url(input, "") == input
    end
    for msg in (Dict("id" => 1, "result" => Dict()),
                Dict("method" => "session/prompt", "params" => Dict("mcpServers" => [own])),
                Dict("method" => "session/load", "params" => Dict("sessionId" => "s")),
                Dict("method" => "session/new", "params" => Dict("mcpServers" => [other, http])))
        line = JSON.json(msg) * "\n"
        @test BonitoWorker.inject_mcp_server_url(line, url) == line
    end
end
