# `find_repos` — the list the review tab's folder picker is built from.
#
# A project folder is routinely a workspace holding one checkout per dependency
# being developed rather than being a checkout itself, so "which repository?" is
# a real question and the tab needs the candidates to ask it with.
#
# This runs while a user waits for a tab to open, so the pruning is not an
# optimisation — it is the difference between a picker and a stall. All of it is
# asserted here: stopping at a hit (walking INTO a checkout is where the time
# goes), the depth limit, the directory budget, and not following symlinks.

@testset "find_repos" begin
    # A repository, as git decides one: a `.git` entry. Directory in a normal
    # checkout, FILE in a worktree or submodule.
    mkrepo(dir)     = (mkpath(joinpath(dir, ".git")); dir)
    mkworktree(dir) = (mkpath(dir); write(joinpath(dir, ".git"), "gitdir: /elsewhere\n"); dir)

    @testset "finds checkouts, at the root and below" begin
        mktempdir() do root
            mkrepo(joinpath(root, "dev", "Alpha"))
            mkrepo(joinpath(root, "dev", "Beta"))
            mkrepo(joinpath(root, "tool"))
            found = BW.find_repos(root)
            @test Set(found.repos) == Set([joinpath(root, "dev", "Alpha"),
                                           joinpath(root, "dev", "Beta"),
                                           joinpath(root, "tool")])
            @test found.truncated == false
            @test found.unreadable == 0
        end
    end

    @testset "the root itself counts" begin
        mktempdir() do root
            mkrepo(root)
            mkpath(joinpath(root, "src"))
            # And nothing below it: the scan stops at the hit, so a checkout's
            # own contents are never walked. This is the pruning that matters —
            # a checkout is where the files actually are.
            @test BW.find_repos(root).repos == [root]
        end
    end

    @testset "a checkout inside a checkout is not reported" begin
        mktempdir() do root
            mkrepo(root)
            mkrepo(joinpath(root, "vendor", "dep"))
            # Stopping at the outer hit is the whole point; `dep` is part of that
            # checkout's working tree as far as this scan is concerned.
            @test BW.find_repos(root).repos == [root]
        end
    end

    @testset "worktrees and submodules count (`.git` is a file there)" begin
        mktempdir() do root
            mkworktree(joinpath(root, "wt"))
            @test BW.find_repos(root).repos == [joinpath(root, "wt")]
        end
    end

    @testset "breadth-first: shallow checkouts come first" begin
        mktempdir() do root
            deep    = mkrepo(joinpath(root, "a", "b", "c", "Deep"))
            shallow = mkrepo(joinpath(root, "Shallow"))
            repos = BW.find_repos(root).repos
            @test repos == [shallow, deep]
            # Which is what makes a truncated scan the USEFUL half rather than an
            # arbitrary one: workspaces are organised near the top.
        end
    end

    @testset "depth limit" begin
        mktempdir() do root
            mkrepo(joinpath(root, "a", "b", "c", "d", "Buried"))
            @test isempty(BW.find_repos(root; max_depth = 2).repos)
            @test length(BW.find_repos(root; max_depth = 5).repos) == 1
        end
    end

    @testset "directory budget, and it SAYS it ran out" begin
        mktempdir() do root
            for i in 1:40
                mkpath(joinpath(root, "d$(i)"))
            end
            mkrepo(joinpath(root, "d40", "Repo"))
            full = BW.find_repos(root)
            @test full.truncated == false
            @test length(full.repos) == 1

            # A budget too small to finish must report itself. A partial list
            # presented as the whole answer is the failure mode: the picker would
            # simply not offer a repository that is right there.
            cut = BW.find_repos(root; max_dirs = 5)
            @test cut.truncated == true
        end
    end

    @testset "hidden directories are skipped" begin
        mktempdir() do root
            mkrepo(joinpath(root, ".cache", "Hidden"))
            mkrepo(joinpath(root, "Visible"))
            @test BW.find_repos(root).repos == [joinpath(root, "Visible")]
        end
    end

    @testset "symlinks are not followed" begin
        # A link pointing at an ancestor turns the walk into an infinite one.
        # `isdir` follows links, so the guard has to be an explicit `islink`
        # check — and a test that would HANG rather than fail if it regressed is
        # worth having a timeout around.
        mktempdir() do root
            mkrepo(joinpath(root, "Real"))
            symlink(root, joinpath(root, "loop"))
            done = Threads.Atomic{Bool}(false)
            result = Ref{Any}(nothing)
            t = Threads.@spawn begin
                result[] = BW.find_repos(root)
                done[] = true
            end
            @test timedwait(() -> done[], 10.0) === :ok
            wait(t)
            @test result[].repos == [joinpath(root, "Real")]
        end
    end

    @testset "an unreadable directory is counted, not fatal" begin
        mktempdir() do root
            mkrepo(joinpath(root, "Readable"))
            locked = joinpath(root, "locked")
            mkpath(locked)
            chmod(locked, 0o000)
            try
                # Assert the PRECONDITION rather than guessing at it from the
                # uid: root reads everything and Windows ignores the mode, and in
                # both cases there is no unreadable directory to count. Testing
                # what we actually did to the filesystem beats testing who we are.
                really_locked = try
                    readdir(locked)
                    false
                catch e
                    e isa Base.IOError || rethrow()
                    true
                end
                found = BW.find_repos(root)
                # The rest of the scan still lands either way…
                @test found.repos == [joinpath(root, "Readable")]
                # …and where the directory really was unreadable, that fact is
                # reported rather than swallowed.
                @test found.unreadable == (really_locked ? 1 : 0)
            finally
                chmod(locked, 0o700)      # or the tempdir can't be removed
            end
        end
    end

    @testset "the response shape the server parses" begin
        mktempdir() do root
            mkrepo(joinpath(root, "R"))
            ok = BW.find_repos_response("rid", root, 4)
            @test ok["type"] == "find_repos_response"
            @test ok["request_id"] == "rid"
            @test ok["repos"] == [joinpath(root, "R")]
            @test ok["truncated"] === false
            @test ok["unreadable"] == 0
            @test !haskey(ok, "error")

            # Errors come back as an `error` field on the same message type —
            # the server raises it as the panel's message, so it has to be a
            # sentence about the path, not a stack trace.
            bad = BW.find_repos_response("rid", joinpath(root, "nope"), 4)
            @test haskey(bad, "error")
            @test occursin("not a directory", bad["error"])
            @test !haskey(bad, "repos")

            @test occursin("missing path", BW.find_repos_response("rid", "", 4)["error"])
        end
    end
end
