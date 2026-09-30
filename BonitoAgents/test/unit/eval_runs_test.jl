@testitem "unit:eval_runs" tags = [:unit] begin

# The chat's side of Julia runs (eval_runs.jl), fed the `run_update` frames an
# MCP process sends: which card a run belongs to, that the card follows the RUN
# (live, in the bar, its result) rather than the call that returned at once, and
# when it may leave the bar. The e2e item (e2e:eval_runs) drives the same frames
# from real processes; here each rule is pinned on its own.

using Test
using BonitoAgents
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

    @testset "short env labels" begin
        @test BT.short_env("/home/me/code/BonitoAgents/test") == "BonitoAgents/test"
        @test BT.short_env("/home/me/code/BonitoAgents/test/") == "BonitoAgents/test"
        @test BT.short_env("") == "temp env"
    end
finally
    close(BT.shared(model).taskbar)
end

end
