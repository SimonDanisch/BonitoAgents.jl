# Real-agent integration test for BonitoWorker.
#
# Why this exists: every Windows regression we've hit (.cmd shim resolution,
# Node version mismatch, EACCES on worker.log, path-in-cwd corruption,
# "ACP connection closed") lives in the path between "server asks for a
# session" and "claude-agent-acp emits its first ACP frame." The existing
# electron suite mocks the entire ACP transport, so none of those bugs are
# observable there. This test exercises the real path:
#
#   1. Stand up a minimal WS server in this process speaking the worker link
#      (`/w`) — no Bonito, no BonitoAgents dep.
#   2. Spawn BonitoWorker as a real subprocess via worker_standalone.jl.
#   3. Take the worker's hello and welcome it onto a link.
#   4. Open an `acp` channel on that link, as the server does for a session.
#   5. The worker spawns the real `claude-agent-acp` and answers `{ok: true}`.
#   6. Send an ACP `initialize` request through the relay; assert we
#      receive a well-formed result. That's the proof of life — it means
#      the .cmd resolved, Node parsed the agent JS, the agent process is
#      alive, and the bidirectional channel↔stdio relay works.
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
const WL = BW.WorkerLink

# Every live process below `root`, read from /proc (Linux).
function proc_descendants(root::Integer)
    parent = Dict{Int,Int}()
    for entry in readdir("/proc")
        pid = tryparse(Int, entry)
        pid === nothing && continue
        stat = try
            read("/proc/$pid/stat", String)
        catch e
            e isa SystemError || rethrow()   # gone between readdir and read
            continue
        end
        # "pid (comm) state ppid …": comm may hold spaces and parentheses.
        parent[pid] = parse(Int, split(stat[findlast(')', stat) + 1:end])[2])
    end
    found = Int[]
    frontier = [Int(root)]
    while !isempty(frontier)
        p = pop!(frontier)
        for (child, pp) in parent
            pp == p || continue
            push!(found, child)
            push!(frontier, child)
        end
    end
    return found
end

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
    projects_root = mktempdir(prefix = "bw_test_")
    server_url    = "http://127.0.0.1:$port"

    # The handler OWNS its WebSocket for the connection's lifetime —
    # HTTP.WebSockets.listen! closes the WS when the handler returns — so it
    # hands the hello and the link to the test driver through channels and
    # then waits for the connection to end.
    hello_ch = Channel{Dict{String,Any}}(1)
    link_ch  = Channel{Any}(1)

    function ws_handler(ws::HTTP.WebSockets.WebSocket)
        # `handshake_request`, not `request`: HTTP v2 renamed the field.
        path = ws.handshake_request.target
        path == "/w" || (@warn "unknown WS path requested" path; return)
        t = WL.WebSocketTransport(ws)
        h = WL.read_hello(t)
        put!(hello_ch, Dict{String,Any}(BW.decode_control(h.app)))
        link = WL.Link(:server; id = h.link_id)
        WL.welcome!(link, t, h, BW.MsgPack.pack(Dict("ok" => true, "registered_as" => "test"));
                    resumed = false)
        put!(link_ch, link)
        wait(t)
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
        # ── Step 1: the worker's hello on /w ─────────────────────────────────
        println("[real-agent] waiting up to 60s for hello…")
        hello = try
            take_or_timeout(hello_ch, 60.0, "worker hello on /w")
        catch e
            @error "no hello received" exception=e log=show_log()
            rethrow()
        end
        println("[real-agent] got hello: name=", get(hello, "name", "?"),
                "  worker_id=", get(hello, "worker_id", "?"))
        @test get(hello, "secret", "") == secret
        @test !isempty(get(hello, "worker_id", ""))
        link = take_or_timeout(link_ch, 10.0, "the worker link")

        # ── Step 2: open an ACP channel, the worker spawns the agent ──────────
        # This is the headline assertion. If the answer is an abort, the agent
        # failed to spawn — most likely Node version, .cmd resolution, or an
        # invalid cwd — and the abort carries the worker's reason.
        println("[real-agent] opening an acp channel")
        ch = WL.open_channel(link, BW.MsgPack.pack(Dict(
            "kind" => "acp", "project_id" => "real-agent-test", "cwd" => projects_root,
            "mcpServers" => Any[], "provider" => "ClaudeCode")); priority = 1)
        answer = Channel{Any}(1)
        Base.errormonitor(@async put!(answer, try
            WebSockets.receive(ch)
        catch e
            e isa WebSockets.WebSocketError || rethrow()
            e                           # the worker's abort, and its reason
        end))
        reply = take_or_timeout(answer, 30.0, "the worker's answer on the acp channel")
        if reply isa Exception
            @error "worker did not start the agent" exception=reply log=show_log()
            throw(reply)
        end
        @test get(BW.decode_control(reply), "ok", false) === true

        # ── Step 3: ACP initialize round-trip through the relay ──────────────
        acp_init = Channel{Dict{String,Any}}(1)
        Base.errormonitor(@async begin
            WebSockets.send(ch, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id"      => 1,
                "method"  => "initialize",
                "params"  => Dict(
                    "protocolVersion" => 1,
                    "clientCapabilities" => Dict("fs" => Dict("readTextFile" => false,
                                                               "writeTextFile" => false)),
                ),
            )))
            for frame in ch
                msg = JSON.parse(String(frame))
                if get(msg, "id", nothing) == 1 && haskey(msg, "result")
                    put!(acp_init, Dict{String,Any}(msg))
                    break
                end
            end
        end)

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

        # ── Step 4: the agent did not inherit the worker's credentials ───────
        # This worker runs env-driven, so its own ENV holds the secret and the
        # server's URL; the agent (and with it its MCP and eval workers) must not.
        # Everything below the worker process: the agent and what it spawned.
        # (Not by the owner mark: this worker runs with the machine's default
        # worker id, which an installed worker's agents carry too.)
        if Sys.islinux()
            environs = String[]
            for pid in proc_descendants(getpid(worker_proc))
                try
                    push!(environs, read("/proc/$pid/environ", String))
                catch e
                    e isa SystemError || rethrow()   # gone meanwhile
                end
            end
            @test !isempty(environs)
            @test !any(e -> occursin(secret, e), environs)
            @test !any(e -> occursin("BONITOAGENTS_SERVER_URL=", e), environs)
        end

    finally
        # Worker FIRST, then the server. The other order put the kill behind
        # `close(server)`, which drains open connections before it returns — and
        # the connection it was draining was the connection of the worker we
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
