@testitem "unit:subagent_completion" tags = [:unit] begin

# Deterministic completion for an ASYNC (`run_in_background`) subagent, headless.
#
# The wire has no "subagent finished" frame — claude-agent-acp marks the parent
# tool_call `completed` at LAUNCH (same millisecond as `async_launched`), and the
# subagent then runs for seconds. The ONLY deterministic completion signal is the
# transcript `outputFile` handed back in the launch's
# `_meta.claudeCode.toolResponse` — the TaskBar's loop tails it for the fd-close
# exactly like a background bash. Membership IS liveness: the subagent is live
# iff it's in the bar (`in_taskbar`), and it leaves ONLY via that fd-close (or a
# ⊗ stop) — never by reading the launch-ack `completed` status, never by counting.
# There is no `task_running` flag.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

function headless_model()
    state = BT.serve(; host = "127.0.0.1", port = 0, worker_secret = "x",
                     state_dir = mktempdir(), working_dir = mktempdir())
    return BT.ChatModel(state, mktempdir(); project_id = "proj",
                        agent = BT.WorkerAgent(state, "w1", "/p"))
end

launch_meta(path) = Dict("_meta" => Dict("claudeCode" => Dict("toolResponse" =>
    Dict("isAsync" => true, "status" => "async_launched", "outputFile" => path))))

@testset "ACP surfaces the async subagent's outputFile" begin
    @test :output_file in fieldnames(ACP.TaskCall)
    @test ACP.async_output_file(launch_meta("/tmp/agent.output")) == "/tmp/agent.output"
    @test ACP.async_output_file(Dict()) === nothing                 # no meta
    @test ACP.async_output_file(Dict("_meta" => Dict())) === nothing # partial
end

@testset "update_from_snap! captures outputFile; launch `completed` is NOT done" begin
    model = headless_model()
    task = BT.TaskToolMsg("t1", "other", "Investigate", "in_progress", "",
                          time(), nothing, "desc", true, nothing, model)
    @test isempty(task.bg_output_path)
    # The async-launch snapshot carries the outputFile (and status `completed` —
    # the launch ack, which must NOT be read as the subagent finishing).
    snap = ACP.TaskCall("t1", "other", "Investigate", "completed", ACP.ToolContent[],
                        Channel{ACP.ToolCall}(4), "desc", "prompt", true, nothing,
                        "/tmp/agent.output")
    BT.update_from_snap!(task, snap)
    @test task.bg_output_path == "/tmp/agent.output"    # captured the poll target
    # `isdone` polls the transcript CONTENT for `"stop_reason":"end_turn"` (the
    # subagent's final response), never the launch-ack status: with no worker to
    # read the file, the poll can't confirm end_turn, so it is NOT done.
    @test BT.isdone(task) == false
end

@testset "isdone ignores the launch-ack `completed`; no outputFile ⇒ stays in the bar" begin
    # A launched async subagent reports tool_call `completed` at LAUNCH (the ack),
    # with no terminal update. `isdone` must NEVER read that status — reading it
    # would finalize the pill a tick after launch. With no outputFile AND no
    # terminal-status TRANSITION (finished_at stays nothing) there is no wire
    # completion signal, so it stays live until the user ⊗-stops it.
    model = headless_model()
    launched = BT.TaskToolMsg("t5", "other", "Investigate", "completed", "",
                              time(), nothing, "desc", true, nothing, model)
    @test isempty(launched.bg_output_path) && launched.finished_at === nothing
    @test BT.isdone(launched) == false                  # launch-ack `completed` ≠ done

    # Drive the bar's OWN poll loop: push it, let the loop tick several times, and
    # assert it stays in the bar (the loop must not finalize a launched subagent).
    push!(BT.chat_taskbar(model), launched)
    @test BT.in_taskbar(launched)
    sleep(2.6)
    @test BT.in_taskbar(launched)

    # The only ways out (no outputFile): a ⊗ stop, here via `finished!`.
    BT.finished!(launched)
    @test !BT.in_taskbar(launched) && launched.finished_at !== nothing
end

