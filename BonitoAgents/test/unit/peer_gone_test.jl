# `is_peer_gone` — the ONE "this socket is already gone" predicate every server
# teardown path uses. It exists because the per-site whitelists it replaced were
# each written against the transport of their day.
#
# The regression is concrete. On 2026-09-11 the server journal carried:
#
#   UNHANDLED TASK ERROR: use of closed network connection
#     [2] _write_ptr!(fd::Reseau.IOPoll.FD, ...)
#     [9] send_control @ worker_client.jl:56
#    [10] handle_worker_control##6 @ worker_client.jl:486
#
# — the worker-heartbeat PING task. Its catch listed `WebSocketError`,
# `Base.IOError` and `EOFError`; Reseau throws `NetClosingError`, a bare
# `struct <: Exception` that is none of them. So it rethrew, the pinger died,
# and `last_ping_ok` — the timestamp the zombie reaper reads to decide a worker
# is unreachable — stopped advancing.
@testitem "unit:peer_gone" tags = [:unit] begin
    using Test
    import BonitoAgents as BT
    import HTTP

    # Stand-in for `Reseau.IOPoll.NetClosingError`, declared the same way (bare
    # struct, no supertype beyond Exception). Reseau is HTTP's transport
    # internals and NOT a dependency of this package, so the predicate matches
    # it by NAME — which is exactly what this asserts.
    struct NetClosingError <: Exception end

    @testset "the error that actually escaped" begin
        @test BT.is_peer_gone(NetClosingError())
        # …and it must not be matched by accident through a supertype: that it
        # is neither of these is the whole reason the old whitelist missed it.
        @test !(NetClosingError() isa Base.IOError)
        @test !(NetClosingError() isa EOFError)
    end

    @testset "the transports it always covered" begin
        @test BT.is_peer_gone(EOFError())
        @test BT.is_peer_gone(Base.IOError("closed", -1))
        @test BT.is_peer_gone(HTTP.WebSockets.WebSocketError(
            HTTP.WebSockets.CloseFrameBody(1006, "")))
        @test BT.is_peer_gone(ArgumentError("stream is closed or unusable"))
    end

    @testset "a real bug is still a real bug" begin
        # The predicate gates `rethrow()`, so anything it wrongly accepts is an
        # error the server would swallow.
        @test !BT.is_peer_gone(ErrorException("boom"))
        @test !BT.is_peer_gone(BoundsError([1], 5))
        @test !BT.is_peer_gone(ArgumentError("bad argument"))
    end

    # The stale-session predicate is layered on top, so it inherits the fix —
    # `safe_notify!` tolerating a dead browser tab must cover the same
    # transport errors as the worker sockets do.
    @testset "is_stale_session_error inherits it" begin
        @test BT.is_stale_session_error(NetClosingError())
        @test BT.is_stale_session_error(EOFError())
        @test !BT.is_stale_session_error(ErrorException("boom"))
    end
end

# The log reader itself: it runs on machines we do not control (a macOS or
# Windows worker, a CI box, a worker that has not written a line yet), so every
# one of those must be an ANSWER rather than a throw — a fan-out over six
# machines must not lose five because one cannot help.
#
# The format matters as much as the reading. One record is ONE timestamped line
# plus indented continuations, and anything that bypassed the logger entirely
# (an `UNHANDLED TASK ERROR`, a signal dump) is kept verbatim and inherits the
# stamp above it. That is what lets `since`/`until` slice a log without cutting
# a stack trace off the line that raised it.
@testitem "unit:log_file" tags = [:unit] begin
    using Test
    import BonitoWorker as BW

    @testset "a machine with no log answers, it does not throw" begin
        r = BW.read_log_file(; path = "", lines = 5)
        @test r["ok"] === false
        @test occursin("not writing a log file", r["error"])
        @test haskey(r, "host")          # shape is identical whatever happened

        gone = BW.read_log_file(; path = joinpath(mktempdir(), "nope.log"))
        @test gone["ok"] === false
        @test occursin("no log file", gone["error"])
        @test gone["host"] == gethostname()
    end

    @testset "records round-trip through the reader" begin
        path = joinpath(mktempdir(), "probe.log")
        open(path, "w") do io
            BW.CoreLogging.with_logger(BW.TimestampLogger(io, BW.CoreLogging.Info)) do
                @info "alpha" worker = "Desktop"
                @warn "two\nline"
                @error "omega" code = 42
            end
            # …and the class of output that never passes through a logger.
            println(io, "UNHANDLED TASK ERROR: bypassed the logger")
            println(io, "Stacktrace:")
        end
        r = BW.read_log_file(; path = path, lines = 50)
        @test r["ok"] === true
        @test r["bytes"] > 0
        txt = join(r["lines"], "\n")

        # A record is one stamped line; its extra lines are INDENTED, so the
        # stamp regex cannot match mid-record and split one record into two.
        stamped = [l for l in r["lines"] if match(BW.STAMP_RE, l) !== nothing]
        @test length(stamped) == 3
        @test occursin("worker=Desktop", txt) && occursin("code=42", txt)
        @test any(l -> startswith(l, "    line"), r["lines"])

        # Raw stderr survives verbatim — this is the whole reason the log is a
        # redirect of fd 1/2 rather than a logger sink.
        @test occursin("UNHANDLED TASK ERROR: bypassed the logger", txt)

        @test BW.read_log_file(; path = path, grep = "omega")["returned"] == 1
        @test BW.read_log_file(; path = path, lines = 2)["returned"] == 2

        today = Libc.strftime("%Y-%m-%d", time())
        @test BW.read_log_file(; path = path, since = today)["returned"] == length(r["lines"])
        @test BW.read_log_file(; path = path, since = "2099-01-01")["returned"] == 0
        # Space and T are both accepted on input.
        @test BW.read_log_file(; path = path, since = "$(today) 00:00")["returned"] ==
              BW.read_log_file(; path = path, since = "$(today)T00:00")["returned"]
    end

    @testset "an un-timestamped log says so instead of going quiet" begin
        # A log written before the timestamping logger existed matches no time
        # window. Returning an empty list would read like a quiet machine.
        path = joinpath(mktempdir(), "legacy.log")
        write(path, "┌ Info: BonitoWorker: registered with server\n└   name = \"x\"\n")
        r = BW.read_log_file(; path = path, since = "2026-01-01")
        @test r["ok"] === true
        @test r["returned"] == 0
        @test occursin("predates the timestamping logger", r["note"])
        # …and without a time filter the same file reads fine.
        @test BW.read_log_file(; path = path)["returned"] == 2
        @test !haskey(BW.read_log_file(; path = path), "note")
    end

    @testset "the line count is capped" begin
        # The reply crosses a websocket into a chat; an uncapped read is a way
        # to paste a gigabyte of log into a conversation.
        path = joinpath(mktempdir(), "big.log")
        open(path, "w") do io
            for i in 1:50; println(io, "line $i"); end
        end
        @test BW.read_log_file(; path = path, lines = 10^9)["capped_at"] == BW.LOG_MAX_LINES
        @test BW.LOG_MAX_LINES <= 5000
    end
end
