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

    @testset "project name from path" begin
        derive(path) = replace(basename(rstrip(path, '/')), r"[^a-zA-Z0-9_\-]" => "_")
        @test derive("/home/sdani/Programmieren/VulkanDev") == "VulkanDev"
        @test derive(BT.js_path("C:\\Users\\sdani\\Programmieren\\VulkanDev")) == "VulkanDev"
        @test derive("C:/Users/sdani/Programmieren/VulkanDev") == "VulkanDev"
        @test derive("C:UserssdaniProgrammierenVulkanDev") != "VulkanDev"
    end
end
