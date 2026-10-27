@testitem "unit:sync_progress" tags = [:unit] begin
    using BonitoAgents
    const B = BonitoAgents
    state = B.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    book = B.job_book(state, "sync-test")
    for status in (:completed, :failed, :cancelled)
        report = B.sync_job_progress(state, "sync-test", "worker-a", "Pull from Desktop")
        report(:phase, (msg = "Preparing transfer",))
        job = only(j for j in values(book.changed[]) if j["status"] == "running")
        id = job["id"]
        @test job["total"] === nothing
        report(:manifest_received, (count = 4,))
        report(:plan_received, (planned = 6, work = 2))
        report(:file_start, (rel = "results/frame.png", idx = 1, total = 2))
        report(:file_chunk, (bytes = 4096,))
        sleep(0.21)
        report(:file_done, (rel = "results/frame.png", idx = 1, total = 2))
        job = book.changed[][id]
        @test job["completed"] == 3 # two unchanged files, one transferred
        @test job["total"] == 4
        @test occursin("4.000 KiB", job["detail"])
        @test occursin("results/frame.png", job["detail"])
        report(:transfer_done, (files = 4,))
        @test book.changed[][id]["status"] == "running" # destination not yet confirmed
        report(status, (msg = "destination outcome",))
        @test book.changed[][id]["status"] == String(status)
        @test book.changed[][id]["detail"] == "destination outcome"
    end
    restored = B.ServerState(; state_dir = state.state_dir, working_dir = state.working_dir)
    @test length(B.job_book(restored, "sync-test").changed[]) == 3
    @test isempty(state.chat_models)
    @test state.turn_signal[] == 0
end
