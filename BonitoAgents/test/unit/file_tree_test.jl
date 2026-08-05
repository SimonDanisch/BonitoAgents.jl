@testitem "unit:file_tree" tags = [:unit] begin

# File-tree backend: worker RPCs, the editor open-guard, the project file index,
# and the search scorer. Browser-free — the scorer is a pure function and the
# rest runs against a REAL worker subprocess (dev_server), the same harness as
# `test_dev_server_worker.jl`. The UI flow itself lives in `e2e/file_tree.jl`;
# this guards the pieces that the heavy e2e otherwise covers only indirectly.

using Test
import BonitoAgents, BonitoWorker
const BT = BonitoAgents

@testset "file tree search scorer (score_match)" begin
    sm = BT.score_match
    # Exact basename wins outright, case-insensitively — the bug that buried
    # `dev/Makie/Makie/src/Makie.jl` under scattered subsequence hits.
    @test sm("Makie.jl", "dev/Makie/Makie/src/Makie.jl") == 1000
    @test sm("makie.jl", "dev/Makie/Makie/src/Makie.jl") == 1000
    # The tiers, strictly descending.
    @test sm("Makie",    "MakieCore.jl")   == 900    # basename prefix
    @test sm("Core",     "MakieCore.jl")   == 750    # basename substring
    @test sm("src/main", "a/src/main.jl")  == 500    # path substring (not basename)
    @test sm("mn",       "main.jl")        == 300    # basename subsequence
    @test sm("amn",      "a/x/main.jl")    == 120    # path subsequence only
    @test sm("zzz",      "main.jl")        == -1     # no match at all
    # Ranking sanity: the file actually NAMED Makie.jl sorts first.
    cands = ["x/wglmakie.jl", "deep/dir/Makie.jl", "m/a/k/i/e.jl"]
    @test sort(cands; by = c -> (-sm("Makie.jl", c), length(c)))[1] == "deep/dir/Makie.jl"
end

@testset "file tree worker RPCs + open-guard + index" begin
    h = BT.dev_server(; port = 0)
    try
        # Wait for the worker subprocess to register on the control WS.
        registered = false
        for _ in 1:60
            isempty(h.state.workers[]) || (registered = true; break)
            sleep(0.5)
        end
        @test registered
        wid = first(keys(h.state.workers[]))

        # A tree on disk (worker == same machine, so it can stat/walk these paths).
        root = mktempdir()
        mkpath(joinpath(root, "src"));  mkpath(joinpath(root, ".git"))
        write(joinpath(root, "src", "main.jl"), "println(1)\n")     # 11 bytes
        write(joinpath(root, "big.txt"),  repeat("a", 3_000_000))   # > 2 MB editor cap
        write(joinpath(root, ".git", "config"), "[core]\n")         # must be index-excluded

        @testset "list_dir returns per-entry sizes + dir flags" begin
            ld = BT.list_worker_dir(h.state, wid, root)
            byname = Dict(e.name => e for e in ld.entries)
            @test haskey(byname, "src") && byname["src"].dir && byname["src"].size == 0
            @test haskey(byname, "big.txt") && !byname["big.txt"].dir &&
                  byname["big.txt"].size == 3_000_000
            @test !haskey(byname, ".git")   # dotfiles skipped by list_dir
        end

        @testset "stat_path: file vs dir vs missing" begin
            f = BT.stat_worker_path(h.state, wid, joinpath(root, "src", "main.jl"))
            @test f.exists && f.isfile && !f.isdir && f.size == 11
            d = BT.stat_worker_path(h.state, wid, joinpath(root, "src"))
            @test d.exists && d.isdir && !d.isfile
            m = BT.stat_worker_path(h.state, wid, joinpath(root, "nope.jl"))
            @test !m.exists && !m.isfile
        end

        @testset "list_project_files excludes .git, returns rel paths" begin
            fi = BT.list_worker_project_files(h.state, wid, root)
            @test "src/main.jl" in fi.files
            @test "big.txt" in fi.files
            @test !any(f -> startswith(f, ".git"), fi.files)
            @test !fi.truncated
        end

        # Register a ProjectInfo so the guard can resolve worker_id + worker_path.
        pid = "ft-test"
        h.state.projects[][pid] =
            BT.ProjectInfo(pid, "FT", wid, root, root, BT.now(BT.UTC))

        @testset "open-guard: every refusal branch + the openable case" begin
            ok   = BT.open_guard_reject_reason(h.state, pid, "src/main.jl")
            @test ok === nothing                                   # a real text file opens
            @test occursin("folder",       BT.open_guard_reject_reason(h.state, pid, "src"))
            @test occursin("not found",    BT.open_guard_reject_reason(h.state, pid, "nope.jl"))
            @test occursin("too large",    BT.open_guard_reject_reason(h.state, pid, "big.txt"))
            # Binary/media extension is rejected on the name alone (no stat needed).
            @test occursin("not a text file", BT.open_guard_reject_reason(h.state, pid, "logo.png"))
        end

        @testset "project file index: cache + single-flight" begin
            proj = h.state.projects[][pid]
            t = BT.ensure_project_file_index!(h.state, proj)
            t === nothing || wait(t)
            files = BT.project_index_files(proj)
            @test "src/main.jl" in files
            @test !any(f -> startswith(f, ".git"), files)
            # A second call within the TTL needs no walk → no in-flight task.
            @test BT.ensure_project_file_index!(h.state, proj) === nothing
        end
    finally
        close(h)
    end
end

end
