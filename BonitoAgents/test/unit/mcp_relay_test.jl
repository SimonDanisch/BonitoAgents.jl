@testitem "unit:mcp_relay" tags = [:unit] begin
    using Test, Dates, JSON, HTTP
    import BonitoAgents as BT, BonitoWorker as BW

    # In-memory stand-ins for the ONE worker/server wire. The localhost socket
    # and MCP subprocess are real. The browser suite additionally exercises the
    # real worker daemon, ACP launch, and a second worker's eval subprocess.
    struct RelayTestWire
        receive::Function
    end
    HTTP.WebSockets.send(w::RelayTestWire, frame) = w.receive(BW.decode_control(frame))

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "unused")
    p = BT.ProjectInfo("relay-chat", "relay", "worker-a", mktempdir(), mktempdir(), now(UTC))
    p.dev_mode = true
    state.projects[][p.id] = p
    channels = Dict{String,Any}()
    relay_ref = Ref{Any}(nothing)
    hold_requests = Ref(false)
    held = Channel{Nothing}(1)
    server_wire = RelayTestWire(cmd -> BW.handle_mcp_relay_frame!(relay_ref[], cmd))
    worker_wire = RelayTestWire() do cmd
        if hold_requests[] && get(cmd, "type", "") == "mcp_frame" &&
                get(JSON.parse(cmd["frame"]), "op", "") == "remote_workers"
            put!(held, nothing)
        else
            BT.handle_worker_mcp!(state, "worker-a", server_wire, channels, cmd)
        end
    end
    state.worker_control_ws["worker-a"] = server_wire
    relay = BW.start_mcp_relay(worker_wire)
    relay_ref[] = relay
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
    try
        @testset "filtered MCP subprocess needs no server coordinates" begin
            cfg = Dict("name" => "btworker", "command" => first(Base.julia_cmd().exec),
                "args" => ["--startup-file=no", "--project=$(dirname(Base.active_project()))", "-e",
                           "using BonitoMCP; BonitoMCP.run_stdio()"],
                "env" => [Dict("name" => "BONITOAGENTS_PROJECT_ID", "value" => p.id),
                          Dict("name" => "BONITOAGENTS_DEV_TOOLS", "value" => "1")])
            # No SERVER_URL and no server secret, even in the explicit config.
            launch = JSON.json(Dict("method" => "session/new", "params" => Dict("mcpServers" => [cfg])))
            configured = JSON.parse(BW.inject_mcp_server_url(launch, ""; mcp_relay = relay, owner = "agent-1"))
            entry = only(configured["params"]["mcpServers"])
            env = Dict(k => v for (k, v) in ENV if !startswith(k, "BONITOAGENTS_"))
            merge!(env, Dict(e["name"] => e["value"] for e in entry["env"]))
            @test !haskey(env, "BONITOAGENTS_SERVER_URL")
            @test !haskey(env, "BONITOAGENTS_SECRET")
            proc[] = open(detach(Cmd(Cmd(String[entry["command"]; entry["args"]]); env)), "r+")
            request(1, "initialize", Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(),
                "clientInfo" => Dict("name" => "relay-regression", "version" => "1")))
            listing = request(2, "tools/call", Dict("name" => "bt_julia_list_sessions", "arguments" => Dict()))
            text = join(get(c, "text", "") for c in listing["content"])
            @test occursin("remote julia is OFF", text)
            @test BT.mcp_ctrl_for(state, p.id) isa BT.WorkerMCPChannel
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
            inspected = request(8, "tools/call", Dict("name" => "bt_dev_inspect",
                "arguments" => Dict("section" => "projects", "project_id" => p.id)))
            @test inspected["isError"] === false
            @test occursin(p.id, only(inspected["content"])["text"])
            # Only this grant can authenticate; an unrelated local process
            # cannot claim a project by putting its id in a frame.
            @test length(channels) == 1
            HTTP.WebSockets.open(env["BONITOAGENTS_CONTROL_URL"]) do ws
                HTTP.WebSockets.send(ws, "incorrect-token")
                try HTTP.WebSockets.receive(ws) catch end
            end
            @test length(channels) == 1
        end

        @testset "disconnect and replacement do not strand or misroute RPCs" begin
            old = BT.mcp_ctrl_for(state, p.id)
            rid, pending = BT.register_rpc!(state)
            push!(old.pending, rid)
            # Closing fails this channel's waiter immediately.
            BT.close_mcp_channel!(old; notify_worker = false)
            @test isready(pending)
            @test take!(pending) isa Exception
            @test isempty(old.pending)
            @test BT.mcp_ctrl_for(state, p.id) === nothing
            BT.handle_worker_mcp!(state, "worker-a", server_wire, channels,
                Dict("type" => "mcp_open", "channel" => "replacement", "project_id" => p.id))
            new = BT.mcp_ctrl_for(state, p.id)
            @test new !== old
            @test_throws BT.WorkerUnreachableError BT.host_rpc(state, new, "sessions", Dict(); timeout = 0.1)
            @test isempty(new.pending)
            BT.close_mcp_channel!(old; notify_worker = false)
            @test BT.mcp_ctrl_for(state, p.id) === new
            # A reply on another channel cannot resolve new's pending request.
            other = BT.ProjectInfo("other-chat", "other", "worker-a", p.server_path,
                                   p.worker_path, now(UTC))
            state.projects[][other.id] = other
            BT.handle_worker_mcp!(state, "worker-a", server_wire, channels,
                Dict("type" => "mcp_open", "channel" => "other-channel", "project_id" => other.id))
            rid2, waiting = BT.register_rpc!(state)
            push!(new.pending, rid2)
            BT.handle_worker_mcp!(state, "worker-a", server_wire, channels,
                Dict("type" => "mcp_frame", "channel" => "other-channel",
                     "frame" => JSON.json(Dict("request_id" => rid2, "result" => "wrong"))))
            @test !isready(waiting)
            BT.close_mcp_channel!(channels["other-channel"]; notify_worker = false)
            BT.close_mcp_channel!(new; notify_worker = false)
            @test isready(waiting)
            @test take!(waiting) isa Exception
            BT.unregister_rpc!(state, rid)
            BT.unregister_rpc!(state, rid2)
        end
        @testset "MCP caller is released when its worker connection disappears" begin
            hold_requests[] = true
            result = Channel{Any}(1)
            @async put!(result, try request(7, "tools/call",
                Dict("name" => "bt_julia_list_sessions", "arguments" => Dict())) catch e; e end)
            @test timedwait(() -> isready(held), 10.0) === :ok
            close(relay)
            @test timedwait(() -> isready(result), 5.0) === :ok
            isready(result) || error("disconnected MCP call did not finish")
            reply = take!(result)
            reply isa Exception && throw(reply)
            @test occursin("connection closed", join(get(c, "text", "") for c in reply["content"]))
        end
        BW.revoke_mcp_grants!(relay, "agent-1")
        @test isempty(relay.grants)

        @testset "slow local readers have a bounded queue" begin
            peer = BW.MCPRelayPeer(nothing, "slow", Union{String,Nothing}[], 0, Threads.Condition(), false)
            relay.peers["slow"] = peer
            for _ in 1:128
                BW.handle_mcp_relay_frame!(relay, Dict("type" => "mcp_frame", "channel" => "slow", "frame" => "x"))
            end
            @test !peer.closed
            BW.handle_mcp_relay_frame!(relay, Dict("type" => "mcp_frame", "channel" => "slow", "frame" => "x"))
            @test peer.closed
            @test isempty(peer.queue)
            @test peer.bytes == 0
        end
    finally
        proc[] === nothing || (BW.kill_proc!(proc[]); wait(proc[]))
        close(relay)
        foreach(ch -> BT.close_mcp_channel!(ch; notify_worker = false), values(channels))
        rm(state.state_dir; recursive = true, force = true)
        rm(state.working_dir; recursive = true, force = true)
    end
    @test isempty(state.mcp_ctrl)
    @test isempty(state.pending_rpcs)
    @test isempty(relay.peers)
end
