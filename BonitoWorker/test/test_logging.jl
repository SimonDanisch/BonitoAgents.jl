using Test, Logging, BonitoWorker

module LoggingPayloadFixture
    struct Payload
        displays::Base.RefValue{Int}
    end
    Base.show(io::IO, p::Payload) = (p.displays[] += 1; print(io, "EXPANDED_PAYLOAD"))
    restricted(::Int) = nothing
end

@testset "timestamp logger formats exceptions without traversing arguments" begin
    count = Ref(0)
    err, bt = try
        LoggingPayloadFixture.restricted(LoggingPayloadFixture.Payload(count))
        error("expected a MethodError")
    catch e
        e isa MethodError || rethrow()
        (e, catch_backtrace())
    end
    for exception in (err, (err, bt))
        io = IOBuffer()
        with_logger(BonitoWorker.TimestampLogger(io, Logging.Debug)) do
            @error "render failed" exception
        end
        text = String(take!(io))
        @test count[] == 0
        @test occursin("MethodError", text)
        @test occursin("restricted", text)
        @test occursin("Payload", text)
        @test !occursin("EXPANDED_PAYLOAD", text)
        exception isa Tuple && @test occursin("Stacktrace:", text)
    end
    io = IOBuffer()
    with_logger(BonitoWorker.TimestampLogger(io, Logging.Debug)) do
        @info "ordinary values" count = 3 phase = "render"
    end
    @test occursin("count=3  phase=render", String(take!(io)))
end