@testset "no outputFile: NEVER auto-finalizes — not finished_at, not a quiet feed" begin
    # The deterministic contract: with no transcript file there is NO completion
    # signal to read, so NOTHING the wire says (the launch-ack `completed`, its
    # `finished_at`) and NO amount of silence retires the pill. It stays until the
    # transcript's `end_turn` marker or a ⊗ stop. No timeout, no staleness guess.
    model = headless_model()
    task = BT.TaskToolMsg("t6", "other", "Investigate", "in_progress", "",
                          time(), nothing, "desc", true, nothing, model)
    push!(BT.chat_taskbar(model), task)
    @test BT.in_taskbar(task) && BT.isdone(task) == false
    # The launch-ack stamps finished_at while the subagent runs on — ignored.
    task.finished_at = time()
    @test BT.isdone(task) == false
    # Even a long-silent feed does NOT finalize it (no quiet-timeout guessing).
    task.last_activity_at = time() - 100_000.0
    @test BT.isdone(task) == false
    # The only way out (no outputFile): ⊗ stop, here via `finished!`.
    BT.finished!(task)
    @test !BT.in_taskbar(task)
end

@testset "streamed run_in_background / outputFile on a LATER update pins the subagent" begin
    # THE REAL WIRE (regression): claude-agent-acp streams rawInput, so the
    # initial Task `tool_call` arrives with NO run_in_background and NO outputFile
    # — is_background is false, it is NOT pinned yet. Both ride a later
    # `tool_call_update` (the async_launched ack). `update_from_snap!(::TaskToolMsg)`
    # must flip is_background off EITHER signal and `process_update!` must re-pin.
    # (The old mocks put run_in_background in the INITIAL rawInput, so they never
    # exercised this — the subagent pill never showed on the real wire.)
    model = headless_model()
    initial = ACP.TaskCall("t7", "other", "Investigate", "in_progress", ACP.ToolContent[],
                           Channel{ACP.ToolCall}(4), "", "", false, nothing, "")  # empty rawInput
    b = BT.build_tool_msg(model, initial)
    BT.send!(model, b)
    @test b.is_background == false && BT.in_taskbar(b) == false     # not a bg task yet

    # The launch-ack update: run_in_background=true AND the transcript outputFile.
    upd = ACP.TaskCall("t7", "other", "Investigate", "completed", ACP.ToolContent[],
                       Channel{ACP.ToolCall}(4), "", "", true, nothing, "/tmp/t7.output")
    put!(upd.updates, ACP.TaskCall("t7", "other", "Investigate", "completed", ACP.ToolContent[],
        Channel{ACP.ToolCall}(4), "", "", true, nothing, "/tmp/t7.output"))
    close(upd.updates)
    BT.process_update!(b, upd)
    @test b.is_background == true                                   # flipped off the late signal
    @test b.bg_output_path == "/tmp/t7.output"                     # captured the poll target
    @test BT.in_taskbar(b) == true                                 # NOW pinned
    @test BT.is_pinned(model, "t7")
end

@testset "outputFile ALONE (no run_in_background) still pins the subagent" begin
    # Belt-and-suspenders: even if run_in_background never arrives, an outputFile
    # in the launch ack is itself proof of an async detach → background.
    model = headless_model()
    b = BT.build_tool_msg(model,
        ACP.TaskCall("t8", "other", "Investigate", "in_progress", ACP.ToolContent[],
                     Channel{ACP.ToolCall}(4), "", "", false, nothing, ""))
    BT.send!(model, b)
    upd = ACP.TaskCall("t8", "other", "Investigate", "completed", ACP.ToolContent[],
                       Channel{ACP.ToolCall}(4), "", "", false, nothing, "/tmp/t8.output")
    put!(upd.updates, ACP.TaskCall("t8", "other", "Investigate", "completed", ACP.ToolContent[],
        Channel{ACP.ToolCall}(4), "", "", false, nothing, "/tmp/t8.output"))
    close(upd.updates)
    BT.process_update!(b, upd)
    @test b.is_background == true && BT.in_taskbar(b) == true
end

@testset "finished! is the deterministic end (bar's loop off the file's fd-close)" begin
    model = headless_model()
    task = BT.TaskToolMsg("t2", "other", "Investigate", "in_progress", "",
                          time(), nothing, "desc", true, nothing, model)
    task.bg_output_path = "/tmp/agent2.output"
    push!(BT.chat_taskbar(model), task)                 # enter the bar (membership = liveness)
    push!(BT.shared(model).msgs_store, task)
    @test BT.is_pinned(model, "t2")
    @test BT.in_taskbar(task)
    BT.finished!(task)                                  # what the bar's loop calls when isdone
    @test task.finished_at !== nothing
    @test task.status in ("completed", "failed")        # fd-close ⇒ terminal (not left in_progress)
    @test !BT.is_pinned(model, "t2")
    @test !BT.in_taskbar(task)
end

end
