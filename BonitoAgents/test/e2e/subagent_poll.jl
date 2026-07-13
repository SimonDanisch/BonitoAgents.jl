# End-to-end: a background subagent's taskbar pill is finalized DETERMINISTICALLY
# off its transcript `outputFile`'s CONTENT — the subagent's final response ends
# its turn with `"stop_reason":"end_turn"`, which lands EXACTLY when it finishes
# (verified live against a real claude-agent-acp subagent). The wire `completed`
# is the launch-ack lie; the fd-close is worthless (the transcript is written
# append-per-line, so the fd reads "closed" between every write while the subagent
# is still alive). Only the `end_turn` marker in the content is the real signal.
# Proves the poller + real worker clear the slot at end_turn, and NOT before.
#
# Regression (the launch race): the `outputFile` PATH lands on the wire before the
# file is on disk. A MISSING file, and a still-streaming file with no `end_turn`,
# must NOT read as done — else the pill vanishes while the subagent runs on.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

function run_suite(server)
    BA = TestKit.BT
    @testset "BonitoAgents subagent poll completion" begin
        pid   = TK.new_chat(server; title = "SubPoll")
        model = server.h.state.chat_models[pid]
        @test BA.bg_worker_id(server.h.state, model) !== nothing   # a real worker

        # The subagent's transcript path — NOT created yet (the launch race: the
        # path is known before the file lands on disk).
        outpath = tempname() * ".output"
        @test !isfile(outpath)

        # A background subagent pill whose poll target is that (missing) file.
        task = BA.TaskToolMsg("sub-poll-1", "other", "Investigate", "in_progress",
                              "", time(), nothing, "dig around", true, nothing, model)
        task.bg_output_path = outpath
        BA.push!(BA.chat_taskbar(model), task)
        lock(BA.shared(model).lock) do; push!(BA.shared(model).msgs_store, task); end

        # (A) MISSING file must NOT read as done — absence is not completion. The
        # bar's loop must keep it live + pinned through several ticks (the race).
        sleep(2.5)
        @test BA.in_taskbar(task) == true
        @test BA.is_pinned(model, "sub-poll-1")

        # (B) The transcript materializes and the subagent is WORKING: entries with
        # tool calls (`stop_reason":"tool_use"`), NO `end_turn` yet → stays pinned.
        open(outpath, "w") do io
            println(io, """{"type":"user","message":{"role":"user","content":"dig around"}}""")
            println(io, """{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}""")
        end
        sleep(2.5)
        @test BA.in_taskbar(task) == true
        @test BA.is_pinned(model, "sub-poll-1")

        # (C) The subagent produces its FINAL response — a text message that ends
        # its turn with `stop_reason":"end_turn"`. The bar's loop must finalize the
        # pill (dropped from the bar) within a few 1 Hz ticks — no ⊗ needed.
        open(outpath, "a") do io
            println(io, """{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done: found the marker."}]}}""")
        end
        done = false
        t0 = time()
        while time() - t0 < 12
            (!BA.in_taskbar(task) && !BA.is_pinned(model, "sub-poll-1")) && (done = true; break)
            sleep(0.5)
        end
        @test done
        @test !BA.in_taskbar(task)
        @test task.finished_at !== nothing
        @test !BA.is_pinned(model, "sub-poll-1")
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = (_p -> [TK.text("ready"), TK.end_turn()]))
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
