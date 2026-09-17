# Real-agent integration test for BonitoWorker.
#
# Why this exists: every Windows regression we've hit (.cmd shim resolution,
# Node version mismatch, EACCES on worker.log, path-in-cwd corruption,
# "ACP connection closed") lives in the path between "server says
# open_session" and "claude-agent-acp emits its first ACP frame." The
# existing electron suite mocks the entire ACP transport, so none of those
# bugs are observable there. This test exercises the real path:
#
#   1. Stand up a minimal HTTP+WS server in this process, just /worker-ws +
#      /worker-acp routes — no Bonito, no BonitoAgents dep.
#   2. Spawn BonitoWorker as a real subprocess via worker_standalone.jl.
#   3. Wait for the worker's hello on /worker-ws, ack it.
#   4. Send `open_session` over the control WS.
#   5. The worker spawns the real `claude-agent-acp` and dials /worker-acp.
#   6. Send an ACP `initialize` request through the relay; assert we
#      receive a well-formed result. That's the proof of life — it means
#      the .cmd resolved, Node parsed the agent JS, the agent process is
#      alive, and the bidirectional WS↔stdio relay works.
#
# We deliberately don't send a `session/prompt` — that would burn Claude
# API quota for no extra coverage of the bug classes we're targeting.
#
# Skipped automatically when `claude-agent-acp` isn't on PATH (CI without
# Claude Code installed).

using Test
using HTTP, HTTP.WebSockets, JSON, Sockets, Dates
using BonitoWorker
const BW = BonitoWorker

# Bounded receive — fail loudly instead of hanging the suite forever.
function take_or_timeout(ch::Channel, timeout_s::Real, what::AbstractString)
    result = Ref{Any}(nothing)
    t = @async (result[] = take!(ch))
    if timedwait(() -> istaskdone(t), Float64(timeout_s); pollint = 0.05) === :timed_out
        error("timed out waiting for $what after $(timeout_s)s")
    end
    return result[]
end

# Grab a free local port by binding ephemerally and releasing.
function free_port()
    s = listen(IPv4(0), 0)
    p = Sockets.getsockname(s)[2]
    close(s)
    return Int(p)
end

