# Worker-install revision templating (#37). The worker one-liner must land
# workers on the SAME code the server runs, in all three deployment shapes:
# a git checkout (branch/sha), a tagged release bundle (no git tree → the
# version's `v` tag), and a from-`main` Pkg install (prerelease version →
# `main`). The git path is environment-dependent; the pure version→rev
# mapping is pinned here.
@testitem "unit:install_rev" tags = [:unit] begin
    using BonitoAgents

    @testset "clean release versions map to their v-tag" begin
        @test BonitoAgents.install_rev_for(v"0.1.0")  == "v0.1.0"
        @test BonitoAgents.install_rev_for(v"1.2.3")  == "v1.2.3"
        @test BonitoAgents.install_rev_for(v"10.0.0") == "v10.0.0"
    end

    @testset "non-release versions can only guess main" begin
        @test BonitoAgents.install_rev_for(v"0.2.0-DEV")    == "main"
        @test BonitoAgents.install_rev_for(v"1.0.0-rc1")    == "main"
        @test BonitoAgents.install_rev_for(v"1.0.0+build3") == "main"
        @test BonitoAgents.install_rev_for(nothing)         == "main"
    end

    @testset "the env override beats everything" begin
        withenv("BONITOAGENTS_INSTALL_REV" => "v9.9.9") do
            @test BonitoAgents.current_repo_rev() == "v9.9.9"
        end
    end

    @testset "a git checkout resolves to the checked-out branch" begin
        # This test runs from the monorepo checkout, so the git path applies:
        # the templated rev must be exactly what `git` reports for HEAD.
        repo = abspath(pkgdir(BonitoAgents), "..")
        expected = strip(read(`git -C $repo rev-parse --abbrev-ref HEAD`, String))
        expected == "HEAD" && (expected = strip(read(`git -C $repo rev-parse HEAD`, String)))
        @test BonitoAgents.current_repo_rev() == expected
    end
end
