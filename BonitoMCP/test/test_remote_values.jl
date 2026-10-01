# Values between an eval session and one on another worker: the protocol both
# sides of `remote_values.jl` speak, in one process. A stand-in relay plays the
# worker relays AND the server: it accepts the chat's side (`<token> values`),
# answers its "open", has the other side connect (`serve_values(pair)`, which
# dials back here with `<token> values <pair>`) and pipes the two sockets
# together byte for byte. The real relay and server are in the e2e test
# (BonitoAgents' e2e/remote_values_test.jl).

using Test
using BonitoMCP
import Sockets, Serialization

# Its own copy of the helper: the process running this may be an eval worker
# with one loaded already.
module RemoteValuesTest end
Base.include(RemoteValuesTest, BonitoMCP.helper_payload_path())
const H = RemoteValuesTest.BonitoMCPHelper

struct Unserializable end
Serialization.serialize(::Serialization.AbstractSerializer, ::Unserializable) =
    error("Unserializable refuses to be serialized")

mutable struct FakeRelay
    server::Sockets.TCPServer
    token::String
    pairs::Dict{String,Channel{Sockets.TCPSocket}}
    answering::Vector{Sockets.TCPSocket}     # the other sides, to cut them off
    opens::Int
    lock::ReentrantLock
end

function FakeRelay(token)
    r = FakeRelay(Sockets.listen(Sockets.localhost, 0), token, Dict{String,Channel{Sockets.TCPSocket}}(),
                  Sockets.TCPSocket[], 0, ReentrantLock())
    Base.errormonitor(@async while true
        sock = try
            Sockets.accept(r.server)
        catch e
            (e isa Base.IOError && !isopen(r.server)) || rethrow()
            break
        end
        Base.errormonitor(@async serve_fake(r, sock))
    end)
    return r
end

address(r::FakeRelay) = "127.0.0.1:" * string(Sockets.getsockname(r.server)[2])

function copy_bytes(from, to)
    try
        while !eof(from)
            write(to, readavailable(from))
        end
    catch e
        e isa Base.IOError || rethrow()
    finally
        close(to)
    end
end

function serve_fake(r::FakeRelay, sock)
    token, rest... = split(H.read_msg(sock)::String, ' ')
    if token != r.token
        H.write_msg(sock, "refused\nunknown token")
        return close(sock)
    end
    H.write_msg(sock, "ok")
    if length(rest) == 2                                  # the other side, answering
        put!(lock(() -> r.pairs[rest[2]], r.lock), sock)
        return nothing
    end
    verb, arg = H.request_parts(H.read_msg(sock)::String)
    worker, env_path = split(arg, '\n'; limit = 2)
    lock(() -> r.opens += 1, r.lock)
    if worker == "old-julia"
        H.write_msg(sock, "ok\nold-julia")
        H.write_msg(sock, "hello\n1.0.0")
        return nothing
    elseif worker == "nobody"
        H.write_msg(sock, "error\nno worker named 'nobody'")
        return close(sock)
    end
    pair = string(rand(UInt64); base = 16)
    ch = Channel{Sockets.TCPSocket}(1)
    lock(() -> (r.pairs[pair] = ch), r.lock)
    H.serve_values(pair)                                   # dials back into this relay
    other = take!(ch)
    lock(() -> push!(r.answering, other), r.lock)
    H.write_msg(sock, "ok\n" * worker)
    @async copy_bytes(other, sock)
    copy_bytes(sock, other)
    return nothing
end

