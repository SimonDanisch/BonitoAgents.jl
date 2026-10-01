# A worker that crashes in the middle of a chat's turn: when it is back, that
# chat, and only that chat, carries on by itself (crash_recovery.jl).
#
#   1. a chat mid-turn and an idle chat; the worker is killed (SIGKILL: no exit
#      handler runs, as in an out-of-memory kill or a segfault) and started again.
#      The busy chat gets the one automatic "carry on" message and the agent's
#      answer; the idle chat gets nothing;
#   2. a worker STOPPED (SIGTERM, a service stop) mid-turn continues nothing;
#   3. a stop clicked while the worker is down means the chat is not continued;
#   4. a dropped connection (same worker process) just resumes: the turn ends
#      normally, nothing is added;
#   5. a crash during the automatic continuation is not continued again.
#
# Real worker processes (killed and restarted the way a machine would), the real
# dev_server and browser, the mock agent. Own dev server: its worker gets killed.
@testitem "e2e:worker_crash" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    import BonitoAgents as BT
    BW = BT.BonitoWorker

    CRASH = "crashed while you were working"
    slow_continue = Ref(false)
    function agent(prompt)
        if occursin(CRASH, prompt)
            return slow_continue[] ?
                [TK.text("continuing slowly "), TK.delay(120_000), TK.end_turn()] :
                [TK.text("picked up after the crash"), TK.end_turn()]
        elseif occursin("long task", prompt)
            return [TK.text("working on it "), TK.delay(120_000), TK.text("done"), TK.end_turn()]
        elseif occursin("short task", prompt)
            return [TK.text("short task running "), TK.delay(12_000), TK.text("finished short"), TK.end_turn()]
        end
        return [TK.text("echo: $(prompt)"), TK.end_turn()]
    end

    z = TK.dev_server(; agent)
    try
        TK.open_browser(z)
        state = z.h.state
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        wid = only(keys(state.workers[]))

        P(pid) = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
        shows(pid, text) = "[...document.querySelectorAll('$(P(pid)).bt-agent-msg')].some(e => e.innerText.includes($(repr(text))))"
        crash_notes(pid) = "[...document.querySelectorAll('$(P(pid)).bt-user-msg-auto')].filter(e => e.innerText.includes($(repr(CRASH)))).length"
        busy(pid) = "!!document.querySelector('$(P(pid)).bt-busy.bt-busy-active')"
        function send!(pid, text)
            TK.open_chat(z, pid)
            TK.wait_for(z, "the input of $(pid)", "!!document.querySelector('$(P(pid)).bt-text-input')"; timeout = 30)
            TK.set_input(z, "$(P(pid)).bt-text-input", text)
            TK.click(z, "$(P(pid)).bt-send-btn")
        end
        function kill_worker!()
            proc = z.h.worker_proc
            TK.kill_worker!(z)
            @test timedwait(() -> !process_running(proc), 30) === :ok
            @test timedwait(() -> !BT.worker_connected(state, wid), 30) === :ok
        end
        function start_worker!()
            proc, _ = BW.spawn_worker()
            @test proc !== nothing
            z.h.worker_proc = proc
            @test timedwait(() -> BT.worker_connected(state, wid), 180) === :ok
        end

        idle = TK.new_chat(z; cwd = mkpath(joinpath(mktempdir(), "idlechat")))
        send!(idle, "hello")
        @test TK.wait_for(z, "the idle chat answered", shows(idle, "echo: hello"); timeout = 60) == true
        busy_chat = TK.new_chat(z; cwd = mkpath(joinpath(mktempdir(), "busychat")))

        @testset "a crash mid-turn: that chat carries on, the idle one does not" begin
            send!(busy_chat, "long task")
            @test TK.wait_for(z, "the turn is under way", shows(busy_chat, "working on it"); timeout = 60) == true
            kill_worker!()
            start_worker!()
            @test TK.wait_for(z, "the automatic message", "$(crash_notes(busy_chat)) === 1"; timeout = 120) == true
            @test TK.wait_for(z, "the agent carried on", shows(busy_chat, "picked up after the crash"); timeout = 120) == true
            TK.open_chat(z, idle)
            @test TK.wait_for(z, "the idle chat is shown", "!!document.querySelector('$(P(idle)).bt-text-input')"; timeout = 30) == true
            @test TK.eval_js(z, crash_notes(idle)) == 0
            @test isempty(state.crash_watch.interrupted)
        end

        @testset "a worker stopped mid-turn continues nothing" begin
            send!(busy_chat, "long task")
            @test TK.wait_for(z, "the second turn is under way", busy(busy_chat); timeout = 60) == true
            BW.stop_running_worker!()          # SIGTERM, what a service stop sends
            @test timedwait(() -> !BT.worker_connected(state, wid), 30) === :ok
            start_worker!()
            sleep(15)                          # time enough for a continuation to show
            @test TK.eval_js(z, crash_notes(busy_chat)) == 1
            send!(busy_chat, "after the stop")
            @test TK.wait_for(z, "the chat works as before", shows(busy_chat, "echo: after the stop"); timeout = 120) == true
        end

        @testset "a stop clicked while the worker is down: not continued" begin
            send!(busy_chat, "long task")
            @test TK.wait_for(z, "the third turn is under way", busy(busy_chat); timeout = 60) == true
            kill_worker!()
            @test haskey(state.crash_watch.interrupted, busy_chat)
            TK.click(z, "$(P(busy_chat)).bt-stop-btn")
            @test timedwait(() -> !haskey(state.crash_watch.interrupted, busy_chat), 10) === :ok
            start_worker!()
            sleep(15)
            @test TK.eval_js(z, crash_notes(busy_chat)) == 1
        end

        @testset "a dropped connection resumes the turn, nothing added" begin
            send!(busy_chat, "short task")
            @test TK.wait_for(z, "the short turn is under way", shows(busy_chat, "short task running"); timeout = 60) == true
            TK.drop_worker_connection!(z)
            @test TK.wait_for(z, "the turn finished by itself", shows(busy_chat, "finished short"); timeout = 90) == true
            @test TK.eval_js(z, crash_notes(busy_chat)) == 1
            @test isempty(state.crash_watch.interrupted)
        end

        @testset "a crash during the continuation is not continued again" begin
            slow_continue[] = true
            send!(busy_chat, "long task")
            @test TK.wait_for(z, "the fifth turn is under way", busy(busy_chat); timeout = 60) == true
            kill_worker!()
            start_worker!()
            @test TK.wait_for(z, "the second automatic message", "$(crash_notes(busy_chat)) === 2"; timeout = 120) == true
            @test TK.wait_for(z, "the continuation is under way", shows(busy_chat, "continuing slowly"); timeout = 120) == true
            kill_worker!()
            start_worker!()
            sleep(15)
            @test TK.eval_js(z, crash_notes(busy_chat)) == 2
        end
        @test isempty(TK.js_errors(z))
    finally
        close(z)
    end
end
