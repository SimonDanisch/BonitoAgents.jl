# Runs (runs.jl): every eval is a run with an id, and a run can outlive the tool
# call that started it. What is pinned here is the contract the agent and the
# chat rely on:
#
#   * `background = true` returns at once and the run keeps going;
#   * `bt_julia_wait` blocks on several runs, returns when any/all finished, and
#     hands back each finished run's result exactly once (collected);
#   * a second eval in a busy env is refused and names the running run;
#   * a turn cancel stops the foreground eval and leaves background runs alone;
#   * output the agent did not see is cut to the tail and names the whole log.
#
# All against real Malt sessions: the bugs this guards against lived in the
# hand-off between the collector, the session and the tool calls.

using Test
using BonitoMCP
const M = BonitoMCP
const JSON = M.JSON

text_of(r) = join((String(b["text"]) for b in r["content"] if get(b, "type", "") == "text"), "\n")
run_of(r) = r["_meta"]["run"]

# Fresh temp-session envs, so each testset starts with idle sessions.
fresh_env() = mktempdir()

# The server's end of the control channel: keeps what this process answers.
struct RecordingCtrlWS
    sent::Vector{Any}
end
M.WebSockets.send(ws::RecordingCtrlWS, x) = (push!(ws.sent, JSON.parse(String(x))); nothing)
ctrl_interrupt!(run) = begin
    ws = RecordingCtrlWS(Any[])
    M.handle_ctrl_frame!(ws, Dict{String,Any}("op" => "interrupt_eval", "request_id" => "q", "run" => run.id))
    only(ws.sent)
end

# Spins without ever yielding: neither the targeted throw nor SIGINT reaches it.
const SPIN = "function spin(); s = 0.0; while true; s += rand(); end; s; end; spin()"

