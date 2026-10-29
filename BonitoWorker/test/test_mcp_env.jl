using Test, BonitoWorker
import JSON

# Exercise the actual channel → stdio relay, including newline framing. The sink
# is a file because the relay closes stdin on EOF, just as it does in production.
mutable struct MCPEnvFrames
    frames::Vector{String}
end
BonitoWorker.WebSockets.isclosed(ws::MCPEnvFrames) = isempty(ws.frames)
BonitoWorker.WebSockets.receive(ws::MCPEnvFrames) = popfirst!(ws.frames)

@testset "RomeoDB is enabled without worker configuration" begin
    options = (; command = "/worker/julia", project = "/worker/env", index = "/worker/index")
    server = only(BonitoWorker.worker_mcp_servers(Dict(); options...))
    @test server.name == "btromeodb"
    @test server.command == "/worker/julia"
    @test server.args == ["--project=/worker/env", "--startup-file=no", "--threads=2", "-e",
                          "using RomeoDB; RomeoDB.serve(ARGS[1])", "/worker/index"]
    @test isempty(server.env)
    @test isempty(BonitoWorker.worker_mcp_servers(
        Dict("mcp_servers" => Dict("btromeodb" => Dict("enabled" => false))); options...))
    override = Dict("command" => "custom", "args" => ["--project=/embedding-env"])
    customized = BonitoWorker.worker_mcp_servers(Dict("mcp_servers" => Dict("btromeodb" => override)); options...)
    @test only(customized).command == "custom"
    @test only(customized).args == ["--project=/embedding-env"]
    defaults = BonitoWorker.worker_mcp_servers(Dict("mcp_servers" => Dict("extra" => Dict("command" => "extra"))); options...)
    @test sort([s.name for s in defaults]) == ["btromeodb", "extra"]
    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir, "BONITOAGENTS_MCP_CONFIG" => nothing) do
            # The desktop/precompile entry point constructs WorkerConfig directly.
            c = BonitoWorker.WorkerConfig(; server_url = "http://test", worker_id = "test", name = "test",
                mcp_command = "/worker/julia", mcp_arguments = String[], projects_root = dir)
            @test only(c.mcp_servers).name == "btromeodb"
            @test only(c.mcp_servers).command == "/worker/julia"
        end
    end
    target = Dict("repo" => "https://example.test/BonitoAgents.jl", "rev" => "main", "source_id" => "exact-sha",
                  "bonito_url" => "https://example.test/Bonito.jl", "bonito_rev" => "main")
    @test isempty(BonitoWorker.missing_worker_packages(Dict(), ["RomeoDB"]))
    install = only(BonitoWorker.missing_worker_packages(Dict("update_spec" => target), String[]))
    @test install.name == "RomeoDB"
    @test install.rev == "exact-sha"
    @test install.subdir == "RomeoDB"
    @test_throws ErrorException BonitoWorker.missing_worker_packages(Dict(), String[])
end

