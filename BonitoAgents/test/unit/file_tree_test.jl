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
        # An image, so the open-guard case below stats a file that EXISTS — the
        # old assertion ("not a text file") never needed one, because the kind
        # check short-circuited before any stat.
        write(joinpath(root, "logo.png"), UInt8[0x89, 0x50, 0x4E, 0x47, fill(0x00, 32)...])

        @testset "list_dir returns per-entry sizes + dir flags" begin
            ld = BT.list_worker_dir(h.state, wid, root)
            byname = Dict(e.name => e for e in ld.entries)
            @test haskey(byname, "src") && byname["src"].dir && byname["src"].size == 0
            @test haskey(byname, "big.txt") && !byname["big.txt"].dir &&
                  byname["big.txt"].size == 3_000_000
            @test !haskey(byname, ".git")   # dotfiles skipped by list_dir
        end

        # Backs the picker's "New folder" — a project can be started somewhere
        # that doesn't exist yet.
        @testset "make_dir creates on the worker, and refuses to escape" begin
            created = BT.make_worker_dir(h.state, wid, root, "fresh-proj")
            @test isdir(created)
            @test basename(created) == "fresh-proj"
            # Visible to the picker immediately.
            @test "fresh-proj" in [e.name for e in BT.list_worker_dir(h.state, wid, root).entries]
            # Not a way to write anywhere else on the worker.
            @test_throws Exception BT.make_worker_dir(h.state, wid, root, "../escape")
            @test_throws Exception BT.make_worker_dir(h.state, wid, root, "a/b")
            @test_throws Exception BT.make_worker_dir(h.state, wid, root, "")
            @test_throws Exception BT.make_worker_dir(h.state, wid, root, "fresh-proj")  # exists
            @test !ispath(joinpath(dirname(root), "escape"))
        end

        # Backs the picker's "type /newname to create it" — a FULL path that is
        # mkpath'd (parents included) rather than a single child of `root`.
        @testset "ensure_dir creates the full path, refuses files" begin
            # Multi-segment, nothing exists yet: parents are created too.
            missing_child = joinpath(root, "a", "b", "newproj")
            @test !ispath(missing_child)
            made = BT.ensure_worker_dir(h.state, wid, missing_child)
            @test isdir(missing_child)
            # Returns the worker's normalized absolute path.
            @test made == abspath(missing_child)
            # Existing folder is idempotent (no error).
            @test BT.ensure_worker_dir(h.state, wid, missing_child) == abspath(missing_child)
            # A path that exists as a plain FILE is refused — mkpath would
            # silently create a sibling and the project would start nowhere real.
            file_path = joinpath(root, "a", "not-a-dir.txt")
            write(file_path, "nope")
            @test_throws Exception BT.ensure_worker_dir(h.state, wid, file_path)
            # …and it is left untouched.
            @test isfile(file_path)
        end

        @testset "stat_path: file vs dir vs missing" begin
            src = joinpath(root, "src", "main.jl")
            f = BT.stat_worker_path(h.state, wid, src)
            @test f.exists && f.isfile && !f.isdir && f.size == 11
            d = BT.stat_worker_path(h.state, wid, joinpath(root, "src"))
            @test d.exists && d.isdir && !d.isfile
            m = BT.stat_worker_path(h.state, wid, joinpath(root, "nope.jl"))
            @test !m.exists && !m.isfile

            # `mtime` is the other half of the mirror freshness key (#34): a file
            # REWRITTEN at the same path must report a different stamp, or the
            # server keeps serving its first-ever copy forever.
            @test f.mtime > 0
            sleep(0.05)
            write(src, "changed!!!!")          # same length, different content
            f2 = BT.stat_worker_path(h.state, wid, src)
            @test f2.mtime != f.mtime
            write(src, "println(1)\n")         # restore for the tests below
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
            # An image is NOT a refusal any more: the file viewer opens every
            # kind, so the guard only stops files that can't be opened at all.
            @test BT.open_guard_reject_reason(h.state, pid, "logo.png") === nothing
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
