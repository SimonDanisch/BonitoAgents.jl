@testitem "unit:managed_processes" tags=[:unit] begin
    using BonitoWorker
    const BW = BonitoWorker
    if Sys.isunix()
        dir = mktempdir()
        s = BW.ProcessSupervisor(joinpath(dir,"logs"))
        s.monitor = @async BW.monitor_processes!(s)
        start(id,script;kw...) = BW.start_process!(s,"chat-a",["sh","-c",script];
            id,cwd=dir,label=id,epoch="session-a",kw...)
        status(id) = BW.managed_process_request(s,"chat-a",Dict("action"=>"status","id"=>id))
        until(id,predicate) = timedwait(() -> predicate(status(id)),15.0;pollint=0.05) === :ok
        try
            @testset "tracked output, exit, idempotency and scope" begin
                result = start("success","printf 'hello:%s' \"\$JOB_TEST_VALUE\"";env=Dict("JOB_TEST_VALUE"=>"world"))
                @test until("success",d -> d["status"] == "succeeded")
                done = status("success")
                @test done["output"] == "hello:world"
                @test done["exitcode"] == 0
                @test done["cwd"] == dir
                @test !haskey(done,"env")
                @test start("success","printf 'hello:%s' \"\$JOB_TEST_VALUE\"")["pid"] == result["pid"]
                @test_throws ArgumentError start("success","echo another-command")
                @test_throws ArgumentError BW.managed_process_request(s,"chat-b",Dict("action"=>"kill","id"=>"success"))
                @test isempty(BW.managed_process_request(s,"chat-b",Dict("action"=>"list"))["jobs"])
                @test_throws ArgumentError start("bad/id","echo hello")
                start("failure","echo failure-message >&2; exit 7")
                @test until("failure",d -> d["status"] == "failed")
                @test status("failure")["exitcode"] == 7
                @test occursin("failure-message",status("failure")["output"])
                failed = BW.start_process!(s,"chat-a",[joinpath(dir,"missing-program")];id="missing",cwd=dir,label="missing")
                @test until("missing",d -> d["status"] == "failed")
                @test !isempty(status("missing")["output"])
            end
            @testset "signals address the complete process group" begin
                start("graceful","trap 'echo interrupted; exit 0' INT; echo ready; while :; do sleep 0.1; done")
                @test until("graceful",d -> occursin("ready",d["output"]))
                BW.signal_process!(s,"chat-a","graceful","interrupt")
                @test until("graceful",d -> d["status"] == "interrupted")
                @test occursin("interrupted",status("graceful")["output"])
                stubborn = start("stubborn","trap '' INT TERM; sleep 300 & echo child=\$!; wait")
                @test until("stubborn",d -> occursin("child=",d["output"]))
                @test BW.signal_process!(s,"chat-a","stubborn","interrupt")["status"] == "interrupting"
                sleep(0.6)
                @test status("stubborn")["status"] == "interrupting"
                @test BW.signal_process!(s,"chat-a","stubborn","terminate")["status"] == "terminating"
                @test BW.signal_process!(s,"chat-a","stubborn","kill")["status"] == "killing"
                @test until("stubborn",d -> d["status"] == "killed")
                @test !(stubborn["pgid"] in BW.process_groups_alive())
                # The parent can exit while its child remains: it is still a
                # live job until that process group has actually exited.
                orphan = start("orphan","sleep 300 >/dev/null 2>&1 & echo child-started; exit 0")
                @test until("orphan",d -> occursin("child-started",d["output"]))
                sleep(0.6)
                @test status("orphan")["status"] == "running"
                BW.signal_process!(s,"chat-a","orphan","kill")
                @test until("orphan",d -> d["status"] == "killed")
                @test !(orphan["pgid"] in BW.process_groups_alive())
            end
            @testset "bounded logs and cursors" begin
                start("output","yes 12345678 | head -c 9000000")
                @test until("output",d -> d["status"] == "succeeded")
                chunk = BW.managed_process_request(s,"chat-a",Dict("action"=>"output","id"=>"output","offset"=>0,"max_bytes"=>32))
                @test ncodeunits(chunk["output"]) == 32
                @test chunk["output_truncated"]
                @test chunk["output_offset"] > 0
                @test chunk["next_offset"] == chunk["output_offset"]+32
                @test maximum(filesize(joinpath(s.directory,f)) for f in readdir(s.directory) if endswith(f,".log")) <= BW.PROCESS_LOG_BYTES
            end
            @testset "retired sessions cannot start or kill replacement jobs" begin
                start("old","sleep 300")
                BW.close_process_jobs!(s,"chat-a";epoch="session-a")
                @test until("old",d -> d["status"] == "killed")
                @test_throws ErrorException start("late-start","echo never")
                BW.start_process!(s,"chat-a",["sh","-c","sleep 300"];id="new",cwd=dir,label="new",epoch="session-b")
                BW.close_process_jobs!(s,"chat-a";epoch="session-a")
                @test status("new")["status"] == "running"
                BW.signal_process!(s,"chat-a","new","kill")
                @test until("new",d -> d["status"] == "killed")
                restored = BW.ProcessSupervisor(s.directory)
                BW.restore_process_jobs!(restored)
                @test "session-a" in restored.closed_epochs
                @test BW.managed_process_request(restored,"chat-a",Dict("action"=>"status","id"=>"old"))["status"] == "killed"
            end
            @testset "worker restart reaps persisted running groups" begin
                crashed = BW.ProcessSupervisor(mktempdir())
                crash = BW.start_process!(crashed,"chat-a",["sh","-c","printf crash-output; sleep 300 & wait"];
                    id="crash",cwd=dir,label="crash",epoch="session-c")
                @test timedwait(() -> BW.managed_process_request(crashed,"chat-a",Dict("action"=>"status","id"=>"crash"))["output_bytes"] > 0,
                    10.0;pollint=0.05) === :ok
                recovered = BW.ProcessSupervisor(crashed.directory)
                try
                    BW.restore_process_jobs!(recovered)
                    recovered.monitor = @async BW.monitor_processes!(recovered)
                    inspect() = BW.managed_process_request(recovered,"chat-a",Dict("action"=>"status","id"=>"crash"))
                    @test timedwait(() -> inspect()["status"] == "lost",10.0;pollint=0.05) === :ok
                    @test !(crash["pgid"] in BW.process_groups_alive())
                    @test occursin("Worker restarted",inspect()["error"])
                    @test inspect()["output_offset"] >= 0
                    @test inspect()["output"] == "crash-output"
                    @test inspect()["output_cursor_reset"]
                finally
                    BW.close_process_jobs!(crashed)
                    recovered.closed = true
                    recovered.monitor === nothing || wait(recovered.monitor)
                end
            end
        finally
            BW.close_process_jobs!(s)
            timedwait(() -> all(j -> !(j.record["status"] in BW.PROCESS_ACTIVE),values(s.jobs)),10.0)
            s.closed = true
            wait(s.monitor)
        end
    end
