# A background shell's output reaches its card while the shell writes it, and
# the shell's exit ends its task: both reported by the worker following the
# output file (BonitoWorker file_watch.jl). The server used to ask the worker
# once a second per task, and each answer scanned every process on the machine.
@testitem "e2e:background_shell" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    out = joinpath(mktempdir(), "bg.output")
    id = "bgsh-$(rand(UInt32))"
    shell = Ref{Base.Process}()
    # The agent starts the shell with its redirect, as claude-agent-acp does, and
    # names the output file in the tool's result.
    s.agent_fn[] = _ -> begin
        shell[] = run(pipeline(`sh -c "echo first-line; sleep 3; echo second-line; sleep 2"`;
                               stdout = out, append = true); wait = false)
        [TK.tool(kind = "execute", tool_name = "Bash", title = "a background shell", id = id,
                 raw_input = Dict("command" => "sh -c ...", "run_in_background" => true),
                 content = Any[Dict("type" => "text", "text" =>
                     "Command running in background with ID: $(id). Output is being written to: $(out)")]),
         TK.text("launched"), TK.end_turn()]
    end
    TK.new_chat(s; title = "BgShell")
    TK.send_message(s, "start it")

    slot = "document.querySelector('.bt-taskbar-slot[data-task-id=\"$(id)\"]')"
    card = "[...document.querySelectorAll('.bt-tool-msg')].find(c => (c.dataset.msgId || '').includes('$(id)'))"
    summary = "($(card)?.querySelector('.bt-tool-summary')?.textContent || '')"
    @test TK.wait_for(s, "the task in the bar", "!!$(slot)"; timeout = 60) == true
    # The first line is there while the shell still runs.
    @test TK.wait_for(s, "the first line streamed", "$(summary).includes('1 line')"; timeout = 15) == true
    @test process_running(shell[])
    @test TK.wait_for(s, "the second line streamed", "$(summary).includes('2 lines')"; timeout = 15) == true
    # The shell exits: its task is done, and waits for the agent to report on it.
    @test TK.wait_for(s, "the shell's exit ends the task",
        "($(slot)?.querySelector('.bt-taskbar-activity')?.textContent || '').includes('finished')"; timeout = 20) == true
    @test process_exited(shell[])
    s.agent_fn[] = S.default_agent
end
