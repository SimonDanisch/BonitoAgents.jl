@testitem "unit:mcp_relay" tags = [:unit] setup = [LinkPair] begin
    using Test, Dates, JSON, HTTP
    import BonitoAgents as BT, BonitoWorker as BW, WorkerLink, Bonito

    # The ONE worker/server connection is a real link over an in-memory
    # transport; the worker's relay, its localhost socket and the MCP subprocess
    # are real too. The browser suite additionally exercises the real worker
    # daemon, ACP launch, and a second worker's eval subprocess.
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "unused")
    p = BT.ProjectInfo("relay-chat", "relay", "worker-a", mktempdir(), mktempdir(), now(UTC))
    p.dev_mode = true
    state.projects[][p.id] = p
    # The eval bridge proxies assets through the dashboard's server.
    state.srv = Bonito.Server(Bonito.App(() -> Bonito.DOM.div("x")), "127.0.0.1", 0)
    # While `hold[]`, a channel the worker opens is accepted and then parked
    # here instead of served: a server that takes the call and never answers.
    hold = Ref(false)
    held = Channel{WorkerLink.LinkChannel}(Inf)
    server_link, worker_link = link_pair(; on_open = ch -> hold[] ? (BT.accept_channel(ch); put!(held, ch)) :
                                                     BT.accept_worker_channel(state, "worker-a", ch))
    state.worker_links["worker-a"] = server_link
    relay = BW.start_mcp_relay(worker_link)
    proc = Ref{Any}(nothing)
    function request(id, method, params)
        println(proc[], JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)))
        flush(proc[])
        result = Channel{Any}(1)
        @async put!(result, try JSON.parse(readline(proc[])) catch e; e end)
        timedwait(() -> isready(result), 60.0) === :ok || error("MCP subprocess did not reply")
        reply = take!(result)
        reply isa Exception && throw(reply)
        @test reply["id"] == id
        return reply["result"]
    end
    # A channel as the relay opens it, for a chat, straight from the worker's end.
    open_mcp(project_id) = WorkerLink.open_channel(worker_link, BW.MsgPack.pack(Dict(
        "kind" => "mcp", "project_id" => project_id, "host" => false)))
    try
        @testset "the MCP process needs no server coordinates" begin
            cfg = Dict("name" => "btworker", "command" => first(Base.julia_cmd().exec),
                "args" => ["--startup-file=no", "--project=$(dirname(Base.active_project()))", "-e",
                           "using BonitoMCP; BonitoMCP.run_stdio()"],
                "env" => [Dict("name" => "BONITOAGENTS_PROJECT_ID", "value" => p.id),
                          Dict("name" => "BONITOAGENTS_DEV_TOOLS", "value" => "1")])
            launch = JSON.json(Dict("method" => "session/new", "params" => Dict("mcpServers" => [cfg])))
            configured = JSON.parse(BW.inject_mcp_grant(launch, relay, "agent-1"))
            entry = only(configured["params"]["mcpServers"])
            env = Dict(k => v for (k, v) in ENV if !startswith(k, "BONITOAGENTS_"))
            merge!(env, Dict(e["name"] => e["value"] for e in entry["env"]))
            # Only the relay's address and a grant: no server URL, no secret.
            @test sort([k for k in keys(env) if startswith(k, "BONITOAGENTS_")]) ==
                  ["BONITOAGENTS_CONTROL_TOKEN", "BONITOAGENTS_CONTROL_URL",
                   "BONITOAGENTS_DEV_TOOLS", "BONITOAGENTS_EVAL_TOKEN", "BONITOAGENTS_PROJECT_ID"]
            proc[] = open(detach(Cmd(Cmd(String[entry["command"]; entry["args"]]); env)), "r+")
            request(1, "initialize", Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(),
                "clientInfo" => Dict("name" => "relay-regression", "version" => "1")))
            listing = request(2, "tools/call", Dict("name" => "bt_julia_list_sessions", "arguments" => Dict()))
            text = join(get(c, "text", "") for c in listing["content"])
            @test occursin("remote julia is OFF", text)
            @test BT.mcp_ctrl_for(state, p.id) isa BT.MCPChannel
            result = request(3, "tools/call", Dict("name" => "bt_julia_eval", "arguments" => Dict(
                "code" => "6 * 7", "worker" => "worker-b")))
            @test result["isError"] === true
            @test occursin("switched OFF", only(result["content"])["text"])
            running = request(4, "tools/call", Dict("name" => "bt_julia_eval", "arguments" => Dict(
                "code" => "println(\"relay-started\"); sleep(60); 42", "timeout" => 0.1)))
            @test running["_meta"]["status"] == "running"
            @test BT.interrupt_project_eval!(state, p.id; timeout = 10.0) == 1
            stopped = request(5, "tools/call", Dict("name" => "bt_julia_continue", "arguments" => Dict()))
            @test stopped["_meta"]["status"] == "completed"
            @test occursin("InterruptException", join(get(c, "text", "") for c in stopped["content"]))
            again = request(6, "tools/call", Dict("name" => "bt_julia_eval", "arguments" => Dict("code" => "21 * 2")))
            @test occursin("42", join(get(c, "text", "") for c in again["content"]))
            # The eval worker runs user code: its environment holds no grant
            # (the MCP process took it out of its own before starting it).
            seen = request(9, "tools/call", Dict("name" => "bt_julia_eval", "arguments" => Dict(
                "code" => "sort([k for k in keys(ENV) if occursin(r\"CONTROL|EVAL_TOKEN\", k)])")))
            @test occursin("String[]", join(get(c, "text", "") for c in seen["content"]))
            # The eval worker's live-render bridge came up through the relay too.
            @test timedwait(() -> BT.eval_bridge_for(state, p.id) !== nothing, 30.0) === :ok
            inspected = request(8, "tools/call", Dict("name" => "bt_dev_inspect",
                "arguments" => Dict("section" => "projects", "project_id" => p.id)))
            @test inspected["isError"] === false
            @test occursin(p.id, only(inspected["content"])["text"])
            # Revoking an owner's grants leaves everyone else's.
            BW.mcp_relay_env(relay, p.id; owner = "agent-2")
            @test length(relay.grants) == 4          # a control and an eval token each
            BW.revoke_mcp_grants!(relay, "agent-2")
            @test sort([(g.owner, g.kind) for g in values(relay.grants)]) ==
                  [("agent-1", "eval"), ("agent-1", "mcp")]
            # Only a token we handed out gets a channel: an unrelated local
            # process cannot claim a chat. The relay hangs up on it, and the
            # server still knows exactly the one MCP channel.
            HTTP.WebSockets.open(env["BONITOAGENTS_CONTROL_URL"]) do ws
                HTTP.WebSockets.send(ws, "incorrect-token")
                @test_throws HTTP.WebSockets.WebSocketError HTTP.WebSockets.receive(ws)
            end
            # The eval workers' token (their process runs user code) cannot
            # open the control channel either.
            HTTP.WebSockets.open(env["BONITOAGENTS_CONTROL_URL"]) do ws
                HTTP.WebSockets.send(ws, env["BONITOAGENTS_EVAL_TOKEN"])
                @test_throws HTTP.WebSockets.WebSocketError HTTP.WebSockets.receive(ws)
            end
            @test collect(keys(state.mcp_ctrl)) == [p.id]
        end

        @testset "a refused channel reaches its local client with the server's reason" begin
            # A grant the worker minted for a chat the server does not give it.
            stray = BW.mcp_relay_env(relay, "no-such-chat"; owner = "stray")
            err = HTTP.WebSockets.open(stray["BONITOAGENTS_CONTROL_URL"]) do ws
                HTTP.WebSockets.send(ws, stray["BONITOAGENTS_CONTROL_TOKEN"])
                try
                    HTTP.WebSockets.receive(ws)
                    nothing
                catch e
                    e
                end
            end
            # Never an "ok": the client does not count this as connected.
            @test err isa HTTP.WebSockets.WebSocketError
            @test occursin("may speak for", err.message.reason)
            @test !haskey(state.mcp_ctrl, "no-such-chat")
            BW.revoke_mcp_grants!(relay, "stray")
        end

        @testset "a worker only speaks for its own chats" begin
            stranger = open_mcp("no-such-chat")
            err = try WorkerLink.WebSockets.receive(stranger); nothing catch e; e end
            @test err isa HTTP.WebSockets.WebSocketError && occursin("may speak for", err.message.reason)
        end

        @testset "MCP caller is released when its worker connection disappears" begin
            # The server stops answering: the MCP process's next channel is
            # accepted but never served.
            hold[] = true
            close(BT.mcp_ctrl_for(state, p.id))
            result = Channel{Any}(1)
            @async put!(result, try request(7, "tools/call",
                Dict("name" => "bt_julia_list_sessions", "arguments" => Dict())) catch e; e end)
            @test timedwait(() -> isready(held), 30.0) === :ok
            close(relay)
            @test timedwait(() -> isready(result), 10.0) === :ok
            isready(result) || error("disconnected MCP call did not finish")
            reply = take!(result)
            reply isa Exception && throw(reply)
            @test occursin("connection closed", join(get(c, "text", "") for c in reply["content"]))
        end

        @testset "disconnect and replacement do not strand or misroute RPCs" begin
            # The relay is closed by now, so the MCP process can't redial and
            # replace the channels this test opens itself.
            hold[] = false
            first_channel = open_mcp(p.id)
            @test timedwait(() -> BT.mcp_ctrl_for(state, p.id) !== nothing, 10.0) === :ok
            old = BT.mcp_ctrl_for(state, p.id)
            rid, pending = BT.register_rpc!(state)
            push!(old.pending, rid)
            # Closing fails this channel's waiter immediately.
            close(old)
            @test isready(pending)
            @test take!(pending) isa Exception
            @test isempty(old.pending)
            @test BT.mcp_ctrl_for(state, p.id) === nothing
            replacement = open_mcp(p.id)
            @test timedwait(() -> (c = BT.mcp_ctrl_for(state, p.id); c !== nothing &&
                                   WorkerLink.channel_id(c.channel) == WorkerLink.channel_id(replacement)), 10.0) === :ok
            new = BT.mcp_ctrl_for(state, p.id)
            @test_throws BT.WorkerUnreachableError BT.host_rpc(state, new, "sessions", Dict(); timeout = 0.1)
            @test isempty(new.pending)
            # A reply on another chat's channel cannot resolve new's request.
            other = BT.ProjectInfo("other-chat", "other", "worker-a", p.server_path, p.worker_path, now(UTC))
            state.projects[][other.id] = other
            other_channel = open_mcp(other.id)
            @test timedwait(() -> BT.mcp_ctrl_for(state, other.id) !== nothing, 10.0) === :ok
            rid2, waiting = BT.register_rpc!(state)
            push!(new.pending, rid2)
            WorkerLink.WebSockets.send(other_channel, JSON.json(Dict("request_id" => rid2, "result" => "wrong")))
            sleep(0.5)
            @test !isready(waiting)
            close(BT.mcp_ctrl_for(state, other.id))
            close(new)
            @test isready(waiting)
            @test take!(waiting) isa Exception
            BT.unregister_rpc!(state, rid)
            BT.unregister_rpc!(state, rid2)
        end

    finally
        proc[] === nothing || (BW.kill_proc!(proc[]); wait(proc[]))
        close(relay)
        foreach(close, collect(values(state.mcp_ctrl)))
        foreach(l -> WorkerLink.kill!(l, "done"), (server_link, worker_link))
        BT.teardown_eval_bridge!(state, p.id)
        close(state.srv)
        rm(state.state_dir; recursive = true, force = true)
        rm(state.working_dir; recursive = true, force = true)
    end
    @test isempty(state.mcp_ctrl)
    @test isempty(state.pending_rpcs)
    @test isempty(relay.peers)
end
