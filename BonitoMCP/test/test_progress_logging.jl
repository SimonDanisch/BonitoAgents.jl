using BonitoMCP, Logging, Test, UUIDs, ProgressLogging

@testset "ProgressLogging public protocol" begin
    P=BonitoMCP.BonitoProgress
    context=Dict("BONITOAGENTS_PROGRESS_ADDR"=>"","BONITOAGENTS_PROGRESS_TOKEN"=>"")
    logger=P.progress_logger(NullLogger();context)
    with_logger(logger) do
        ProgressLogging.@withprogress name="Standard loop" begin
            ProgressLogging.@logprogress 0.4
            ProgressLogging.@logprogress 1.0
        end
        @test_throws ErrorException ProgressLogging.@withprogress name="Interrupted loop" begin
            ProgressLogging.@logprogress 0.2
            error("renderer stopped")
        end
        @info ProgressLogging.Progress(uuid4(),0.6;name="Typed record")
    end
    jobs=Dict(j.snapshot["label"]=>j.snapshot for j in values(logger.jobs))
    @test jobs["Standard loop"]["status"]=="completed"
    @test jobs["Standard loop"]["completed"]==1
    @test jobs["Interrupted loop"]["status"]=="closed"
    @test jobs["Interrupted loop"]["completed"]==0.2
    @test jobs["Typed record"]["completed"]==0.6
    @test jobs["Typed record"]["status"]=="running"
    @test length(jobs)==3
end

# A value whose `show` throws, logged inside an eval: the logger reports it and
# the eval goes on, as under a plain ConsoleLogger. ProgressLogger said it did
# not catch, so the eval that logged it failed.
struct ProgressUnprintable end
Base.show(::IO, ::ProgressUnprintable) = error("this show method always throws")

@testset "ProgressLogger: a log record that can't be shown doesn't throw" begin
    logger = BonitoMCP.BonitoProgress.progress_logger(ConsoleLogger(IOBuffer()); context = Dict{String,String}())
    @test Logging.catch_exceptions(logger)
    reached = with_logger(logger) do
        @info "unshowable" value = ProgressUnprintable()
        true
    end
    @test reached
end
