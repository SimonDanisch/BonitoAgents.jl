# Regression tests for the BonitoWorker stability findings (M1, M8, M12, M13).
# No network, no claude-agent-acp, no real git: we exercise the pure pieces that
# were extracted for exactly this (clone_repo_response with an injected clone
# stub, the removed idle watchdog, a refused session over an in-memory link).

using Test
using BonitoWorker
const BW = BonitoWorker

# ── M1: clone onto an existing dir REFUSES and leaves the tree intact ──────────
@testset "M1: clone_repo never deletes a pre-existing dst_path" begin
    mktempdir() do root
        dst = joinpath(root, "existing-project")
        mkpath(dst)
        sentinel = joinpath(dst, "PRECIOUS.txt")
        write(sentinel, "do not delete me")
        nested = joinpath(dst, "src")
        mkpath(nested)
        write(joinpath(nested, "main.jl"), "x = 1")

        clone_called = Ref(false)
        do_clone = (url, d, pr) -> (clone_called[] = true)   # must NOT be reached

        resp = BW.clone_repo_response("req-1", "https://example.com/x.git", dst,
                                       nothing, do_clone)

        # Refused with an error, the clone never ran...
        @test haskey(resp, "error")
        @test occursin("already exists", resp["error"])
        @test clone_called[] == false
        # ...and CRITICALLY the user's tree is fully intact (the data-destroyer bug).
        @test isdir(dst)
        @test isfile(sentinel)
        @test read(sentinel, String) == "do not delete me"
        @test isfile(joinpath(nested, "main.jl"))
    end
end

@testset "M1: malformed pr_number returns an error (no throw, no delete)" begin
    mktempdir() do root
        dst = joinpath(root, "fresh")          # does NOT exist yet
        do_clone = (url, d, pr) -> error("should not be called")
        resp = BW.clone_repo_response("req-2", "https://example.com/x.git", dst,
                                       "not-a-number", do_clone)
        @test haskey(resp, "error")            # surfaced as a response, not a throw
        @test !ispath(dst)                     # nothing was created
    end
end

@testset "M1: a partial clone WE created is cleaned up on failure" begin
    mktempdir() do root
        dst = joinpath(root, "halfcloned")
        # Simulate a clone that creates the dir then fails partway.
        do_clone = (url, d, pr) -> begin
            mkpath(d); write(joinpath(d, "partial"), "x"); error("network died")
        end
        resp = BW.clone_repo_response("req-3", "https://example.com/x.git", dst,
                                       nothing, do_clone)
        @test haskey(resp, "error")
        @test occursin("network died", resp["error"])
        @test !ispath(dst)                     # our partial clone was removed
    end
end

@testset "M1: a clean clone succeeds" begin
    mktempdir() do root
        dst = joinpath(root, "good")
        do_clone = (url, d, pr) -> (mkpath(d); write(joinpath(d, "README"), "ok"))
        resp = BW.clone_repo_response("req-4", "https://example.com/x.git", dst,
                                       nothing, do_clone)
        @test !haskey(resp, "error")
        @test resp["dst_path"] == dst
        @test isfile(joinpath(dst, "README"))
    end
end

# ── M8: agent process is always reaped (kill_proc! tolerates dead/closed) ──────
@testset "M8: kill_proc! is idempotent and never throws" begin
    # A real short-lived process: kill_proc! after it already exited must not throw.
    proc = open(`$(Base.julia_cmd()[1]) -e "exit(0)"`, "r+")
    sleep(0.3)
    @test BW.kill_proc!(proc) === nothing       # already dead → no throw
    @test BW.kill_proc!(proc) === nothing       # idempotent second call
end

# ── M12: NO idle watchdog ──────────────────────────────────────────────────────
# The control-WS idle watchdog was removed: the server doesn't ping, so an idle
# (healthy) connection has no inbound frames and the watchdog killed it. Assert
# the heuristic is gone so it can't be reintroduced without a real heartbeat.
@testset "M12: no idle-kill watchdog on the control WS" begin
    @test !isdefined(BW, :control_ws_watchdog)
    @test !isdefined(BW, :CONTROL_WS_IDLE_TIMEOUT)
end

# ── M13: a session the worker can't start is refused WITH the reason ──────────
# The server asks for an agent session by opening an `acp` channel. A worker
# that can't run the agent aborts that channel with why, and the server's first
# receive reports it — instead of waiting out a timeout for an answer that will
# never come.
@testset "M13: a failed agent start aborts its channel with the reason" begin
    WL = BW.WorkerLink
    w = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:1", secret = "s",
        worker_id = "m13", name = "m13", mcp_command = "julia", mcp_arguments = String[],
        projects_root = mktempdir(), agent_bin = ""))
    ct, st = WL.memory_pair()
    server_task = Threads.@spawn begin
        h = WL.read_hello(st)
        server = WL.Link(:server; id = h.link_id)
        WL.welcome!(server, st, h, UInt8[]; resumed = false)
        server
    end
    WL.connect!(w.link, ct, UInt8[])
    server = fetch(server_task)
    ch = WL.open_channel(server, BW.MsgPack.pack(Dict(
        "kind" => "acp", "project_id" => "p", "cwd" => mktempdir(),
        "mcpServers" => Any[], "provider" => "NoSuchAgent")))
    err = try
        BW.WebSockets.receive(ch)
        nothing
    catch e
        e
    end
    @test err isa BW.WebSockets.WebSocketError
    @test occursin("unknown provider 'NoSuchAgent'", err.message.reason)
    @test BW.worker_idle(w)                 # nothing was left registered
    close(w)
    WL.kill!(server, "done")
end
