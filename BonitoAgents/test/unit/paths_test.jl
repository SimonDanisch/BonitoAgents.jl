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

    @testset "project name from path" begin
        derive(path) = replace(basename(rstrip(path, '/')), r"[^a-zA-Z0-9_\-]" => "_")
        @test derive("/home/sdani/Programmieren/VulkanDev") == "VulkanDev"
        @test derive(BT.js_path("C:\\Users\\sdani\\Programmieren\\VulkanDev")) == "VulkanDev"
        @test derive("C:/Users/sdani/Programmieren/VulkanDev") == "VulkanDev"
        @test derive("C:UserssdaniProgrammierenVulkanDev") != "VulkanDev"
    end
end
