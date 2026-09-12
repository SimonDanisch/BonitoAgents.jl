# A worker can run a different OS than the server, so `ProjectInfo.worker_path`
# is a FOREIGN path the server only stores and echoes back.
#
# Reported from a real Windows worker: `session/load` ran with
#   cwd: 'C:UserssdaniProgrammierenVulkanDev'
# — `C:\Users\sdani\Programmieren\VulkanDev` with every separator gone. That is
# the signature of a JS string-literal parse: `\U`, `\s` and `\P` are invalid
# escapes, so JS drops the backslash and keeps the letter. The cwd then doesn't
# exist and every session bring-up for that project fails.
#
# Forward slashes work everywhere on Windows and survive JS, JSON and HTML
# untouched, so paths are normalized once on the way in.
@testitem "unit:worker_path" tags = [:unit] begin
    N = BonitoAgents.normalize_worker_path
    W = BonitoAgents.windows_path
    M = BonitoAgents.mangled_windows_path

    @testset "windows paths are normalized to forward slashes" begin
        @test N("C:\\Users\\sdani\\Programmieren\\VulkanDev") ==
              "C:/Users/sdani/Programmieren/VulkanDev"
        @test N("C:\\Users\\sdani") == "C:/Users/sdani"
        @test N("d:\\proj") == "d:/proj"           # lower-case drive letter
        @test N("\\\\server\\share\\proj") == "//server/share/proj"   # UNC
        # Already normalized ⇒ unchanged (idempotent, so re-import is stable).
        @test N("C:/Users/sdani") == "C:/Users/sdani"
        @test N(N("C:\\Users\\sdani")) == N("C:\\Users\\sdani")
    end

    @testset "linux paths are left completely alone" begin
        # A backslash is a LEGAL character in a Linux filename — rewriting one
        # would corrupt the path, so only drive-letter/UNC paths are touched.
        @test N("/home/simon/dev") == "/home/simon/dev"
        @test N("/home/simon/weird\\name") == "/home/simon/weird\\name"
        @test !W("/home/simon/weird\\name")
        @test W("C:\\Users\\x") && W("C:/Users/x") && W("\\\\srv\\share")
    end

    @testset "an already-mangled path is detected, not silently stored" begin
        # The exact string from the bug report.
        @test M("C:UserssdaniProgrammierenVulkanDev")
        @test M("D:proj")
        # Healthy paths must never trip the detector.
        @test !M("C:\\Users\\sdani")
        @test !M("C:/Users/sdani")
        @test !M("/home/simon")
        @test !M("")
        # It is unrepairable by construction: the separators are gone, so the
        # normalizer must NOT pretend it fixed anything.
        @test N("C:UserssdaniProgrammierenVulkanDev") ==
              "C:UserssdaniProgrammierenVulkanDev"
    end

    @testset "project creation refuses a mangled worker path" begin
        dir = mktempdir()
        state = BonitoAgents.ServerState(; state_dir = joinpath(dir, "state"),
                                           working_dir = joinpath(dir, "work"),
                                           worker_secret = "test-secret")
        # Fails on the PATH, not on "unknown worker" — the guard runs first, so
        # the operator gets an actionable message instead of a broken project.
        err = try
            BonitoAgents.create_project_from_worker!(
                state, "nosuchworker", "C:UserssdaniProgrammierenVulkanDev";
                name = "VulkanDev", start_session = false)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("lost its separators", err.msg)
    end
end
