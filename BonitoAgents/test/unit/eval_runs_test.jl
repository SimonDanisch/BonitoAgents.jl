@testitem "unit:eval_runs" tags = [:unit] begin

# The chat's side of Julia runs (eval_runs.jl), fed the `run_update` frames an
# MCP process sends: which card a run belongs to, that the card follows the RUN
# (live, in the bar, its result) rather than the call that returned at once, and
# when it may leave the bar. The e2e item (e2e:eval_runs) drives the same frames
# from real processes; here each rule is pinned on its own.

using Test
using BonitoAgents
import Bonito, HTTP, JSON
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

state = BT.serve(; host = "127.0.0.1", port = 0,
                 state_dir = mktempdir(), working_dir = mktempdir())
model = BT.ChatModel(state, mktempdir(); project_id = "proj",
                     agent = BT.WorkerAgent(state, "w1", "/p"))
lock(state.lock) do; state.chat_models["proj"] = model; end

function card(id, raw; status = "pending")
    m = BT.JuliaEvalToolMsg(BT.Message(id, "other", "bt_julia_eval", "bt_julia_eval",
                                       status, "", time(), nothing, model), "btworker")
    BT.apply_input!(m, Dict{String,Any}(raw))
    lock(model.lock) do; push!(model.msgs_store, m); end
    return m
end
frame(id; kw...) = Dict{String,Any}("type" => "run_update", "run" => id,
                                    (String(k) => v for (k, v) in kw)...)
running(id, env; kw...) = frame(id; status = "running", route = abspath(env), env_path = env,
                                started = time(), kw...)

# A run's process, as the server's channel to it: answers every interrupt with
# `reply`, and counts them.
struct FakeRunProcess
    state::Any
    reply::Dict{String,Any}
    asked::Base.RefValue{Int}
end
FakeRunProcess(state, reply) = FakeRunProcess(state, Dict{String,Any}(reply), Ref(0))
function HTTP.WebSockets.send(p::FakeRunProcess, frame::AbstractString)
    p.asked[] += 1
    rid = String(JSON.parse(frame)["request_id"])
    @async BT.deliver_rpc_response!(p.state, rid, copy(p.reply))
    return nothing
end
BT.untrack_mcp_request!(::FakeRunProcess, rid) = nothing
function host_process!(worker, reply)
    p = FakeRunProcess(state, reply)
    lock(state.lock) do; state.eval_hosts[BT.eval_host_key("proj", worker)] = p; end
    return p
end

