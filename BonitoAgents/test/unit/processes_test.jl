@testitem "unit:processes" tags = [:unit] begin

# The server's record of every process a chat runs (processes.jl), fed the
# `process_update` frames BonitoMCP sends, and what a restart of the chat does
# with it. The kill itself is the worker's (BonitoWorker test_agent_reaping.jl);
# e2e:restart_cleanup drives the whole road with real processes.

using Test, Dates
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

state = BT.serve(; host = "127.0.0.1", port = 0,
                 state_dir = mktempdir(), working_dir = mktempdir())
p = BT.ProjectInfo("proc-chat", "procs", "worker-a", mktempdir(), mktempdir(), now(UTC))
state.projects[][p.id] = p
frame(pid; kw...) = Dict{String,Any}("type" => "process_update", "pid" => pid,
                                     "recorded_at" => time(), (String(k) => v for (k, v) in kw)...)
recorded() = Set((q.worker_id, q.pid, q.kind) for q in BT.chat_processes(state, p.id))
mkworker(id; online, capabilities) = begin
    w = BT.WorkerInfo(id, id, nothing, id, "/home/u", "julia", String[], "/p", :online, now(UTC))
    w.online[] = online
    w.capabilities = capabilities
    state.workers[][id] = w
end

model = BT.ChatModel(state, mktempdir(); project_id = p.id, agent = BT.WorkerAgent(state, "worker-a", "/p"))
lock(state.lock) do; state.chat_models[p.id] = model; end

try
    @testset "a chat's processes, by worker, recorded from their own word" begin
        # The chat's MCP runs on the chat's worker; an eval host names its own.
        BT.record_process!(state, p.id, "", frame(101; kind = "mcp"))
        BT.record_process!(state, p.id, "", frame(102; kind = "julia session", pgid = 102, label = "/env"))
        BT.record_process!(state, p.id, "worker-b", frame(201; kind = "eval host"))
        @test recorded() == Set([("worker-a", 101, "mcp"), ("worker-a", 102, "julia session"),
                                 ("worker-b", 201, "eval host")])
        BT.record_process!(state, p.id, "", frame(101; kind = "", alive = false))
        @test recorded() == Set([("worker-a", 102, "julia session"), ("worker-b", 201, "eval host")])
        q = only(x for x in BT.chat_processes(state, p.id) if x.pid == 102)
        @test q.pgid == 102 && q.label == "/env"
    end

    @testset "the record outlives the server" begin
        again = BT.ServerState(; state_dir = state.state_dir, working_dir = state.working_dir)
        @test Set((q.worker_id, q.pid) for q in BT.chat_processes(again, p.id)) ==
              Set([("worker-a", 102), ("worker-b", 201)])
    end

    @testset "a worker that cannot kill now keeps its processes on record" begin
        # Offline: for when it is back. Too old to know the request: it would
        # leave it unanswered, so it is not asked (and says so in the log).
        mkworker("worker-a"; online = false, capabilities = ["kill_processes"])
        mkworker("worker-b"; online = true, capabilities = String[])
        @test isempty(BT.kill_recorded!(state, p.id, BT.chat_processes(state, p.id)))
        @test length(BT.chat_processes(state, p.id)) == 2
    end

    @testset "a restart ends the old session's runs and empties the bar" begin
        m = BT.JuliaEvalToolMsg(BT.Message("toolu_R", "other", "bt_julia_eval", "bt_julia_eval",
                                           "pending", "", time(), nothing, model), "btworker")
        BT.apply_input!(m, Dict{String,Any}("code" => "while true; end", "env_path" => "/tmp/envR",
                                           "background" => true))
        lock(model.lock) do; push!(model.msgs_store, m); end
        BT.run_update!(state, p.id, "", Dict{String,Any}("type" => "run_update", "run" => "r1",
            "status" => "running", "route" => abspath("/tmp/envR"), "env_path" => "/tmp/envR",
            "background" => true, "started" => time(), "tool_use_id" => "toolu_R"))
        @test BT.run_live(m) && BT.in_taskbar(m)
        BT.end_chat_session!(model, "the chat was restarted")
        @test m.run.status == "lost" && m.run.summary == "the chat was restarted"
        @test m.run.notified            # the new session's agent is not told about it
        @test !BT.in_taskbar(m)
        @test isempty(BT.chat_taskbar(model).items[])
        @test occursin("the chat was restarted", BT.eval_env_summary(m))
    end
finally
    close(BT.shared(model).taskbar)
end

end
