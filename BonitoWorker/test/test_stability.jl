# Regression tests for the BonitoWorker stability findings (M1, M8, M12, M13).
# No network, no claude-agent-acp, no real git: we exercise the pure pieces that
# were extracted for exactly this (clone_repo_response with an injected clone
# stub, the removed idle watchdog, report_open_session_failed framing).

using Test
using BonitoWorker
const BW = BonitoWorker

# A capturing stand-in WS so we can assert report_open_session_failed's frame
# without a real socket. Defined at top level (no world-age dance). The method
# is added to the same generic BonitoWorker calls internally.
# Captures what actually goes on the wire: BYTES. The control wire is MsgPack in
# a binary frame, so a `Vector{String}` sink would have to pick an encoding to
# hold it in — and `String(::Vector{UInt8})` STEALS the buffer it is handed,
# which is a fine way to lose the very frame you meant to inspect.
struct CapturingWS
    sink::Vector{Vector{UInt8}}
end
ws_bytes(msg::AbstractVector{UInt8}) = collect(UInt8, msg)
ws_bytes(msg::AbstractString)        = collect(UInt8, codeunits(msg))
BonitoWorker.WebSockets.send(w::CapturingWS, msg) = (push!(w.sink, ws_bytes(msg)); nothing)

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

# ── M13: open_session failures are reported to the server, not swallowed ───────
@testset "M13: report_open_session_failed sends a frame" begin
    # report_open_session_failed must emit an `open_session_failed` control frame
    # so the server stops waiting for a dial that will never come.
    sent = Vector{UInt8}[]
    ws = CapturingWS(sent)
    BW.report_open_session_failed(ws, "sid-123", "boom")
    @test length(sent) == 1
    # Decoded the way the SERVER decodes it. `JSON.parse` here used to pass; it
    # now throws on the MsgPack bytes, which is the hard cut doing its job — a
    # test that kept parsing the old format would have gone on being green while
    # the wire underneath it had moved.
    payload = BW.decode_control(sent[1])
    @test payload["type"] == "open_session_failed"
    @test payload["sid"] == "sid-123"
    @test occursin("boom", payload["error"])
end
