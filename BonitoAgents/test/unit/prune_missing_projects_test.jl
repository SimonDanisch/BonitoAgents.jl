# When a worker connects, the server drops its projects whose folder is gone (a
# scratch dir cleared on reboot) and keeps everything else: a folder that is
# there, a chat that is in use, and anything it cannot be sure about. Against a
# real worker over a real websocket, so the check is the one a worker answers.
#
# The check is a `stat`. It used to inspect each folder (walking the whole tree
# for counts, sizes and git state), which on a large checkout timed out on every
# start of the desktop app and starved the worker's link meanwhile.
@testitem "unit:prune_missing_projects" tags = [:unit] begin
    import BonitoAgents, BonitoWorker
    const BA = BonitoAgents
    const BW = BonitoWorker
    using Dates, Test

    dir = mktempdir()
    state = BA.serve(; host = "127.0.0.1", port = 0, scan_on_connect = false,
                     state_dir = mkpath(joinpath(dir, "state")),
                     working_dir = mkpath(joinpath(dir, "working")))
    wid = "prune-test"
    project(id, path) = BA.add_project!(state, BA.ProjectInfo(id, id, wid, joinpath(dir, "working", id),
                                                              path, now(UTC)))
    kept    = project("kept", mkpath(joinpath(dir, "kept")))
    gone    = project("gone", joinpath(dir, "gone"))            # never created
    file    = project("file", (touch(joinpath(dir, "a-file")); joinpath(dir, "a-file")))
    in_use  = project("in_use", joinpath(dir, "also-gone"))
    in_use.locked_by = wid                                    # a live session holds it

    worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
        worker_id = wid, name = wid,
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
        projects_root = mkpath(joinpath(dir, "projects"))))
    task = Threads.@spawn BW.serve(worker; retry_delay = 0.2)
    try
        @test timedwait(() -> BA.worker_connected(state, wid), 30.0) === :ok
        # Coming online runs the prune.
        @test timedwait(() -> !haskey(state.projects[], "gone"), 30.0) === :ok
        @test !haskey(state.projects[], "file")                 # a file is not a project folder
        @test haskey(state.projects[], "kept")
        @test haskey(state.projects[], "in_use")                # never one in use

        # Asked again, nothing more to drop; a folder deleted since goes.
        @test BA.prune_missing_projects!(state, wid) == 0
        rm(kept.worker_path; recursive = true)
        @test BA.prune_missing_projects!(state, wid) == 1
        @test !haskey(state.projects[], "kept")

        # A worker that cannot answer proves nothing.
        @test BA.worker_path_missing(state, "not-connected", joinpath(dir, "gone")) == false
    finally
        close(worker)
        wait(task)
        BA.close_worker_links!(state)
        close(state.srv)
    end
end
