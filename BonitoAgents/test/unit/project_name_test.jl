# Every create path derives a default project name from the picked WORKER
# folder, and they used to derive it differently:
#
#   • `create_project_from_worker!`'s `name` default took a raw `basename`,
#   • the worker card's "+ Project" sanitized that basename itself,
#   • the dashboard's "New project" form had NO derivation at all — a blank Name
#     went through as "" and came back as "Project name must not be empty
#     (folder has no basename?)" about a folder the user had just picked.
#
# `project_name_from_path` is now the one derivation. The name is a DIRECTORY
# COMPONENT (the server mirror is `<working_dir>/<worker>-<name>`, and moving a
# project lands it at `joinpath(w.projects_root, p.name)`), so whatever it
# returns has to satisfy `valid_project_name`.
@testitem "unit:project_name" tags = [:unit] begin
    P = BonitoAgents.project_name_from_path
    V = BonitoAgents.valid_project_name

    @testset "the folder's own name" begin
        @test P("/sim/Programmieren/AgentsDev")  == "AgentsDev"
        @test P("/sim/Programmieren/AgentsDev/") == "AgentsDev"   # trailing slash
        @test P("/AgentsDev")                    == "AgentsDev"
    end

    @testset "foreign (windows) paths use the worker's separator, not ours" begin
        # `basename` on a Linux server returns the WHOLE backslash string, which
        # is how a project once got named after its entire path.
        @test P("C:\\Users\\sdani\\VulkanDev") == "VulkanDev"
        @test P("C:/Users/sdani/VulkanDev")    == "VulkanDev"
        @test P("//server/share/Proj")         == "Proj"
    end

    @testset "roots have no folder name to take" begin
        @test P("/")    == "project"
        @test P("")     == "project"
        @test P("C:/")  == "project"   # drive root, not a folder
        @test P("C:\\") == "project"
        @test P("/sim/..") == "project"
        # Only a BARE drive letter is a root. A colon is a legal character in a
        # Linux filename, so a folder that merely contains one keeps its name.
        @test P("/srv/c:weird") == "c:weird"
    end

    @testset "the name is the folder's, not an alphanumeric scrub" begin
        # The old rule rewrote everything outside [a-zA-Z0-9_-] to `_`, so
        # "Mantle DNN" became "Mantle_DNN" — a name the user never chose, for a
        # folder every filesystem in play accepts. Whether a name is WRITABLE is
        # the filesystem's call (it makes it at `mkpath`), not a regex's.
        @test P("/sim/Mantle DNN")       == "Mantle DNN"
        @test P("C:\\Users\\x\\My Proj") == "My Proj"
        @test P("/sim/a+b")              == "a+b"
        @test P("/sim/π-solver")         == "π-solver"
    end

    @testset "always a String, never a SubString" begin
        # `create_project_from_worker!` takes `name::String`, so a SubString
        # (what `lstrip`/`split` hand back) is a TypeError the user meets as
        # "Failed to import: expected String, got SubString".
        for p in ("/sim/AgentsDev", "/sim/.hidden", "/", "C:/", "/sim/Mantle DNN")
            @test P(p) isa String
        end
    end

    @testset "the containment invariant always holds" begin
        # The one thing the server DOES have to enforce: the name stays a single
        # path component, because it is joined onto `working_dir` and onto a
        # target worker's `projects_root`. Nothing derived may escape either.
        for p in ("/sim/my proj", "/sim/.hidden", "/sim/a+b", "/", "C:/", "",
                  "/sim/..", "/sim/π-solver", "/srv/c:weird",
                  "/sim/Programmieren/AgentsDev", "C:\\Users\\x\\My Proj")
            @test V(P(p))
        end
        # A leading dot would make the mirror a hidden directory (and covers
        # "." / ".."), so it is stripped rather than carried through.
        @test P("/sim/.hidden") == "hidden"
    end
end