end

@testitem "unit:managed_processes_windows" tags=[:unit] begin
    using BonitoWorker
    const BW = BonitoWorker
    if Sys.iswindows()
        dir = mktempdir()
        supervisor = BW.ProcessSupervisor(joinpath(dir,"logs"))
        supervisor.monitor = @async BW.monitor_processes!(supervisor)
        status(id) = BW.managed_process_request(supervisor,"windows-chat",Dict("action"=>"status","id"=>id))
        try
            BW.start_process!(supervisor,"windows-chat",["cmd","/d","/c","echo quick-result"];
                id="quick",cwd=dir,label="Quick Windows command")
            @test timedwait(() -> status("quick")["status"] == "succeeded",30.0) === :ok
            @test occursin("quick-result",status("quick")["output"])
            BW.start_process!(supervisor,"windows-chat",["cmd","/d","/c","echo windows-ready & ping -n 300 127.0.0.1 >nul"];
                id="tree",cwd=dir,label="Windows process tree")
            @test timedwait(() -> occursin("windows-ready",status("tree")["output"]),30.0) === :ok
            @test supervisor.jobs[BW.process_key("windows-chat","tree")].job_handle != C_NULL
            @test_throws ErrorException BW.signal_process!(supervisor,"windows-chat","tree","interrupt")
            BW.signal_process!(supervisor,"windows-chat","tree","kill")
            @test timedwait(() -> status("tree")["status"] == "killed",30.0) === :ok
            @test supervisor.jobs[BW.process_key("windows-chat","tree")].job_handle == C_NULL
        finally
            BW.close_process_jobs!(supervisor)
            timedwait(() -> all(j -> !(j.record["status"] in BW.PROCESS_ACTIVE),values(supervisor.jobs)),10.0)
            supervisor.closed = true
            wait(supervisor.monitor)
        end
    end
