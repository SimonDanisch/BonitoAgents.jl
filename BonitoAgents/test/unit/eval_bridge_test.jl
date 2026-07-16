@testitem "unit:eval_bridge" tags = [:unit] begin

# Headless unit tests for the SERVER side of the remote-app bridge (EvalBridge)
# in isolation — no dev_server, no worker, no socket. A bare `HTTPAssetServer()`
# stands in for the per-worker asset host. Guards the disconnect/reconnect
# correctness paths the e2e only covers incidentally: a control call must fail
# fast (not hang the full timeout) when the socket is down, in-flight requests
# must be resolved (not stranded) when the socket drops, and worker→host control
# replies (value AND error) must route back to the right caller.

using Test
import BonitoAgents, Bonito
const BT = BonitoAgents

mkbridge() = BT.make_eval_bridge("proj", nothing, Bonito.HTTPAssetServer())  # ws=nothing ⇒ disconnected

# A browser connection whose write is slow (simulates a CPU-bound / WGLMakie tab
# draining its socket slowly) — the condition that head-of-line-blocked the relay.
struct SlowConn <: Bonito.FrontendConnection end
Base.write(::SlowConn, ::AbstractVector{UInt8}) = (sleep(2.0); nothing)
Base.isopen(::SlowConn) = true
Base.close(::SlowConn) = nothing
Bonito.setup_connection(::Bonito.Session{SlowConn}) = nothing

@testset "EvalBridge server-side (headless)" begin

    @testset "call_ctrl fails fast when the socket is down (redial_grace = 0)" begin
        eb = mkbridge()
        t0 = time()
        @test_throws Exception BT.call_ctrl(eb, "delegate"; timeout = 30.0, redial_grace = 0.0)
        @test time() - t0 < 1.0          # fast-fail, NOT a 30s timedwait
    end

    @testset "call_ctrl waits out the redial grace, then errors" begin
        # A dropped dial-back gets a bounded reconnect window before failing —
        # an instant error here used to leave fragments without their JS module
        # (asset fetch during a redial). No redial happens in this test, so the
        # call must error AFTER the grace, not before and not much later.
        eb = mkbridge()
        t0 = time()
        @test_throws Exception BT.call_ctrl(eb, "delegate"; timeout = 30.0, redial_grace = 0.3)
        elapsed = time() - t0
        @test 0.3 <= elapsed < 2.0
    end

    @testset "fail_pending! resolves every in-flight request, then empties" begin
        eb = mkbridge()
        chans = [Channel{Any}(1) for _ in 1:3]
        lock(eb.pending_lock) do
            for (i, ch) in enumerate(chans); eb.pending[i] = ch; end
        end
        BT.fail_pending!(eb, "socket dropped")
        for ch in chans
            @test isready(ch)
            @test take!(ch) isa Exception
        end
        @test isempty(eb.pending)        # table cleared, no stale entries
    end

    @testset "handle_worker_control routes a reply back to its caller" begin
        eb = mkbridge()
        # value reply
        ch = Channel{Any}(1); lock(eb.pending_lock) do; eb.pending[5] = ch; end
        BT.handle_worker_control(eb, Dict{String,Any}("op" => "reply", "id" => 5, "val" => 42))
        @test take!(ch) == 42
        # error reply → surfaced as an Exception (so call_ctrl rethrows, not a hang)
        ch2 = Channel{Any}(1); lock(eb.pending_lock) do; eb.pending[6] = ch2; end
        BT.handle_worker_control(eb, Dict{String,Any}("op" => "reply", "id" => 6, "err" => "kaboom"))
        r = take!(ch2)
        @test r isa Exception
        @test occursin("kaboom", sprint(showerror, r))
        # a reply for an unknown id is a harmless no-op (caller already gave up)
        BT.handle_worker_control(eb, Dict{String,Any}("op" => "reply", "id" => 999, "val" => 1))
        @test true
    end

    @testset "relay stays responsive while the browser write is slow (head-of-line)" begin
        # The bug: the relay loop did a blocking worker→browser `write` AND
        # delivered control replies, so a slow browser starved delegate/asset_read
        # replies → 30s timeouts. Now data frames are queued for a writer task and
        # control frames are handled inline — a slow write must not delay a reply.
        eb = mkbridge()
        eb.root_conn[] = SlowConn()                       # every browser write takes 2s
        outbound = Channel{Vector{UInt8}}(2048)
        writer = Base.errormonitor(@async BT.relay_writer(eb, outbound))

        ch = Channel{Any}(1); lock(eb.pending_lock) do; eb.pending[7] = ch; end
        # A DATA frame the writer will spend 2s shipping to the slow browser…
        BT.relay_frame!(eb, outbound, vcat(UInt8('D'), rand(UInt8, 8_000)))
        # …immediately followed by the control REPLY for the in-flight request.
        reply = Bonito.MsgPack.pack(Dict{String,Any}("op" => "reply", "id" => 7, "val" => "ok"))
        t0 = time()
        BT.relay_frame!(eb, outbound, vcat(UInt8('C'), reply))
        @test timedwait(() -> isready(ch), 1.0) === :ok   # reply NOT stuck behind the 2s write
        @test time() - t0 < 1.0
        @test take!(ch) == "ok"
        close(outbound)
    end
end

end
