@testitem "unit:job_progress" tags=[:unit] begin
    using BonitoAgents, BonitoMCP, JSON
    const B=BonitoAgents
    const P=BonitoMCP.BonitoProgress
    state=B.ServerState(;state_dir=mktempdir(),working_dir=mktempdir())
    book=B.job_book(state,"progress-test")
    context=Dict("BONITOAGENTS_PROGRESS_ADDR"=>"","BONITOAGENTS_PROGRESS_TOKEN"=>"")
    job=P.progress("Render \"frames\"\nλ";id="farm",total=100,context)
    @test JSON.parse(P.encode(job.snapshot)) == job.snapshot
    B.job_update!(book,job.snapshot,"worker-a","connection-a")
    @test book.changed[]["farm"]["completed"] == 0
    P.update!(job,32;detail="32 validated frames")
    B.job_update!(book,job.snapshot,"worker-a","connection-a")
    @test book.changed[]["farm"]["completed"] == 32
    old=copy(job.snapshot)
    P.finish!(job)
    B.job_update!(book,job.snapshot,"worker-a","connection-a")
    B.job_update!(book,old,"worker-a","connection-a")
    @test book.changed[]["farm"]["status"] == "completed"
    @test book.changed[]["farm"]["completed"] == 100
    B.progress_disconnected!(book,"connection-a")
    restored=B.ServerState(;state_dir=state.state_dir,working_dir=state.working_dir)
    @test B.job_book(restored,"progress-test").changed[]["farm"]["status"] == "completed"
    resumed=P.progress("Resume";id="farm",total=200,completed=100,context)
    B.job_update!(book,resumed.snapshot,"worker-b","connection-b")
    B.job_update!(book,job.snapshot,"worker-a","connection-a")
    B.progress_disconnected!(book,"connection-a")
    @test book.changed[]["farm"]["label"] == "Resume"
    @test book.changed[]["farm"]["connected"]
    P.update!(resumed,120)
    B.job_update!(book,resumed.snapshot,"worker-b","connection-b")
    B.progress_disconnected!(book,"connection-b")
    @test !book.changed[]["farm"]["connected"]
    @test book.changed[]["farm"]["completed"] == 120
    @test book.changed[]["farm"]["status"] == "running"
    malformed=merge(resumed.snapshot,Dict("completed"=>NaN))
    @test_throws ArgumentError B.job_update!(book,malformed,"worker-b","connection-b")
    @test_throws ArgumentError P.update!(resumed,Inf)
    @test_throws ArgumentError P.update!(resumed,201)
    @test_throws ArgumentError P.update!(resumed,-1)
    @test_throws ArgumentError P.progress("bad";id="",context)
    @test_throws ArgumentError P.update!(resumed,120;detail=repeat("x",4097))
    book.changed[]["farm"]["dismissed"]=true
    P.update!(resumed,121)
    B.job_update!(book,resumed.snapshot,"worker-b","connection-b")
    @test book.changed[]["farm"]["dismissed"]
    B.progress_worker_connected!(state,"worker-b",false)
    @test !book.changed[]["farm"]["worker_online"]
    B.progress_worker_connected!(state,"worker-b",true)
    @test book.changed[]["farm"]["worker_online"]
    P.fail!(resumed,"renderer failed")
    B.job_update!(book,resumed.snapshot,"worker-b","connection-b")
    @test book.changed[]["farm"]["status"] == "failed"
    @test book.changed[]["farm"]["completed"] == 121
    @test isempty(state.chat_models) # telemetry never creates or prompts an agent
    @test state.turn_signal[] == 0
    @test state.chat_signal[] == 0
    captured=Ref{P.Job}()
    @test P.progress("callback";total=10,context) do job
        captured[]=job
        job(4,10)
        @test job.snapshot["completed"]==4
        :result
    end == :result
    @test captured[].snapshot["status"]=="completed"
    @test_throws ErrorException P.progress("failed callback";total=10,context) do job
        captured[]=job
        job(3,10)
        error("render failed")
    end
    @test captured[].snapshot["status"]=="failed"
    @test captured[].snapshot["completed"]==3
    close(captured[])
    @test_throws ArgumentError P.update!(captured[],4)
    cancelled=P.progress("Cancelled farm";total=10,completed=3,context)
    P.cancel!(cancelled)
    @test cancelled.snapshot["status"]=="cancelled"
    @test cancelled.snapshot["completed"]==3
    P.update!(cancelled,4)
    @test cancelled.snapshot["completed"]==3
end

@testitem "unit:progress_offline" tags=[:unit] begin
    using BonitoMCP, Sockets
    P=BonitoMCP.BonitoProgress
    listener=Sockets.listen(Sockets.localhost,0)
    port=Sockets.getsockname(listener)[2]
    close(listener) # A real unavailable endpoint, with no server accepting it.
    context=Dict("BONITOAGENTS_PROGRESS_ADDR"=>"127.0.0.1:$port","BONITOAGENTS_PROGRESS_TOKEN"=>"test-grant")
    job=P.progress("Offline farm";total=10000,context)
    try
        updates=@async for done in 1:10000; P.update!(job,done); end
        @test timedwait(()->istaskdone(updates),2.0) === :ok
        fetch(updates)
        @test job.snapshot["completed"]==10000
        @test !P.flush_progress(job;timeout=0.05)
        @test job.acknowledged==0
    finally
        close(job)
    end
    @test timedwait(()->istaskdone(job.task),2.0) === :ok
    @test job.socket===nothing
end

@testitem "unit:progress_logging" tags=[:unit] begin
    using BonitoMCP, Logging
    const P=BonitoMCP.BonitoProgress
    context=Dict("BONITOAGENTS_PROGRESS_ADDR"=>"","BONITOAGENTS_PROGRESS_TOKEN"=>"")
    logger=P.progress_logger(NullLogger();context)
    with_logger(logger) do
        @info "Render frames" progress=0.25 _id=:render completed=25 total=100 unit="frames"
        @info "Render frames" progress=1.0 _id=:render completed=100 total=100
        @info "Render frames" progress="done" _id=:render
        @info "Interrupted render" progress=0.2 _id=:interrupted
        @info "Interrupted render" progress="done" _id=:interrupted
        @info "ordinary log remains ordinary"
    end
    @test length(logger.jobs) == 2
    @test logger.jobs["render"].snapshot["status"] == "completed"
    @test logger.jobs["render"].snapshot["completed"] == 100
    @test logger.jobs["interrupted"].snapshot["status"] == "closed"
    @test logger.jobs["interrupted"].snapshot["completed"] == 0.2
    first_generation=logger.jobs["render"].snapshot["generation"]
    with_logger(logger) do
        @info "Render again" progress=0.1 _id=:render
    end
    @test logger.jobs["render"].snapshot["generation"] != first_generation
    @test logger.jobs["render"].snapshot["status"] == "running"
end