@testset "worker-local MCP servers reach every ACP session entry point" begin
    config = Dict("mcp_servers" => Dict(
        "btromeodb" => Dict("command" => "/worker/julia", "args" => ["--project=/worker/RomeoDB"],
                          "env" => Dict("JULIA_GLFW_PLATFORM" => "null")),
        "disabled" => Dict("enabled" => false)))
    configured = BonitoWorker.configured_mcp_servers(config)
    @test length(configured) == 1
    @test isempty(BonitoWorker.configured_mcp_servers(Dict()))
    @test_throws ArgumentError BonitoWorker.configured_mcp_servers(
        Dict("mcp_servers" => Dict("btworker" => Dict("command" => "julia"))))
    @test_throws ArgumentError BonitoWorker.configured_mcp_servers(
        Dict("mcp_servers" => Dict("bad" => Dict("command" => " "))))
    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            path = BonitoWorker.write_config!(; server_url = "http://test", name = "test",
                mcp_servers = config["mcp_servers"])
            BonitoWorker.write_config!(; server_url = "http://test", name = "test")
            @test JSON.parsefile(path)["mcp_servers"] == config["mcp_servers"]
        end
    end
    link = BonitoWorker.WorkerLink.Link(:client)
    relay = BonitoWorker.start_mcp_relay(link)
    try
        for method in ("session/new", "session/load", "session/fork", "session/resume")
            msg = Dict("id" => 8, "method" => method, "params" => Dict("cwd" => "/project"))
            mktemp() do path, io
                BonitoWorker.relay_ws_to_proc(MCPEnvFrames([JSON.json(msg)]), (; in = io), relay, "owner", configured)
                out = JSON.parse(read(path, String))
                server = only(out["params"]["mcpServers"])
                @test server["name"] == "btromeodb"
                @test server["command"] == "/worker/julia"
                @test server["args"] == ["--project=/worker/RomeoDB"]
                @test server["env"] == [Dict("name" => "JULIA_GLFW_PLATFORM", "value" => "null")]
                @test out["params"]["cwd"] == "/project"
            end
        end
        duplicate = JSON.json(Dict("method" => "session/new", "params" =>
            Dict("mcpServers" => [Dict("name" => "btromeodb")])) )
        @test_throws ErrorException BonitoWorker.inject_mcp_grant(duplicate, relay, "owner", configured)
        prompt = JSON.json(Dict("method" => "session/prompt", "params" => Dict()))
        @test BonitoWorker.inject_mcp_grant(prompt, relay, "owner", configured) == prompt
        mktemp() do path, io
            write(io, JSON.json(config)); flush(io)
            withenv("BONITOAGENTS_MCP_CONFIG" => path) do
                @test only(BonitoWorker.configured_mcp_servers()).name == "btromeodb"
            end
        end
    finally
        close(relay)
        BonitoWorker.WorkerLink.kill!(link, "done")
    end
end

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
                                               "BONITOAGENTS_PROGRESS_ADDR", "BONITOAGENTS_PROGRESS_TOKEN",
                                               "BONITOAGENTS_PROJECT_ID", "BONITOAGENTS_VALUES_ADDR"]
            @test startswith(env["BONITOAGENTS_CONTROL_URL"], "ws://127.0.0.1:")
            @test startswith(env["BONITOAGENTS_VALUES_ADDR"], "127.0.0.1:")
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
    progress = env["BONITOAGENTS_PROGRESS_TOKEN"]
    @test BonitoWorker.relay_request(relay,progress)[3]["kind"] == "progress"
    @test BonitoWorker.relay_request(relay,progress * " eval bridge") === nothing
    @test BonitoWorker.relay_request(relay,progress * " values") === nothing
    restarted = BonitoWorker.mcp_relay_env(relay,"test-chat";owner="replacement")
    @test restarted["BONITOAGENTS_PROGRESS_TOKEN"] == progress
    otherchat = BonitoWorker.mcp_relay_env(relay,"other-chat";owner="other")
    @test otherchat["BONITOAGENTS_PROGRESS_TOKEN"] != progress
    BonitoWorker.revoke_mcp_grants!(relay,"roles")
    @test BonitoWorker.relay_request(relay,progress) !== nothing
    # Renew the agent grants for the remaining role checks.
    env = BonitoWorker.mcp_relay_env(relay,"test-chat";owner="roles-new")
    control,evaltoken=env["BONITOAGENTS_CONTROL_TOKEN"],env["BONITOAGENTS_EVAL_TOKEN"]
    # Value exchanges: the chat's session asks, the other side answers a pair.
    @test BonitoWorker.relay_request(relay, evaltoken * " values")[3] ==
          Dict{String,Any}("kind" => "values", "project_id" => "test-chat", "host" => false)
    @test BonitoWorker.relay_request(relay, evaltoken * " values p1")[3]["pair"] == "p1"
    @test BonitoWorker.relay_request(relay, control * " values") === nothing
    @test BonitoWorker.relay_request(relay, evaltoken * " values ") === nothing
    @test BonitoWorker.relay_request(relay, evaltoken * " values p1 p2") === nothing
    close(relay)
    @test BonitoWorker.relay_request(relay, control) === nothing   # a closed relay honours nothing
    BonitoWorker.WorkerLink.kill!(link, "done")
end

