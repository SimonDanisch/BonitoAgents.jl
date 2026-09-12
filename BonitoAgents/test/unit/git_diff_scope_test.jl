# Headless: the git diff a review tab gets is scoped to the PROJECT's folder.
#
# A project is routinely a package inside a bigger checkout, and the diff used to
# run at the git ROOT with no pathspec — so reviewing `pkg/` handed you every
# change in the monorepo, including files you were not looking at. This drives
# the worker-side responder directly (no browser, no server): it is the thing
# that builds the patch.
#
# File names are deliberately all distinct: `occursin("member.jl", patch)` would
# also match `member_new.jl`, which would quietly weaken every assertion here.
@testitem "unit:git_diff_scope" tags = [:unit] begin
    using Test
    using BonitoWorker

    mktempdir() do repo
        git(args...) = run(pipeline(`git -C $repo $args`; stdout = devnull, stderr = devnull))
        git("init", "-q")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "TestUser")
        mkpath(joinpath(repo, "pkg"))
        write(joinpath(repo, "pkg", "member.jl"), "member() = 1\n")
        write(joinpath(repo, "sibling.jl"), "sibling() = 1\n")
        git("add", "-A")
        git("commit", "-qm", "initial")

        # One tracked change and one untracked file on EACH side of the boundary.
        write(joinpath(repo, "pkg", "member.jl"), "member() = 2\n")
        write(joinpath(repo, "sibling.jl"), "sibling() = 2\n")
        write(joinpath(repo, "pkg", "arrival.jl"), "arrival() = :in\n")
        write(joinpath(repo, "bystander.jl"), "bystander() = :out\n")

        @testset "the repo root sees everything" begin
            res = BonitoWorker.git_diff_response("rid", repo, "")
            @test !haskey(res, "error")
            @test res["scope"] == ""            # no pathspec ⇒ whole repository
            for name in ("member.jl", "sibling.jl", "arrival.jl", "bystander.jl")
                @test occursin(name, res["patch"])
            end
        end

        @testset "a sub-folder sees only its own changes" begin
            res = BonitoWorker.git_diff_response("rid", joinpath(repo, "pkg"), "")
            @test !haskey(res, "error")
            @test res["scope"] == "pkg"
            # `repo` still names the git ROOT — the scope is what narrows it, and
            # the UI joins the two so the header cannot claim more than it shows.
            @test !isempty(res["repo"])
            @test occursin("member.jl", res["patch"])
            @test occursin("arrival.jl", res["patch"])     # untracked, scoped too
            # The siblings live in the same repository and must NOT be here.
            @test !occursin("sibling.jl", res["patch"])
            @test !occursin("bystander.jl", res["patch"])
        end

        @testset "a folder that isn't a repository says so" begin
            res = mktempdir() do plain
                BonitoWorker.git_diff_response("rid", plain, "")
            end
            @test haskey(res, "error")
            @test occursin("not a git repository", res["error"])
        end
    end
end