try
    @testset "a run finds its card by the tool id Claude names" begin
        a = card("toolu_A", ("code" => "1", "env_path" => "/tmp/envA", "background" => true))
        b = card("toolu_B", ("code" => "2", "env_path" => "/tmp/envA"))   # same env, newer
        @test a.background
        BT.run_update!(state, "proj", "", running("r1", "/tmp/envA";
                       background = true, tool_use_id = "toolu_A"))
        @test a.run !== nothing && a.run.id == "r1"
        @test b.run === nothing
        @test BT.run_live(a) && BT.is_live(a)
        # A background run is in the bar from the start; its header reads live.
        @test BT.in_taskbar(a)
        d = Dict{String,Any}("status" => "completed", "finished_at" => 1.0)
        BT.run_header_extras!(d, a)
        @test d["status"] == "in_progress" && !haskey(d, "finished_at") && d["taskbar"] === true
        @test occursin("r1 · running", BT.eval_env_summary(a))
        # The chat's own worker goes unnamed (the row is narrow); others are named.
        @test BT.taskbar_label(a) == "r1 · tmp/envA"
        # While it runs, the call's own result (the start notice) is not its result.
        @test BT.result_content(a, Any[ACP.TextContent("run r1 started")]) === nothing
    end

    @testset "without a tool id: the newest unbound card on the same worker and env" begin
        old = card("anon-old", ("code" => "1", "env_path" => "/tmp/envC", "worker" => "worker-b"))
        new = card("anon-new", ("code" => "2", "env_path" => "/tmp/envC", "worker" => "worker-b"))
        here = card("anon-here", ("code" => "3", "env_path" => "/tmp/envC"))   # the chat's own worker
        BT.run_update!(state, "proj", "worker-b", running("r7", "/tmp/envC"))
        @test new.run !== nothing && new.run.id == "r7"
        @test old.run === nothing && here.run === nothing
        @test new.run.worker_id == "worker-b"
        @test BT.taskbar_label(new) == "r7 · worker-b · tmp/envC"
    end

    @testset "a run announced before its card exists is adopted by the card" begin
        # The run's frames and the call's travel separate roads; the run can win.
        BT.run_update!(state, "proj", "", running("r3", "/tmp/envE"; background = true,
                                                  tool_use_id = "toolu_E"))
        early = BT.shared(model).runs.runs["r3"]
        @test early.card === nothing
        e = card("toolu_E", ("code" => "3", "env_path" => "/tmp/envE", "background" => true))
        BT.adopt_run!(e)
        @test e.run === early && early.card === e
        @test BT.in_taskbar(e)
    end

    @testset "a foreground run takes a bar slot only once its call is over" begin
        f = card("toolu_F", ("code" => "sleep(99)", "env_path" => "/tmp/envF"))
        BT.run_update!(state, "proj", "", running("r2", "/tmp/envF"; tool_use_id = "toolu_F"))
        @test BT.run_live(f) && !BT.is_taskbar_item(f)      # the call is still open
        f.message.status = "completed"                       # it returned at its checkpoint
        @test BT.is_taskbar_item(f)
    end

    @testset "the run's end is the card's result, and it leaves the bar once collected" begin
        a = only(m for m in model.msgs_store if m isa BT.JuliaEvalToolMsg && BT.tool_id(m) == "toolu_A")
        BT.run_update!(state, "proj", "", frame("r1"; status = "failed", route = abspath("/tmp/envA"),
            env_path = "/tmp/envA", background = true, started = a.run.started, elapsed = 3.0,
            summary = "Some tests did not pass: 3 passed, 1 failed",
            content = Any[Dict("type" => "text", "text" => "tick\nERROR: Some tests did not pass")]))
        @test !BT.run_live(a)
        @test a.message.status == "completed"
        rc = BT.result_content(a, Any[ACP.TextContent("run r1 started")])
        @test rc isa AbstractVector && occursin("tick", only(rc).text)
        @test isfile(BT.run_content_file(model.chat_dir, "toolu_A"))
        @test occursin("r1 · ✗ failed after 3s — Some tests did not pass: 3 passed, 1 failed",
                       BT.eval_env_summary(a))
        @test occursin("tick", a.stream_text[])
        # Finished, not yet collected: still in the bar, saying how it ended.
        @test !BT.isdone(a)
        @test startswith(BT.taskbar_activity(a, time()), "✗ failed")
        BT.run_update!(state, "proj", "", frame("r1"; collected = true))
        @test BT.isdone(a)
        # After a restart the result comes from its file.
        a.run = nothing
        @test occursin("tick", only(BT.result_content(a, Any[])).text)
    end

    @testset "a process that does not come back loses its running runs" begin
        g = card("toolu_G", ("code" => "sleep(99)", "env_path" => "/tmp/envG", "worker" => "worker-g",
                             "background" => true))
        BT.run_update!(state, "proj", "worker-g", running("r8", "/tmp/envG"; background = true,
                                                         tool_use_id = "toolu_G"))
        @test BT.run_live(g)
        BT.runs_channel_closed!(state, "proj", "worker-g"; grace = 0.1)
        @test timedwait(() -> !BT.run_live(g), 10.0) === :ok
        @test g.run.status == "lost"
        @test occursin("✗ lost", BT.eval_env_summary(g))
        # The chat's OWN process going away touches only its own runs.
        @test BT.shared(model).runs.runs["r2"].status == "running"
    end

    @testset "a continue says what it waits on, and leads back to it" begin
        cont(id, raw; status = "pending") = begin
            m = BT.JuliaContinueToolMsg(BT.Message(id, "other", "bt_julia_continue", "bt_julia_continue",
                                                   status, "", time(), nothing, model), "btworker")
            BT.apply_input!(m, Dict{String,Any}(raw))
            lock(model.lock) do; push!(model.msgs_store, m); end
            m
        end
        suite = card("toolu_S", ("code" => "\n  using Pkg; Pkg.test(\"Foo\")\nmore", "env_path" => "/tmp/envS"))
        BT.run_update!(state, "proj", "", running("r20", "/tmp/envS"; tool_use_id = "toolu_S"))
        other = card("toolu_O", ("code" => "1+1", "env_path" => "/tmp/elsewhere"))
        # By env (how agents address it most of the time): the newest eval
        # card before it on the same worker and env, not simply the newest one.
        c = cont("cont-1", ("env_path" => "/tmp/envS",))
        @test BT.continued_eval(c) === suite
        @test BT.continue_summary(c) == "↳ r20 · using Pkg; Pkg.test(\"Foo\")"
        d = Dict{String,Any}()
        BT.jump_extras!(d, c)
        j = only(d["jumps"])
        @test j["label"] == "r20" && j["id"] == "toolu_S"
        @test j["index"] == findfirst(x -> x === suite, model.msgs_store) - 1
        @test d["summary"] == "↳ r20 · using Pkg; Pkg.test(\"Foo\")"
        # While it blocks, the run's row says the agent is waiting on it.
        @test BT.awaited(suite)
        @test BT.taskbar_activity(suite, time()) == "agent waiting"
        c.message.status = "completed"
        @test !BT.awaited(suite)
        @test BT.continue_summary(c) == "↳ r20 · using Pkg; Pkg.test(\"Foo\") · still running"
        # By run id: exactly that run; an unknown one is not guessed at.
        @test BT.continued_eval(cont("cont-2", ("run" => "r20",); status = "completed")) === suite
        @test BT.continued_eval(cont("cont-3", ("run" => "r999",); status = "completed")) === nothing
        @test BT.continued_eval(cont("cont-4", ("env_path" => "/tmp/nowhere",); status = "completed")) === nothing
        # A wait leads to each of its runs.
        w = BT.JuliaWaitToolMsg(BT.Message("wait-1", "other", "bt_julia_wait", "bt_julia_wait",
                                           "pending", "", time(), nothing, model), "btworker")
        BT.apply_input!(w, Dict{String,Any}("runs" => ["r20", "r7"]))
        lock(model.lock) do; push!(model.msgs_store, w); end
        @test Set(BT.tool_id.(BT.waited_evals(w))) == Set(["toolu_S", "anon-new"])
        dw = Dict{String,Any}()
        BT.jump_extras!(dw, w)
        @test sort([x["label"] for x in dw["jumps"]]) == ["r20", "r7"]
        @test BT.awaited(suite)
        w.message.status = "completed"
        @test !BT.awaited(suite)
        @test other.run === nothing
    end

    @testset "the note to the agent names the runs and how to collect them" begin
        r = BT.ChatRun("r9", "", "", "", "/home/me/pkg/Foo/test", true, 0.0, "passed", 125.0, "",
                       false, false, Any[], nothing)
        t = BT.run_note_text(model, [r])
        @test startswith(t, "Background Julia run finished: r9 (Foo/test on this worker): ✓ passed after 2m5s")
        @test occursin("bt_julia_wait(runs = [\"r9\"], seconds = 60)", t)
        two = BT.run_note_text(model, [r, BT.ChatRun("r10", "", "", "", "", true, 0.0, "failed", 4.0,
                                                    "boom", false, false, Any[], nothing)])
        @test occursin("- r10 (temp env on this worker): ✗ failed after 4s — boom", two)
        @test occursin("[\"r9\", \"r10\"]", two)
    end

    @testset "the live tail never lands on top of the complete output" begin
        # The tail is drained on a thread of its own and stripped of color, and
        # the call can end between its check and its write: `Pkg.status()` came
        # out without color now and then (e2e:bt_eval_types, st-pkg).
        m = card("toolu_tail", ("code" => "Pkg.status()", "env_path" => "/tmp/envT"); status = "in_progress")
        colored = "\e[90m[824d6782]\e[39m Bonito\n"
        BT.append_tail!(m, colored)
        @test m.stream_text[] == "[824d6782] Bonito\n"          # the tail is plain
        m.message.status = "completed"
        BT.eval_result!(m, Any[ACP.TextContent(colored)])
        @test m.stream_text[] == colored
        BT.append_tail!(m, "\e[90mlate\e[39m chunk\n")           # drained after the end
        @test m.stream_text[] == colored
    end

    @testset "an id a restarted MCP gives out again is a new run, on its own card" begin
        # Ids count per MCP process and a chat outlives its MCP's restarts. The
        # new process's r20 was taken for the old r20: it reopened yesterday's
        # card in history and took the bar with that card's start time.
        t_old = time() - 86_400
        old = card("toolu_old20", ("code" => "1", "env_path" => "/tmp/envR", "background" => true);
                   status = "completed")
        BT.run_update!(state, "proj", "", running("r20", "/tmp/envR"; background = true,
                                                  tool_use_id = "toolu_old20", started = t_old))
        BT.run_update!(state, "proj", "", frame("r20"; status = "passed", route = abspath("/tmp/envR"),
            env_path = "/tmp/envR", background = true, started = t_old, elapsed = 2.0,
            content = Any[Dict("type" => "text", "text" => "yesterday's result")]))
        BT.run_update!(state, "proj", "", frame("r20"; collected = true, started = t_old))
        @test old.run.status == "passed" && old.run.collected
        new = card("toolu_new20", ("code" => "2", "env_path" => "/tmp/envR", "background" => true))
        BT.run_update!(state, "proj", "", running("r20", "/tmp/envR"; background = true,
                                                  tool_use_id = "toolu_new20"))
        @test new.run !== nothing && new.run.id == "r20" && new.run !== old.run
        @test BT.run_live(new) && BT.in_taskbar(new)
        # The old card was not reopened: it stays finished and leaves the bar.
        @test old.run.status == "passed" && !BT.run_live(old)
        @test old.message.status == "completed" && BT.isdone(old)
        # The id now means the new run.
        @test BT.shared(model).runs.runs["r20"] === new.run
        # A late word about the old one (its "collected", announced again by its
        # process) reaches neither: the new run is still running, uncollected.
        BT.run_update!(state, "proj", "", frame("r20"; collected = true, started = t_old))
        @test !new.run.collected
    end

    @testset "two live runs with one id keep their own frames" begin
        # The old r21 still runs on a worker after the chat's MCP restarted, and
        # the new MCP's r21 starts on another.
        t_old = time() - 3_600
        a = card("toolu_a21", ("code" => "1", "env_path" => "/tmp/envS", "worker" => "worker-x",
                               "background" => true))
        BT.run_update!(state, "proj", "worker-x", running("r21", "/tmp/envS"; background = true,
                                                          tool_use_id = "toolu_a21", started = t_old))
        b = card("toolu_b21", ("code" => "2", "env_path" => "/tmp/envS", "worker" => "worker-y",
                               "background" => true))
        BT.run_update!(state, "proj", "worker-y", running("r21", "/tmp/envS"; background = true,
                                                          tool_use_id = "toolu_b21"))
        @test a.run !== b.run && BT.run_live(a) && BT.run_live(b)
        BT.run_update!(state, "proj", "worker-x", frame("r21"; status = "failed", route = abspath("/tmp/envS"),
            env_path = "/tmp/envS", background = true, started = t_old, elapsed = 3600.0))
        @test a.run.status == "failed" && BT.run_live(b)
        @test a.run.worker_id == "worker-x" && b.run.worker_id == "worker-y"
    end

    @testset "a process that comes back without a run loses it" begin
        # Back within the grace is not enough: a restarted process comes back at
        # once and knows none of the old runs. Only what it announces again stays.
        kept = card("toolu_kept", ("code" => "1", "env_path" => "/tmp/envK1", "worker" => "worker-k",
                                   "background" => true))
        gone = card("toolu_gone", ("code" => "2", "env_path" => "/tmp/envK2", "worker" => "worker-k",
                                   "background" => true))
        t_kept = time()
        BT.run_update!(state, "proj", "worker-k", running("r30", "/tmp/envK1"; background = true,
                                                          tool_use_id = "toolu_kept", started = t_kept))
        BT.run_update!(state, "proj", "worker-k", running("r31", "/tmp/envK2"; background = true,
                                                          tool_use_id = "toolu_gone"))
        BT.runs_channel_closed!(state, "proj", "worker-k"; grace = 1.0)
        sleep(0.2)
        # The process reconnects and announces what it still runs: r30 only.
        BT.run_update!(state, "proj", "worker-k", running("r30", "/tmp/envK1"; background = true,
                                                          tool_use_id = "toolu_kept", started = t_kept))
        @test timedwait(() -> !BT.run_live(gone), 10.0) === :ok
        @test gone.run.status == "lost"
        @test BT.run_live(kept)
    end

    @testset "a stop its process cannot do ends the row" begin
        # The process says it has no such run (it ended unheard, or that process
        # is a new one). The row used to say "had already finished" and stay.
        host_process!("worker-n", ("interrupted" => 0,))
        n = card("toolu_N", ("code" => "sleep(99)", "env_path" => "/tmp/envN", "worker" => "worker-n",
                             "background" => true))
        BT.run_update!(state, "proj", "worker-n", running("r40", "/tmp/envN"; background = true,
                                                          tool_use_id = "toolu_N"))
        @test BT.run_live(n) && BT.in_taskbar(n)
        @test BT.stop_run!(model, n)
        @test timedwait(() -> !BT.run_live(n), 10.0) === :ok
        @test n.run.status == "lost"
        # A process that tried and failed says so, at once instead of after the
        # 15s timeout that reported the worker as unreachable.
        host_process!("worker-f", ("interrupted" => 0, "error" => "MethodError: the session is gone"))
        r = BT.ChatRun("r41", "", "worker-f", "", "", true, time(), "running", 0.0, "",
                       false, false, Any[], nothing)
        t0 = time()
        err = try
            BT.interrupt_run!(state, "proj", r)
            nothing
        catch e
            e
        end
        @test err isa ErrorException && occursin("the session is gone", err.msg)
        @test time() - t0 < 5
    end

    @testset "the bar's stop runs once, however many tabs show the chat" begin
        # Every tab added its own listener to the one shared observable, so a
        # click stopped the task once per open tab (four interrupts per click).
        p = host_process!("worker-t", ("interrupted" => 1,))
        t = card("toolu_T", ("code" => "sleep(99)", "env_path" => "/tmp/envTabs", "worker" => "worker-t",
                             "background" => true))
        BT.run_update!(state, "proj", "worker-t", running("r50", "/tmp/envTabs"; background = true,
                                                          tool_use_id = "toolu_T"))
        for _ in 1:2
            s = Bonito.Session()
            Bonito.jsrender(s, copy(model, s))
        end
        BT.shared(model).taskbar.stop_request[] = "toolu_T"
        @test timedwait(() -> p.asked[] >= 1, 10.0) === :ok
        sleep(0.5)
        @test p.asked[] == 1
    end

    @testset "short env labels" begin
        @test BT.short_env("/home/me/code/BonitoAgents/test") == "BonitoAgents/test"
        @test BT.short_env("/home/me/code/BonitoAgents/test/") == "BonitoAgents/test"
        @test BT.short_env("") == "temp env"
    end
finally
    close(BT.shared(model).taskbar)
end

end
