# A background task's output file, followed for the server (file_watch.jl).
# The server used to ask for it once a second per task, and every answer scanned
# every process on the machine for who still held it open. Now the worker says
# what changed when it changes, and that the task ended when its writer closed
# the file. Over a real link pair, with real writer processes.

using Test
using BonitoWorker
const BW = BonitoWorker
const WL = BW.WorkerLink
const MsgPack = BW.MsgPack

# The server's end of a watch: everything the worker sent, until it closed.
function watch(header; on_ready = () -> nothing, timeout = 20.0)
    wt, st = WL.memory_pair()
    worker = WL.Link(:client; on_open = ch -> BW.run_file_watch(ch, BW.decode_control(WL.header(ch))))
    server = WL.Link(:server)
    WL.attach!(worker, wt, UInt64(0)); WL.attach!(server, st, UInt64(0))
    ch = WL.open_channel(server, MsgPack.pack(merge(Dict{String,Any}("kind" => "watch_file"), header)))
    msgs = Dict{String,Any}[]
    try
        @test BW.decode_control(BW.WebSockets.receive(ch))["ok"] === true
        on_ready()
        reader = @async for frame in ch
            push!(msgs, BW.decode_control(frame))
        end
        timedwait(() -> istaskdone(reader), timeout) === :ok || close(ch)
        wait(reader)
    finally
        WL.kill!(worker, "test done"); WL.kill!(server, "test done")
    end
    return msgs
end

text(msgs) = join(m["chunk"] for m in msgs if haskey(m, "chunk"))
done(msgs) = any(m -> get(m, "done", false) === true, msgs)

@testset "file watch" begin
    if !Sys.islinux()
        @test_skip "the end of a shell's output is a Linux close event"
    else
        @testset "a shell's output streams, and its exit ends the watch" begin
            f = tempname()
            writer = Ref{Base.Process}()
            t0 = time()
            msgs = watch(Dict("path" => f, "offset" => 0, "until" => "closed");
                on_ready = () -> (writer[] = run(pipeline(`sh -c "echo one; sleep 0.5; echo two; sleep 0.5"`;
                                                          stdout = f, append = true); wait = false)))
            @test text(msgs) == "one\ntwo\n"
            @test done(msgs)
            @test process_exited(writer[])
            @test last(msgs)["offset"] == 8
            @test time() - t0 < 10
        end

        @testset "a file that does not exist yet" begin
            f = joinpath(mktempdir(), "later.output")
            msgs = watch(Dict("path" => f, "offset" => 0, "until" => "closed");
                on_ready = () -> @async(begin
                    sleep(0.3)
                    run(pipeline(`sh -c "echo late"`; stdout = f, append = true))
                end))
            @test text(msgs) == "late\n" && done(msgs)
        end

        @testset "a task that already ended is done at once, with its output" begin
            f = tempname(); write(f, "all of it\n")
            msgs = watch(Dict("path" => f, "offset" => 4, "until" => "closed"); timeout = 5.0)
            @test text(msgs) == "of it\n" && done(msgs)
        end

        @testset "the server letting go ends the watch and its watcher" begin
            f = tempname()
            writer = run(pipeline(`sleep 300`; stdout = f, append = true); wait = false)
            fds() = length(readdir("/proc/self/fd"))
            try
                before = fds()
                msgs = watch(Dict("path" => f, "offset" => 0, "until" => "closed"); timeout = 1.0)
                @test !done(msgs)                       # the shell still runs
                @test timedwait(() -> fds() <= before, 5.0) === :ok   # inotify closed
            finally
                kill(writer)
            end
        end
    end

    @testset "a subagent's transcript is done at its end marker, also when split" begin
        f = tempname(); write(f, "{\"type\":\"assistant\",\"stop_rea")
        marker = "\"stop_reason\":\"end_turn\""
        msgs = watch(Dict("path" => f, "offset" => 0, "until" => "marker", "marker" => marker);
            on_ready = () -> @async(begin
                sleep(0.3); open(io -> write(io, "son\":\"tool_use\"}\n"), f, "a")
                sleep(0.3); open(io -> write(io, "{\"stop_reason\":\"end_"), f, "a")
                sleep(0.3); open(io -> write(io, "turn\"}\n"), f, "a")
            end))
        @test done(msgs)
        @test !any(m -> haskey(m, "chunk"), msgs)       # a transcript's bytes stay on the worker
    end

    @testset "file_writer_pids: the writer while it runs, nobody after" begin
        Sys.islinux() || return
        f = tempname()
        writer = run(pipeline(`sleep 300`; stdout = f, append = true); wait = false)
        pid = getpid(writer)
        try
            @test BW.file_writer_pids(f) == [pid]
        finally
            kill(writer); wait(writer)
        end
        @test isempty(BW.file_writer_pids(f))
        @test isempty(BW.file_writer_pids(tempname()))   # no such file
    end
end
