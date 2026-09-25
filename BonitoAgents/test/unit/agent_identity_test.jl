# A WorkerAgent speaks for ONE chat. Two chats can share a worker and a folder,
# so the agent must carry its chat's project id rather than look it up by
# (worker, folder): that lookup returned the first match, and with a dismissed
# older thread on the same folder the newer chat's tools were attributed to it,
# so its "Remote julia" switch read on while the agent was refused (2026-09-15).
@testitem "unit:agent_identity" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    path = "/sim/VulkanDev"
    for pid in ("old-thread", "new-thread")
        state.projects[][pid] = BT.ProjectInfo(pid, "VulkanDev", "w1", joinpath(state.working_dir, pid),
                                               path, BT.now(BT.UTC))
    end
    a = BT.WorkerAgent(state, "w1", path; project_id = "new-thread")
    @test a.project_id == "new-thread"

    # An agent built without its chat cannot start; guessing from the folder is
    # exactly the bug. The check comes first, before the worker is even asked.
    nameless = BT.WorkerAgent(state, "w1", path)
    err = try BT.start!(nameless); nothing catch e; e end
    @test err isa ErrorException
    @test occursin("without its chat's project id", sprint(showerror, err))
end
