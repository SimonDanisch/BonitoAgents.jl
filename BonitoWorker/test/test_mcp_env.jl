using Test, BonitoWorker
import JSON

# Exercise the actual channel → stdio relay, including newline framing. The sink
# is a file because the relay closes stdin on EOF, just as it does in production.
mutable struct MCPEnvFrames
    frames::Vector{String}
end
BonitoWorker.WebSockets.isclosed(ws::MCPEnvFrames) = isempty(ws.frames)
BonitoWorker.WebSockets.receive(ws::MCPEnvFrames) = popfirst!(ws.frames)

@testset "the MCP's relay grant survives filtered agent environments" begin
    link = BonitoWorker.WorkerLink.Link(:client)    # never connected: the grant is all this needs
    relay = BonitoWorker.start_mcp_relay(link)
    own = Dict{String,Any}("name" => "btworker", "command" => "julia",
        "args" => ["--startup-file=no"], "env" => Any[
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
            BonitoWorker.relay_ws_to_proc(MCPEnvFrames([input]), (; in = io), relay, "session-owner")
            output = read(path, String)
            @test endswith(output, '\n')
            decoded = JSON.parse(output)
            servers = decoded["params"]["mcpServers"]
            # Simulate an agent forwarding ONLY the explicit ACP env, as Codex
            # does: everything the MCP needs is there without inheritance, and
            # nothing that would reach the server on its own.
            env = Dict(e["name"] => e["value"] for e in servers[1]["env"])
            @test sort(collect(keys(env))) == ["BONITOAGENTS_CONTROL_TOKEN", "BONITOAGENTS_CONTROL_URL",
                                               "BONITOAGENTS_DEV_TOOLS", "BONITOAGENTS_EVAL_TOKEN",
                                               "BONITOAGENTS_PROJECT_ID"]
            @test startswith(env["BONITOAGENTS_CONTROL_URL"], "ws://127.0.0.1:")
            # One token per role: the eval workers' token cannot open the control channel.
            control = relay.grants[env["BONITOAGENTS_CONTROL_TOKEN"]]
            evalgrant = relay.grants[env["BONITOAGENTS_EVAL_TOKEN"]]
            @test (control.kind, control.project_id, control.host, control.owner) ==
                  ("mcp", "test-chat", false, "session-owner")
            @test (evalgrant.kind, evalgrant.project_id, evalgrant.owner) == ("eval", "test-chat", "session-owner")
            @test servers[2] == other
            @test servers[3] == http
            servers[1]["env"] = own["env"]
            @test decoded == msg
        end
    end
    for msg in (Dict("id" => 1, "result" => Dict()),
                Dict("method" => "session/prompt", "params" => Dict("mcpServers" => [own])),
                Dict("method" => "session/load", "params" => Dict("sessionId" => "s")),
                Dict("method" => "session/new", "params" => Dict("mcpServers" => [other, http])))
        line = JSON.json(msg) * "\n"
        @test BonitoWorker.inject_mcp_grant(line, relay, "session-owner") == line
    end
    # A handshake is only honoured for the role its token was minted for.
    env = BonitoWorker.mcp_relay_env(relay, "test-chat"; owner = "roles")
    control, evaltoken = env["BONITOAGENTS_CONTROL_TOKEN"], env["BONITOAGENTS_EVAL_TOKEN"]
    @test BonitoWorker.relay_request(relay, control)[3]["kind"] == "mcp"
    @test BonitoWorker.relay_request(relay, evaltoken * " eval bridge-1")[3]["prefix"] == "bridge-1"
    @test BonitoWorker.relay_request(relay, evaltoken) === nothing
    @test BonitoWorker.relay_request(relay, control * " eval bridge-1") === nothing
    @test BonitoWorker.relay_request(relay, evaltoken * " eval ") === nothing
    close(relay)
    @test BonitoWorker.relay_request(relay, control) === nothing   # a closed relay honours nothing
    BonitoWorker.WorkerLink.kill!(link, "done")
end

@testset "no agent-side child inherits the worker's credentials" begin
    # An env-driven worker (worker_standalone.jl) holds both in its own ENV.
    withenv("BONITOAGENTS_WORKER_SECRET" => "not-for-agents",
            "BONITOAGENTS_SERVER_URL" => "http://server.example:8038",
            "BONITOAGENTS_PUBLIC_URL" => "https://agents.example",
            "BT_INHERITED_PROBE" => "kept") do
        env = BonitoWorker.provider_env(BonitoWorker.AgentProviders.find_provider("ClaudeCode"),
                                        Dict("BONITOAGENTS_PROJECT_ID" => "chat-1"))
        for k in ("BONITOAGENTS_WORKER_SECRET", "BONITOAGENTS_SERVER_URL", "BONITOAGENTS_PUBLIC_URL")
            @test !haskey(env, k)
        end
        @test !any(v -> occursin("not-for-agents", v), values(env))
        @test env["BT_INHERITED_PROBE"] == "kept"
        @test env["BONITOAGENTS_PROJECT_ID"] == "chat-1"
        @test env[BonitoWorker.AGENT_OWNER_ENV] == BonitoWorker.load_or_generate_worker_id()
    end
end