end

@testitem "unit:process_wait_cancellation" tags=[:unit] begin
    using BonitoMCP
    const M = BonitoMCP
    first, second = Channel{Nothing}(0), Channel{Nothing}(0)
    lock(M.SERVER.waits.lock) do
        push!(M.SERVER.waits.active,first,second)
    end
    try
        M.note_wait_request!(Dict("_mcp_request_id"=>"process-wait-a"),first)
        M.note_wait_request!(Dict("_mcp_request_id"=>"process-wait-b"),second)
        M.handle_cancelled!(Dict("params"=>Dict("requestId"=>"process-wait-a")))
        @test !isopen(first)
        @test isopen(second)
        @test haskey(M.SERVER.inflight,"process-wait-b")
    finally
        for (id,wake) in (("process-wait-a",first),("process-wait-b",second))
            M.clear_inflight_request!(id)
            lock(() -> delete!(M.SERVER.waits.active,wake),M.SERVER.waits.lock)
            isopen(wake) && close(wake)
        end
    end
end

@testitem "unit:managed_process_epochs" tags=[:unit] begin
    using BonitoAgents
    const BT = BonitoAgents
    state = BT.ServerState(;state_dir=mktempdir(),working_dir=mktempdir())
    project = BT.ProjectInfo("epochs","epochs","worker",mktempdir(),"/worker/project",BT.now(BT.UTC))
    state.projects[][project.id] = project
    BT.save_projects!(state)
    epoch = BT.managed_process_epoch(state,project.id)
    restarted = BT.ServerState(;state_dir=state.state_dir,working_dir=state.working_dir)
    @test BT.managed_process_epoch(restarted,project.id) == epoch
    BT.close_managed_processes!(state,project.id)
    current = BT.managed_process_epoch(state,project.id)
    @test current != epoch
    # An offline job remains visibly running pending real cleanup. A late
    # snapshot cannot undo the fence, nor can a server restart forget it.
    frame = Dict{String,Any}("project_id"=>project.id,"id"=>"late","epoch"=>epoch,
        "status"=>"running","revision"=>1,"output_bytes"=>0,"output"=>"",
        "started"=>time(),"label"=>"Late job","pid"=>12345,"argv"=>["sleep","300"],
        "cwd"=>"/worker/project","exitcode"=>nothing)
    BT.managed_process_update!(state,"worker",frame)
    book = BT.process_book(state,project.id)
    @test epoch in book.retired
    @test book.jobs[BT.managed_task_id("worker","late")]["status"] == "running"
    BT.close_managed_processes!(state,project.id)
    again = BT.ServerState(;state_dir=state.state_dir,working_dir=state.working_dir)
    restored = BT.process_book(again,project.id)
    @test epoch in restored.retired && current in restored.retired
    @test restored.epoch != current
end
