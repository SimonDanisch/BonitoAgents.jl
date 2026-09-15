# A project move with its worker offline can only push the server's mirror. A
# project registered without a sync has an EMPTY mirror, and pushing that once
# deleted every file of the live project at the target (2026-09-15, the
# Windows side of a dual-boot laptop sharing the Linux side's folder). The move
# now refuses unless the mirror was actually synced, before any transfer is
# opened.
@testitem "unit:project_move_guard" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    mk(id, name, root, online) = BT.WorkerInfo(id, name, "ws://x", "x", nothing, name, "/home/u",
                                              "julia", String[], root, online, BT.now(BT.UTC))
    state.workers[]["linux"]   = mk("linux",   "Laptop", "/sim/Programmieren", :offline)
    state.workers[]["windows"] = mk("windows", "LapWin", "C:/Users/sdani/Programmieren", :online)
    mirror = joinpath(state.working_dir, "linux-VulkanDev")
    mkpath(mirror)                                  # exists, and is empty: registered, never synced
    p = BT.ProjectInfo("p1", "VulkanDev", "linux", mirror, "/sim/Programmieren/VulkanDev", BT.now(BT.UTC))
    state.projects[]["p1"] = p
    @test p.last_sync_at === nothing

    err = try BT.transfer_project!(state, p, "windows"); nothing catch e; e end
    @test err isa ErrorException
    @test occursin("never synced", sprint(showerror, err))
    # Nothing moved: the record still names the source, and no transfer was
    # opened towards the target (no RPC was even registered).
    @test p.worker_id == "linux"
    @test p.worker_path == "/sim/Programmieren/VulkanDev"
    @test isempty(state.pending_rpcs)

    # A mirror that WAS synced may still be pushed while the worker is offline;
    # the push then fails only because no worker is connected here to receive it.
    p.last_sync_at = BT.now(BT.UTC); p.backup_status = :synced
    err2 = try BT.transfer_project!(state, p, "windows"); nothing catch e; e end
    @test err2 isa Exception
    @test !occursin("never synced", sprint(showerror, err2))
end