@testset "runs" begin
    @testset "background eval returns at once, the run finishes on its own" begin
        env = fresh_env()
        t0 = time()
        r = M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(3); println(\"done sleeping\"); 40 + 2",
            "env_path" => env, "background" => true))
        @test time() - t0 < 30          # includes the session start, never the 3s sleep's end
        @test r["isError"] === false
        id = run_of(r)
        @test r["_meta"]["background"] === true
        @test occursin("run $id started", text_of(r))
        run = M.lookup_run(M.SERVER.runs, id)
        @test M.is_running(run)

        w = M.julia_wait_handler(Dict{String,Any}("runs" => [id], "seconds" => 60))
        @test w["isError"] === false
        t = text_of(w)
        @test occursin("1 of 1 run finished", t)
        @test occursin("done sleeping", t)
        @test occursin("42", t)
        @test w["_meta"]["runs"][id] == "passed"
        @test run.collected
        # Collected once: a wait with no runs named no longer includes it.
        @test id ∉ M.open_run_ids()
        M.restart!(M.manager(), env)
    end

    @testset "under BonitoAgents too: refused at once, not after the run" begin
        # With a relay grant every eval first brings up the live-render bridge,
        # under the session lock the running run's collector keeps taking; the
        # refusal used to come only when the run had ended.
        prev = M.SERVER.control.grant
        M.SERVER.control.grant = M.RelayGrant("ws://127.0.0.1:1", "control", "eval", "")
        try
            env = fresh_env()
            r = M.julia_eval_handler(Dict{String,Any}(
                "code" => "sleep(20)", "env_path" => env, "background" => true))
            id = run_of(r)
            t0 = time()
            busy = M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))
            @test time() - t0 < 5
            @test busy["isError"] === true
            @test occursin("run $id is still running", text_of(busy))
            M.julia_interrupt_handler(Dict{String,Any}("run" => id))
            M.restart!(M.manager(), env)
        finally
            M.SERVER.control.grant = prev
        end
    end

    @testset "a second eval in a busy env is refused and names the run" begin
        env = fresh_env()
        r = M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(30)", "env_path" => env, "background" => true))
        id = run_of(r)
        busy = M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))
        @test busy["isError"] === true
        @test occursin("run $id is still running", text_of(busy))
        @test occursin("bt_julia_wait(runs = [\"$id\"])", text_of(busy))
        stop = M.julia_interrupt_handler(Dict{String,Any}("run" => id))
        @test stop["_meta"]["status"] == "completed"
        run = M.lookup_run(M.SERVER.runs, id)
        @test run.status === :interrupted
        # The env is free again.
        @test M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))["_meta"]["status"] == "completed"
        M.restart!(M.manager(), env)
    end

    @testset "wait any / all over several runs" begin
        envs = [fresh_env() for _ in 1:3]
        ids = [run_of(M.julia_eval_handler(Dict{String,Any}(
                   "code" => "sleep($(s)); $(s)", "env_path" => e, "background" => true)))
               for (e, s) in zip(envs, (1, 4, 30))]
        w = M.julia_wait_handler(Dict{String,Any}("runs" => ids, "until" => "any", "seconds" => 60))
        @test w["_meta"]["runs"][ids[1]] == "passed"
        @test w["_meta"]["runs"][ids[3]] == "running"
        @test occursin("still running", text_of(w))
        # "all" with a bound shorter than the slowest run: a normal result, not an error.
        w2 = M.julia_wait_handler(Dict{String,Any}("runs" => ids[2:3], "seconds" => 8))
        @test w2["isError"] === false
        @test w2["_meta"]["runs"][ids[2]] == "passed"
        @test w2["_meta"]["runs"][ids[3]] == "running"
        @test occursin("call bt_julia_wait again", text_of(w2))
        M.julia_interrupt_handler(Dict{String,Any}("run" => ids[3]))
        # Asking for a run that does not exist is an error that says so.
        bad = M.julia_wait_handler(Dict{String,Any}("runs" => ["r99999"], "seconds" => 1))
        @test bad["isError"] === true
        @test occursin("no run named r99999", text_of(bad))
        foreach(e -> M.restart!(M.manager(), e), envs)
    end

    @testset "a cancel stops the foreground eval, not the background runs" begin
        bg_env, fg_env = fresh_env(), fresh_env()
        bg = run_of(M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(20); :bg", "env_path" => bg_env, "background" => true)))
        fg = M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(60); :fg", "env_path" => fg_env, "timeout" => 1))
        @test fg["_meta"]["status"] == "running"
        fg_run = M.lookup_run(M.SERVER.runs, run_of(fg))
        # An untracked request id: the fallback that used to stop EVERYTHING.
        M.handle_cancelled!(Dict("params" => Dict("requestId" => "not-tracked")))
        @test M.wait_run(fg_run, 30.0)
        @test fg_run.status === :interrupted
        bg_run = M.lookup_run(M.SERVER.runs, bg)
        @test M.is_running(bg_run)
        @test M.wait_run(bg_run, 60.0)
        @test bg_run.status === :passed
        M.restart!(M.manager(), bg_env); M.restart!(M.manager(), fg_env)
    end

    @testset "output the agent did not see is cut to the tail and names the log" begin
        env = fresh_env()
        r = M.julia_eval_handler(Dict{String,Any}(
            "code" => "for i in 1:2000; println(\"line \", i); end; :ok",
            "env_path" => env, "max_response_bytes" => 500, "timeout" => 120))
        t = text_of(r)
        @test r["_meta"]["status"] == "completed"
        @test occursin("line 2000", t)
        @test !occursin("line 1\n", t)
        run = M.lookup_run(M.SERVER.runs, run_of(r))
        @test occursin(run.log_path, t)
        log = read(run.log_path, String)
        @test occursin("line 1\n", log) && occursin("line 2000", log)
        M.restart!(M.manager(), env)
    end

    @testset "a parse error is a finished, failed run" begin
        env = fresh_env()
        r = M.julia_eval_handler(Dict{String,Any}("code" => "1 +", "env_path" => env))
        @test r["_meta"]["status"] == "completed"
        @test occursin("ParseError", text_of(r))
        @test M.lookup_run(M.SERVER.runs, run_of(r)).status === :failed
        M.restart!(M.manager(), env)
    end

    @testset "a failure's first line is its summary" begin
        env = fresh_env()
        r = M.julia_eval_handler(Dict{String,Any}(
            "code" => "error(\"Some tests did not pass: 3 passed, 1 failed\")", "env_path" => env))
        run = M.lookup_run(M.SERVER.runs, run_of(r))
        @test run.status === :failed
        @test run.summary == "Some tests did not pass: 3 passed, 1 failed"
        @test occursin("failed after", M.run_line(run))
        M.restart!(M.manager(), env)
    end

    @testset "listing sessions lists the open runs" begin
        env = fresh_env()
        id = run_of(M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(20)", "env_path" => env, "background" => true)))
        t = text_of(M.julia_list_sessions_handler(Dict{String,Any}()))
        @test occursin("runs:", t)
        @test occursin("$(id)  running for", t)
        M.julia_interrupt_handler(Dict{String,Any}("run" => id))
        M.restart!(M.manager(), env)
    end

    # A run must end, whatever happens to it: one left "running" holds its
    # chat's task-bar row for good, every wait on it times out, and neither its
    # ⊗ nor a restart of its session could end it (MacBook, 2026-10-08).
    if ispath("/dev/full")
        @testset "a full disk ends the run's log, not the run" begin
            # A full disk fails the flush (ENOSPC), not the buffered write. It
            # killed the collector, and the finished eval stayed "running".
            env = fresh_env()
            id = run_of(M.julia_eval_handler(Dict{String,Any}(
                "code" => "for i in 1:6; println(\"line \$i\"); sleep(0.5); end; 42",
                "env_path" => env, "background" => true)))
            run = M.lookup_run(M.SERVER.runs, id)
            @lock run.lock begin
                close(run.log)
                run.log = open("/dev/full", "w")
            end
            @test M.wait_run(run, 60.0)
            @test run.status === :passed
            @test occursin("stopped", String(copy(run.tail)))     # says where the log ended
            @test occursin("42", text_of(M.collected_response(run)))
            M.restart!(M.manager(), env)
        end
    end

    @testset "a run that cannot have a log is refused before its eval starts" begin
        # Opened after the eval started, a failing log left that eval going in
        # the session with no run and no collector ("EVAL IN FLIGHT", for good).
        env = fresh_env()
        dir = M.run_logs_dir(M.SERVER.runs)
        chmod(dir, 0o500)
        r = try
            M.julia_eval_handler(Dict{String,Any}("code" => "sleep(30)", "env_path" => env, "background" => true))
        finally
            chmod(dir, 0o700)
        end
        @test r["isError"] === true
        s = M.manager().sessions[M._key(env)]
        @test s.in_flight === nothing
        # The env takes the next eval.
        @test occursin("2", text_of(M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))))
        M.restart!(M.manager(), env)
    end

    @testset "a restart ends the run going in its session" begin
        env = fresh_env()
        id = run_of(M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(60)", "env_path" => env, "background" => true)))
        run = M.lookup_run(M.SERVER.runs, id)
        t = text_of(M.julia_restart_handler(Dict{String,Any}("env_path" => env)))
        @test occursin("Run $(id) was stopped with it", t)
        @test run.status === :interrupted
        @test occursin("its session was restarted", run.result.echo)
    end

    @testset "the chat's stop of a run whose session is gone ends it, and is answered" begin
        # The session died under the run. The stop threw on the dead worker and
        # sent no answer, so the server waited 15s and called the worker
        # unreachable, and the run stayed.
        env = fresh_env()
        id = run_of(M.julia_eval_handler(Dict{String,Any}(
            "code" => "sleep(60)", "env_path" => env, "background" => true)))
        run = M.lookup_run(M.SERVER.runs, id)
        M.kill_session!(run.session)
        reply = ctrl_interrupt!(run)
        @test reply["request_id"] == "q" && reply["interrupted"] == 1 && !haskey(reply, "error")
        @test run.status === :interrupted
        M.restart!(M.manager(), env)
    end

    @testset "an interrupt the eval cannot see ends the run by killing its session" begin
        # Code that computes, or waits in C, never sees the interrupt: the tool
        # waited 30s, answered "still running", and the run went on.
        env = fresh_env()
        id = run_of(M.julia_eval_handler(Dict{String,Any}(
            "code" => SPIN, "env_path" => env, "background" => true)))
        run = M.lookup_run(M.SERVER.runs, id)
        sleep(2)
        t0 = time()
        r = M.julia_interrupt_handler(Dict{String,Any}("run" => id))
        @test time() - t0 < M.RUN_KILL_GRACE_S + 5
        @test run.status === :interrupted
        @test occursin("so its session was killed", text_of(r))
        @test !M.is_alive(run.session)
        # The env is free at once for the next eval.
        @test occursin("2", text_of(M.julia_eval_handler(Dict{String,Any}("code" => "1 + 1", "env_path" => env))))
        M.restart!(M.manager(), env)
    end

    @testset "the chat's stop of a busy run is answered at once, and the run ends" begin
        env = fresh_env()
        id = run_of(M.julia_eval_handler(Dict{String,Any}(
            "code" => SPIN, "env_path" => env, "background" => true)))
        run = M.lookup_run(M.SERVER.runs, id)
        sleep(2)
        t0 = time()
        reply = ctrl_interrupt!(run)
        @test time() - t0 < 5                    # well under the server's 15s wait
        @test reply["interrupted"] == 1
        @test M.wait_run(run, M.RUN_KILL_GRACE_S + 10)
        @test run.status === :interrupted
        M.restart!(M.manager(), env)
    end
end