@testset "no agent-side child inherits the worker's credentials" begin
    # An env-driven worker (worker_standalone.jl) holds both in its own ENV.
    withenv("BONITOAGENTS_WORKER_CREDENTIAL" => "not-for-agents",
            "BONITOAGENTS_SERVER_URL" => "http://server.example:8038",
            "BONITOAGENTS_PUBLIC_URL" => "https://agents.example",
            "BT_INHERITED_PROBE" => "kept") do
        env = BonitoWorker.provider_env(BonitoWorker.AgentProviders.find_provider("ClaudeCode"),
                                        Dict("BONITOAGENTS_PROJECT_ID" => "chat-1"))
        for k in ("BONITOAGENTS_WORKER_CREDENTIAL", "BONITOAGENTS_SERVER_URL", "BONITOAGENTS_PUBLIC_URL")
            @test !haskey(env, k)
        end
        @test !any(v -> occursin("not-for-agents", v), values(env))
        @test env["BT_INHERITED_PROBE"] == "kept"
        @test env["BONITOAGENTS_PROJECT_ID"] == "chat-1"
        @test env[BonitoWorker.AGENT_OWNER_ENV] == BonitoWorker.load_or_generate_worker_id()
    end
end

# The eval workers' value exchanges reach the relay over plain TCP (their
# project has no websocket client). Same grants, same channel, same answers.
@testset "the relay's TCP clients" begin
    import Sockets
    WL = BonitoWorker.WorkerLink
    MP = BonitoWorker.MsgPack
    ct, st = WL.memory_pair()
    headers = Channel{Dict{String,Any}}(8)
    serverside = Threads.@spawn begin
        h = WL.read_hello(st)
        server = WL.Link(:server; id = h.link_id, on_open = ch -> begin
            header = BonitoWorker.decode_control(WL.header(ch))
            put!(headers, header)
            if get(header, "pair", "") == "refuse-me"
                WL.abort(ch, "no value exchange is waiting for this session")
                return
            end
            BonitoWorker.send_control(ch, Dict("ok" => true))
            for msg in ch                                  # an echo
                BonitoWorker.WebSockets.send(ch, msg)
            end
            close(ch)
        end)
        WL.welcome!(server, st, h, UInt8[]; resumed = false)
        server
    end
    link = WL.Link(:client)
    WL.connect!(link, ct, UInt8[])
    server_link = fetch(serverside)
    relay = BonitoWorker.start_mcp_relay(link)
    env = BonitoWorker.mcp_relay_env(relay, "tcp-chat"; owner = "tcp")
    host, port = split(env["BONITOAGENTS_VALUES_ADDR"], ':')
    dial(handshake) = begin
        s = Sockets.connect(String(host), parse(Int, port))
        BonitoWorker.send_local(s, handshake)
        s
    end

    s = dial(env["BONITOAGENTS_EVAL_TOKEN"] * " values")
    @test BonitoWorker.receive_local(s) == "ok"
    @test take!(headers) == Dict{String,Any}("kind" => "values", "project_id" => "tcp-chat", "host" => false)
    BonitoWorker.send_local(s, "open\nworker-b\n")
    @test BonitoWorker.receive_local(s) == "open\nworker-b\n"
    big = rand(UInt8, 3 * 1024 * 1024)                     # binary stays binary, whole
    BonitoWorker.send_local(s, big)
    @test BonitoWorker.receive_local(s) == big
    close(s)

    # The server's refusal reaches the client as text, then the connection ends.
    s = dial(env["BONITOAGENTS_EVAL_TOKEN"] * " values refuse-me")
    @test BonitoWorker.receive_local(s) == "refused\nno value exchange is waiting for this session"
    @test take!(headers)["pair"] == "refuse-me"
    @test eof(s)
    # An unknown token never reaches the server.
    s = dial("not-a-token values")
    @test BonitoWorker.receive_local(s) == "refused\nunknown token"
    @test eof(s)
    @test !isready(headers)
    # A length over the limit is refused before anything is allocated for it.
    s = Sockets.connect(String(host), parse(Int, port))
    write(s, UInt8[0x01, 0xff, 0xff, 0xff, 0x7f])
    @test eof(s)

    close(relay)
    @test_throws Base.IOError Sockets.connect(String(host), parse(Int, port))
    WL.kill!(link, "done")
    WL.kill!(server_link, "done")
end
