# When a worker connects, the server forgets its projects whose folder in the
# worker's SCRATCH space is gone (a `/tmp/jl_*` dir cleared on reboot), and keeps
# everything else: a folder that is there, a chat that is in use, anything it
# cannot be sure about, and every folder outside the scratch space even when it is
# missing. That last rule is the one that was missing: on 11-18 a worker came
# back while its disk was being moved, and the server deleted 26 chats, an app's
# chat and its data among them. Against a real worker over a
# real websocket, so the check is the one a worker answers.
#
# The check is a `stat`. It used to inspect each folder (walking the whole tree
# for counts, sizes and git state), which on a large checkout timed out on every
# start of the desktop app and starved the worker's link meanwhile.
@testitem "unit:prune_missing_projects" tags = [:unit] begin
    import BonitoAgents, BonitoWorker
    const BA = BonitoAgents
    const BW = BonitoWorker
    using Dates, Random, Test

    dir = mktempdir()                       # inside the worker's scratch space
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
    # Missing, but not scratch: a project folder on a disk that is being moved.
    away    = project("away", joinpath(homedir(), ".bt-prune-test-" * randstring(12), "project"))
    @test !ispath(away.worker_path)

    worker = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:$(state.srv.port)",
        worker_id = wid, name = wid,
        mcp_command = first(Base.julia_cmd().exec), mcp_arguments = String[],
        projects_root = mkpath(joinpath(dir, "projects"))))
    scratch = Vector{String}(BW.hello(worker)["scratch_dirs"])
    @test any(d -> BA.inside_dir(dir, d), scratch)            # the worker names its temp dir
    @test !any(d -> BA.inside_dir(away.worker_path, d), scratch)
    task = Threads.@spawn BW.serve(worker; retry_delay = 0.2)
    try
        @test timedwait(() -> BA.worker_connected(state, wid), 30.0) === :ok
        # Coming online runs the prune.
        @test timedwait(() -> !haskey(state.projects[], "gone"), 30.0) === :ok
        @test !haskey(state.projects[], "file")                 # a file is not a project folder
        @test haskey(state.projects[], "kept")
        @test haskey(state.projects[], "in_use")                # never one in use
        @test haskey(state.projects[], "away")                  # never one outside scratch

        # Asked again, nothing more to drop; a scratch folder deleted since goes.
        @test BA.prune_missing_projects!(state, wid, scratch) == 0
        rm(kept.worker_path; recursive = true)
        # A worker too old to name its scratch space prunes nothing.
        @test BA.prune_missing_projects!(state, wid, String[]) == 0
        @test haskey(state.projects[], "kept")
        @test BA.prune_missing_projects!(state, wid, scratch) == 1
        @test !haskey(state.projects[], "kept")
        @test haskey(state.projects[], "away")

        # A worker that cannot answer proves nothing.
        @test BA.worker_path_missing(state, "not-connected", joinpath(dir, "gone")) == false
    finally
        close(worker)
        wait(task)
        BA.close_worker_links!(state)
        close(state.srv)
    end
end

# Paths compare in the worker's own spelling: a Windows worker's scratch dir is
# `C:\…`, and a sibling folder that merely starts with the same letters is not
# inside it.
@testitem "unit:inside_dir" tags = [:unit] begin
    import BonitoAgents as BA
    @test BA.inside_dir("/tmp/jl_abc", "/tmp")
    @test BA.inside_dir("/tmp", "/tmp")
    @test !BA.inside_dir("/tmpfoo/x", "/tmp")
    @test !BA.inside_dir("/home/u/projects/app", "/tmp")
    @test BA.inside_dir("/private/var/folders/x/T/jl_1", "/private/var/folders/x/T")
    @test BA.inside_dir(raw"C:\Users\u\AppData\Local\Temp\jl_1", raw"C:\Users\u\AppData\Local\Temp")
    @test !BA.inside_dir(raw"C:\Users\u\AppData\Local\Temporary\x", raw"C:\Users\u\AppData\Local\Temp")
end
