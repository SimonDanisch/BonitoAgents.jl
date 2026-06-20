# End-to-end of the background-task STOP path through a REAL worker subprocess:
#   request_tool_stop! → kill_worker_file_writers (WS command to the worker) →
#   worker handle_kill_file_writers (SIGTERM the fd holders + tree) → the held
#   process actually dies. Plus the pill-finalize side (finalize_bg_task!).
#
# This covers the code I shipped that the unit tests do NOT: the WS RPC
# round-trip (client send_command ↔ worker dispatch) and the full stop wiring.
# Pure Julia + a spawned worker subprocess (no Electron / agent).
using Test, Dates
import BonitoAgents, BonitoWorker
const BT = BonitoAgents

@testset "background-task stop: kill via real worker RPC" begin
    h = BT.dev_server(; port = 0)
    try
        # Wait for the worker to register on the control WS.
        @test timedwait(() -> !isempty(h.state.workers[]), 40.0) === :ok
        wid = first(keys(h.state.workers[]))

        # A real output file held open by a real child process (stands in for
        # the SDK's background shell). The worker (same machine) will find it
        # via its /proc fd scan.
        dir  = mktempdir(h.working_dir)
        path = joinpath(dir, "task.output")
        write(path, "launch banner\n")
        proc = run(pipeline(`bash -c "exec sleep 120"`; stdout = path, append = true);
                   wait = false)
        proc_pid = getpid(proc)   # capture BEFORE kill — the proc dies fast
        @test timedwait(() -> !isempty(BonitoWorker.file_writer_pids(path)), 5.0) === :ok

        @testset "kill_worker_file_writers RPC SIGTERMs the holder" begin
            r = BT.kill_worker_file_writers(h.state, wid, path)
            @test r.supported                      # Linux worker
            @test proc_pid in r.killed
            @test timedwait(() -> process_exited(proc), 8.0) === :ok
        end

        @testset "request_tool_stop! kills + finalizes the pill (no chat msg)" begin
            # A second real held-open process + a chat whose project is on this
            # worker, so bg_worker_id resolves to it.
            path2 = joinpath(dir, "task2.output")
            write(path2, "banner\n")
            proc2 = run(pipeline(`bash -c "exec sleep 120"`; stdout = path2, append = true);
                        wait = false)
            @test timedwait(() -> !isempty(BonitoWorker.file_writer_pids(path2)), 5.0) === :ok

            # The chat must be a project bound to this worker so bg_worker_id
            # finds it. Reuse the dev_server's state; register a project row.
            pid = "p-kill"
            h.state.projects[][pid] = BT.ProjectInfo(pid, "kill", wid, dir, dir, now(UTC))
            model = BT.ChatModel(h.state, mktempdir();
                                 project_id = pid,
                                 transport = BT.MockTransport((o, i) -> nothing))

            t = BT.BashToolMsg("bgk", "execute", "monitor", "completed", "",
                               time(), nothing, "sleep 120", "Monitor", true,
                               path2, 0, true, "", model)
            push!(model.msgs_store, t)
            BT.pin_task!(model, BT.tool_taskbar_item(model, t))
            @test BT.is_pinned(model, "bgk")

            BT.handle_command!(model, nothing, BT.StopToolCommand("bgk"))

            @test isempty(filter(m -> m isa BT.UserMsg, model.msgs_store))  # NO synthetic msg
            @test !t.bg_running                          # pill finalized
            @test t.status == "completed"
            @test !BT.is_pinned(model, "bgk")            # unpinned
            @test timedwait(() -> process_exited(proc2), 8.0) === :ok  # process really died
        end
    finally
        close(h)
    end
end
