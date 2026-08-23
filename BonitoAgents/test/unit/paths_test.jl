# Headless: path-handling regressions (JS string escaping, breadcrumb
# segmentation under drive letters, project-name derivation). Ported from the
# inline `BonitoAgents paths` testset that used to live in runtests.jl.
@testitem "unit:paths" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    @testset "js_path" begin
        @test BT.js_path("C:\\Users\\sdani\\Proj") == "C:/Users/sdani/Proj"
        @test BT.js_path("/home/sdani/proj")       == "/home/sdani/proj"
        @test BT.js_path("")                       == ""
        @test BT.js_path("no\\separators\\here")   == "no/separators/here"
        @test !occursin('\\', BT.js_path("C:\\foo\\bar"))
    end

    @testset "breadcrumb_paths" begin
        @test BT.breadcrumb_paths("/home/sdani/proj") ==
              ["/", "/home", "/home/sdani", "/home/sdani/proj"]
        @test BT.breadcrumb_paths("/")        == ["/"]
        @test BT.breadcrumb_paths("")         == ["/"]
        @test BT.breadcrumb_paths("/single")  == ["/", "/single"]
        @test BT.breadcrumb_paths("C:/Users/sdani/Proj") ==
              ["C:/", "C:/Users", "C:/Users/sdani", "C:/Users/sdani/Proj"]
        @test BT.breadcrumb_paths("C:/")        == ["C:/"]
        @test BT.breadcrumb_paths("D:/Single")  == ["D:/", "D:/Single"]
        @test BT.breadcrumb_paths("c:/Users/sdani") == ["c:/", "c:/Users", "c:/Users/sdani"]
    end

    @testset "breadcrumb_root_label" begin
        @test BT.breadcrumb_root_label("/")     == "/"
        @test BT.breadcrumb_root_label("C:/")   == "C:"
        @test BT.breadcrumb_root_label("D:/")   == "D:"
        @test BT.breadcrumb_root_label("c:/")   == "c:"
    end

    @testset "disambiguate_labels" begin
        # No collision: everything stays at its basename.
        @test BT.disambiguate_labels(["/p/src/calc.jl", "/p/README.md"]) ==
              ["calc.jl", "README.md"]

        # The collision case this exists for. Only the colliding pair grows.
        @test BT.disambiguate_labels(["/p/src/a/types.jl", "/p/src/b/types.jl", "/p/run.jl"]) ==
              ["a/types.jl", "b/types.jl", "run.jl"]

        # One segment isn't always enough — keep growing until they're distinct.
        @test BT.disambiguate_labels(["/p/x/mod/types.jl", "/p/y/mod/types.jl"]) ==
              ["x/mod/types.jl", "y/mod/types.jl"]

        # Growing to disambiguate one pair must not silently collide a THIRD file
        # into it; the loop re-checks the labels it just produced.
        @test allunique(BT.disambiguate_labels(
            ["/p/a/b/f.jl", "/p/c/b/f.jl", "/p/d/b/f.jl"]))

        # A path can't grow past its own root: this must terminate, not spin.
        @test BT.disambiguate_labels(["/f.jl", "/f.jl"]) == ["/f.jl", "/f.jl"]

        @test BT.disambiguate_labels(String[]) == String[]
        @test BT.disambiguate_labels(["/p/only.jl"]) == ["only.jl"]
    end

    @testset "worker_join" begin
        J = BT.worker_join
        # A worker may run a different OS than this server, so the SERVER's
        # separator has no business in a path rooted on the WORKER.
        @test J("/home/sdani/projects", "Proj")     == "/home/sdani/projects/Proj"
        @test J("/home/sdani/projects/", "Proj")    == "/home/sdani/projects/Proj"
        @test J("C:\\Users\\sdani\\projects", "Proj") == "C:/Users/sdani/projects/Proj"
        @test J("C:/Users/sdani/projects", "Proj")  == "C:/Users/sdani/projects/Proj"
        # No mixed separators, ever — that is the shape `joinpath` produced on a
        # Linux server for a Windows worker (`C:\Users\x\projects/Proj`).
        @test !occursin('\\', J("C:\\Users\\sdani\\projects", "Proj"))

        # Idempotent under `normalize_worker_path`. Load-bearing: stored
        # `worker_path`s are normalized, and `find_project_by_location` compares
        # a freshly joined path against them by STRING. A join that normalized
        # differently would miss the sibling that already exists and create a
        # duplicate project instead of reusing it.
        for (root, name) in (("/home/x/projects", "P"), ("C:\\Users\\x\\p", "P"),
                             ("C:/Users/x/p/", "My Proj"))
            @test BT.normalize_worker_path(J(root, name)) == J(root, name)
        end

        # And the result is still ONE component deeper than the root, which is
        # what `valid_project_name` on the name buys us.
        @test J("/home/x/projects", "My Proj") == "/home/x/projects/My Proj"
    end

    # Regression guard for a bug that has now been introduced twice: a create /
    # move path reaching for the server's `joinpath` on a WORKER's root. It reads
    # correct on a Linux-to-Linux setup and silently produces a mixed-separator
    # path against a Windows worker — which then also defeats the
    # `find_project_by_location` string match. `worker_join` is the only way to
    # build such a path.
    @testset "no server-side joinpath onto a worker root" begin
        srcdir  = dirname(pathof(BonitoAgents))   # the package's own src/
        offenders = String[]
        for f in readdir(srcdir; join = true)
            endswith(f, ".jl") || continue
            for (i, line) in enumerate(eachline(f))
                # Skip prose; the docstrings deliberately quote the old form to
                # explain why it is wrong.
                startswith(lstrip(line), "#") && continue
                occursin(r"joinpath\([^)]*projects_root", line) &&
                    push!(offenders, "$(basename(f)):$i: $(strip(line))")
            end
        end
        @test isempty(offenders)
        isempty(offenders) || @info "use worker_join instead" offenders
    end

    # Name derivation used to be asserted here against a `derive` helper the
    # testset defined ITSELF — a copy of the old alphanumeric-scrub rule that no
    # product code has called since `project_name_from_path` became the one
    # derivation. It passed while testing nothing. It lives in
    # `project_name_test.jl` now, against the real function.
end