@testset "real-agent integration" begin
    agent_path = BW.which_executable("claude-agent-acp")
    if agent_path === nothing
        @info "skipping: claude-agent-acp not on PATH (install Claude Code to run)"
        return
    end

    port          = free_port()
    secret        = "test-" * string(rand(UInt64), base = 16, pad = 16)
    sid           = "sess-" * string(rand(UInt64), base = 16, pad = 16)
    projects_root = mktempdir(prefix = "bw_test_")
    server_url    = "http://127.0.0.1:$port"

    # The WS handlers OWN their WebSocket for the connection's lifetime —
    # HTTP.WebSockets.listen! closes the WS when the handler returns. So
    # cross-task coordination goes through channels: the test driver pushes
    # outgoing frames into `ctrl_send` and reads incoming results from the
    # other channels.
    hello_ch  = Channel{Dict{String,Any}}(1)
    ctrl_send = Channel{Any}(8)             # JSON-encodable dicts to forward to the worker
    acp_hdr   = Channel{Dict{String,Any}}(1)
    acp_init  = Channel{Dict{String,Any}}(1)
    done      = Channel{Nothing}(1)         # closed by the driver to wind down handlers

    # `handshake_request`, not `request`: HTTP v2 renamed the field. Reading
    # `ws.request` here threw on the handler's FIRST line, so the server
    # answered 1011 before anything ran and the worker just saw
    # "control session crashed" with no clue why.
    function ws_handler(ws::HTTP.WebSockets.WebSocket)
        path = ws.handshake_request.target
        if path == "/worker-ws"
            try
                hello = BW.decode_control(WebSockets.receive(ws))
                put!(hello_ch, Dict{String,Any}(hello))
                WebSockets.send(ws, BW.MsgPack.pack(Dict("ok" => true)))
                # Separate sender + receiver tasks against the same WS:
                # HTTP.WebSockets allows concurrent send/receive from
                # different tasks (just not two senders or two receivers).
                sender = Base.errormonitor(@async try
                    for msg in ctrl_send
                        WebSockets.send(ws, BW.MsgPack.pack(msg))
                    end
                catch e
                    e isa WebSockets.WebSocketError && return
                    @warn "ctrl sender error" exception=e
                end)
                try
                    for _ in ws
                        # Worker may send pongs / status frames; we just drain.
                    end
                finally
                    close(ctrl_send)
                    wait(sender)
                end
            catch e
                e isa WebSockets.WebSocketError && return
                @warn "control WS handler error" exception=e
            end
        elseif path == "/worker-acp"
            try
                hdr = JSON.parse(String(WebSockets.receive(ws)))
                put!(acp_hdr, Dict{String,Any}(hdr))
                WebSockets.send(ws, JSON.json(Dict("ok" => true)))
                # We're the ACP *client*; send `initialize` and read the
                # response back through the relay.
                init_req = Dict(
                    "jsonrpc" => "2.0",
                    "id"      => 1,
                    "method"  => "initialize",
                    "params"  => Dict(
                        "protocolVersion" => 1,
                        "clientCapabilities" => Dict("fs" => Dict("readTextFile" => false,
                                                                   "writeTextFile" => false)),
                    ),
                )
                WebSockets.send(ws, JSON.json(init_req))
                for frame in ws
                    msg = JSON.parse(String(frame))
                    if get(msg, "id", nothing) == 1 && haskey(msg, "result")
                        put!(acp_init, Dict{String,Any}(msg))
                        return
                    end
                end
            catch e
                e isa WebSockets.WebSocketError && return
                @warn "ACP WS handler error" exception=e
            end
        else
            @warn "unknown WS path requested" path
        end
    end

    println("[real-agent] starting WS server on port ", port)
    # IMPORTANT: must call ws_handler SYNCHRONOUSLY here. HTTP.WebSockets.listen!
    # closes the WS as soon as the do-block returns, so wrapping in @async
    # would drop the connection immediately.
    server = WebSockets.listen!("127.0.0.1", port) do ws
        ws_handler(ws)
    end

    # ── Spawn BonitoWorker subprocess ────────────────────────────────────────
    julia_bin   = joinpath(Sys.BINDIR::String, Base.julia_exename())
    pkg_root    = normpath(joinpath(@__DIR__, ".."))
    standalone  = joinpath(pkg_root, "src", "worker_standalone.jl")
    # Spawn against the ACTIVE test env, not `pkg_root`. BonitoWorker's own
    # Project.toml is a dependency DECLARATION with no Manifest, so a subprocess
    # pointed at it can't resolve HTTP. That used to work only because Pkg's
    # sandbox leaked JULIA_LOAD_PATH through `copy(ENV)`; once test/Project.toml
    # existed the leak went away and the worker died with "Package HTTP ... does
    # not seem to be installed" before it could send hello. The test env is a
    # real instantiated env that contains BonitoWorker, so use that.
    worker_env  = dirname(Base.active_project())
    env         = copy(ENV)
    env["BONITOAGENTS_WORKER_SECRET"] = secret
    env["BONITOAGENTS_SERVER_URL"]    = server_url
    env["BONITOAGENTS_PROJECTS_ROOT"] = projects_root

    # The kernel-level backstop, and the only one that holds when our own
    # teardown doesn't: `connect_and_serve` arms PR_SET_PDEATHSIG with this pid,
    # so a worker still alive when THIS process exits is reaped by the kernel.
    # A worker that outlives the suite is ~500 MB, and nothing else reaps it —
    # it carries a test secret and a temp projects root nobody looks at again.
    env["BONITOAGENTS_DIE_WITH_PARENT"] = string(getpid())

    worker_log  = tempname() * ".log"
    worker_cmd  = Cmd(`$julia_bin --project=$worker_env --startup-file=no $standalone`)
    println("[real-agent] spawning worker subprocess; log -> ", worker_log)
    # `detach` puts the worker in its own process group, like a real install —
    # which is also what makes the group signal in `kill_proc!` OURS to send
    # (it refuses to signal the group the test runner itself sits in).
    worker_proc = run(pipeline(detach(setenv(worker_cmd, env));
                                stdout = worker_log, stderr = worker_log);
                       wait = false)
    println("[real-agent] worker pid=", getpid(worker_proc))

    function show_log()
        try
            "--- worker log ---\n" * read(worker_log, String)
        catch; "(no log)" end
    end

    try
        # ── Step 1: hello frame from worker on /worker-ws ─────────────────────
        println("[real-agent] waiting up to 60s for hello…")
        hello = try
            take_or_timeout(hello_ch, 60.0, "worker hello on /worker-ws")
        catch e
            @error "no hello received" exception=e log=show_log()
            rethrow()
        end
        println("[real-agent] got hello: name=", get(hello, "name", "?"),
                "  worker_id=", get(hello, "worker_id", "?"))
        @test get(hello, "type", "") == "hello"
        @test get(hello, "secret", "") == secret
        @test !isempty(get(hello, "worker_id", ""))

        # ── Step 2: server sends open_session, worker spawns agent ────────────
        open_msg = Dict(
            "type" => "open_session",
            "sid"  => sid,
            "cwd"  => projects_root,
            "env"  => Dict(),
        )
        println("[real-agent] sending open_session sid=", sid)
        put!(ctrl_send, open_msg)

        # ── Step 3: agent process dials back on /worker-acp ──────────────────
        # This is the headline assertion. If it times out, the agent failed
        # to spawn — most likely Node version, .cmd resolution, or invalid cwd.
        println("[real-agent] waiting for /worker-acp dial-back…")
        hdr = try
            take_or_timeout(acp_hdr, 30.0, "worker /worker-acp dial-back")
        catch e
            @error "worker never connected /worker-acp (agent spawn likely failed)" exception=e log=show_log()
            rethrow()
        end
        println("[real-agent] /worker-acp connected (sid=", get(hdr, "sid", "?"), ")")
        @test get(hdr, "secret", "") == secret
        @test get(hdr, "sid", "")    == sid

        # ── Step 4: ACP initialize round-trip through the relay ──────────────
        println("[real-agent] waiting for ACP initialize response from agent…")
        init_resp = try
            take_or_timeout(acp_init, 30.0, "ACP initialize response from agent")
        catch e
            @error "agent didn't respond to initialize (Node version? syntax error?)" exception=e log=show_log()
            rethrow()
        end
        println("[real-agent] got initialize response ✓")
        @test get(init_resp, "jsonrpc", "") == "2.0"
        @test get(init_resp, "id", 0) == 1
        @test haskey(init_resp, "result")
        result = init_resp["result"]
        @test result isa AbstractDict
        # Agent advertises its protocol version in the result; we don't pin
        # the exact value, just confirm the field's present and shaped right.
        if haskey(result, "protocolVersion")
            @test result["protocolVersion"] isa Number
        end

    finally
        # Worker FIRST, then the server. The other order put the kill behind
        # `close(server)`, which drains open connections before it returns — and
        # the connection it was draining was the control WS of the worker we
        # hadn't killed yet. Anything that made that close slow or throw (it was
        # wrapped in a bare `catch end`, so a throw was silent) skipped the kill
        # entirely and left a ~500 MB worker behind.
        #
        # `kill_proc!` is the teardown the worker uses on its own agents: SIGTERM,
        # then SIGKILL for a process too early in its life to have a handler,
        # then the process group.
        BW.kill_proc!(worker_proc)
        @test timedwait(() -> !process_running(worker_proc), 10.0) === :ok
        # Bounded: HTTP's graceful close can still block on Windows. A socket
        # leaked by a process that is about to exit is harmless; a wedged runner
        # is not.
        closer = @async close(server)
        timedwait(() -> istaskdone(closer), 5.0)
        rm(projects_root; recursive = true, force = true)
        # Keep the worker log on failure for postmortem; otherwise delete.
        ts = Test.get_testset()
        keep_log = ts isa Test.DefaultTestSet && ts.anynonpass
        if keep_log
            @info "worker log retained for postmortem" path=worker_log
        else
            rm(worker_log; force = true)
        end
    end
end