@testset "values to and from another session" begin
    relay = FakeRelay("tok")
    H.set_value_relay!(address(relay), "tok")
    r = H.remote_session("worker-b")
    @test H.remote_session("worker-b") === r          # one per (worker, env)

    @testset "set, get, call" begin
        r[:rv_small] = (1, "two", [3.0])
        @test Main.rv_small == (1, "two", [3.0])
        Core.eval(Main, :(rv_there = Dict(:a => 1)))
        @test r[:rv_there] == Dict(:a => 1)
        @test r(+, 1, 2) == 3
        @test r(x -> x .* 2, [1, 2]) == [2, 4]
        @test r(round, 2.567; digits = 1) == 2.6                 # keywords, to a named function
        # An anonymous function with keywords would not rebuild in another
        # process: refused here, before anything is sent.
        e = try; r((x; k = 0) -> x + k, 1; k = 10); nothing; catch err; err; end
        @test e isa H.RemoteSessionError && occursin("keyword arguments", e.msg)
        @test r(let a = 5; x -> x + a end, 1) == 6                 # a captured value travels
        Core.eval(Main, :(rv_double(x) = 2x))
        @test r(:rv_double, 21) == 42
        @test relay.opens == 1                         # all of it on one connection
    end

    @testset "a value far over one message, both ways" begin
        big = rand(5_000_000)                          # 40 MB: 39 messages of 1 MiB
        r[:rv_big] = big
        @test Main.rv_big == big
        @test r[:rv_big] == big
        @test r(length ∘ string, repeat("x", 3_000_000)) == 3_000_000
    end

    @testset "failures say why and leave the connection usable" begin
        e = try; r[:rv_undefined_anywhere]; nothing; catch err; err; end
        @test e isa H.RemoteSessionError
        @test occursin("rv_undefined_anywhere", e.msg) && occursin("worker-b", e.msg)
        e = try; r(() -> error("boom there")); nothing; catch err; err; end
        @test e isa H.RemoteSessionError
        @test occursin("boom there", e.msg)
        # The backtrace ends at the user's code, not in the exchange's own frames.
        @test !occursin("answer_value_request", e.msg)
        e = try; r[:rv_bad] = Unserializable(); nothing; catch err; err; end
        @test e isa H.RemoteSessionError
        @test occursin("could not send the value", e.msg) && occursin("refuses to be serialized", e.msg)
        @test !isdefined(Main, :rv_bad)
        e = try; r(() -> Unserializable()); nothing; catch err; err; end
        @test e isa H.RemoteSessionError
        @test occursin("could not send the value", e.msg) && occursin("refuses to be serialized", e.msg)
        e = try; r[Symbol("not a name")] = 1; nothing; catch err; err; end
        @test e isa H.RemoteSessionError && occursin("is not a name", e.msg)
        @test r(+, 2, 2) == 4
        @test relay.opens == 1
    end

    @testset "what a value that cannot be rebuilt needs" begin
        pkg = Base.PkgId(Base.UUID("91a5bcdd-55d7-5caf-9e0b-520d859cae80"), "Plots")
        @test occursin("`using Plots` first", H.cannot_deserialize(KeyError(pkg)))
        @test occursin("Define it here too", H.cannot_deserialize(UndefVarError(:Foo, Main)))
    end

    @testset "a kept connection that died is replaced for set and get" begin
        foreach(close, lock(() -> copy(relay.answering), relay.lock))
        sleep(0.2)
        r[:rv_after] = 7                               # retried on a new connection
        @test Main.rv_after == 7
        @test relay.opens == 2
        foreach(close, lock(() -> copy(relay.answering), relay.lock))
        sleep(0.2)
        # A call may have run already: it is not repeated, it says so.
        e = try; r(+, 1, 1); nothing; catch err; err; end
        @test e isa H.RemoteSessionError && occursin("lost the connection", e.msg)
        @test r(+, 1, 1) == 2
    end

    @testset "refusals" begin
        e = try; H.remote_session("old-julia")[:x]; nothing; catch err; err; end
        @test e isa H.RemoteSessionError
        @test occursin("Julia $(VERSION) here, 1.0.0 on old-julia", e.msg)
        e = try; H.remote_session("nobody")[:x]; nothing; catch err; err; end
        @test e isa H.RemoteSessionError && occursin("no worker named 'nobody'", e.msg)
        H.set_value_relay!(address(relay), "wrong")
        e = try; H.remote_session("another")[:x]; nothing; catch err; err; end
        @test e isa ErrorException && occursin("unknown token", e.msg)
        H.set_value_relay!("", "")
        e = try; H.remote_session("yet-another")[:x]; nothing; catch err; err; end
        @test occursin("no route to other workers", sprint(showerror, e))
    end

    close(r)
    close(relay.server)
end
