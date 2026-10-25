using Test, Jail

@testset "Jail" begin

    @testset "JailConfig defaults" begin
        cfg = JailConfig()
        @test cfg.gpu === true
        @test cfg.network === true
        @test cfg.backend === Jail.default_backend()
    end

    # ── Windows / native integrity-level sandbox ─────────────────────────────
    @static if Sys.iswindows()
        @testset "default backend" begin
            @test Jail.default_backend() === :integrity
        end

        @testset "cmd shape (julia self-relaunch launcher)" begin
            work = mktempdir()
            c  = jail(Cmd(["cmd", "/c", "echo hi"]); whitelist = [work])
            ex = collect(String, c.exec)
            @test occursin("julia", lowercase(ex[1]))
            @test any(a -> occursin("_lowbox_launcher.jl", a), ex)
            @test work in ex
            @test "--" in ex
            @test ex[end-2:end] == ["cmd", "/c", "echo hi"]   # command after `--`
        end

        # Real end-to-end: launches at Low integrity via the launcher and
        # checks the write-isolation guarantee on the host filesystem.
        @testset "real low-integrity write isolation" begin
            work    = mktempdir()
            outside = mktempdir()
            src = joinpath(work, "src.txt"); write(src, "seed\n")
            ok   = joinpath(work,    "ok.txt")
            evil = joinpath(outside, "evil.txt")

            run(jail(Cmd(["cmd", "/c", "copy", src, ok]); whitelist = [work]))
            @test isfile(ok)             # whitelist (Low-labelled) write reaches host

            @test !success(jail(Cmd(["cmd", "/c", "copy", src, evil]); whitelist = [work]))
            @test !isfile(evil)          # write outside whitelist is denied

            rm(work; recursive = true, force = true)
            rm(outside; recursive = true, force = true)
        end

        @testset "stdio flows through the jail" begin
            out = read(jail(Cmd(["cmd", "/c", "echo", "HELLO_JAILED"])), String)
            @test occursin("HELLO_JAILED", out)
        end
    end

    # ── Linux / bwrap + landrun (CI; not exercised on the Windows dev box) ────
    @static if Sys.islinux()
        @testset "default backend present" begin
            @test Jail.default_backend() in (:bwrap, :landrun)
        end
        if Sys.which("bwrap") !== nothing
            @testset "bwrap command shape" begin
                work = mktempdir()
                c = jail(Cmd(["echo", "hi"]); whitelist = [work], backend = :bwrap, gpu = false)
                ex = collect(String, c.exec)
                @test endswith(ex[1], "bwrap")
                @test "--bind" in ex
                @test work in ex
                @test ex[end-1:end] == ["echo", "hi"]
            end

            # ── R6: a non-existent whitelist dir must NOT abort the launch ────
            # Previously bwrap got `--bind <missing>` which aborts the whole
            # sandbox on a missing source. The dir should be created (it's RW)
            # and bound, or fall back to --bind-try — never plain --bind of a
            # path that doesn't exist.
            @testset "R6 missing whitelist dir doesn't abort" begin
                base = mktempdir()
                missing_dir = joinpath(base, "not_there_yet")
                @test !isdir(missing_dir)
                c = jail(Cmd(["echo", "hi"]); whitelist = [missing_dir],
                         backend = :bwrap, gpu = false)
                ex = collect(String, c.exec)
                # The whitelist dir is now bound (created → --bind, or --bind-try).
                @test missing_dir in ex
                # If we created it, the next index back is a bind verb; either
                # way the source exists or is bound best-effort, not plain
                # --bind of a missing path that would crash bwrap at runtime.
                idx = findfirst(==(missing_dir), ex)
                @test idx !== nothing
                @test ex[idx - 1] in ("--bind", "--bind-try")
                rm(base; recursive = true, force = true)
            end
        end
    end

    # ── macOS / sandbox-exec (untested backend; construct-only smoke) ─────────
    @static if Sys.isapple()
        @testset "default backend" begin
            @test Jail.default_backend() === :sandbox_exec
        end
        if Sys.which("sandbox-exec") !== nothing
            @testset "sandbox-exec profile shape" begin
                work = mktempdir()
                c = jail(Cmd(["echo", "hi"]); whitelist = [work])
                ex = collect(String, c.exec)
                @test ex[1] == "sandbox-exec"
                @test ex[2] == "-p"
                @test occursin("(deny default)", ex[3])
                @test occursin(work, ex[3])
                @test ex[end-1:end] == ["echo", "hi"]
            end
        end
    end

    # ── R2: Windows launcher aborts on integrity-label failure ───────────────
    # The launcher is a standalone script that runs `main()` on load, so we
    # can't include it here. Instead assert its labelling failure path now
    # ERRORS (aborts the launch) rather than `@warn`+continue, which would run
    # the child in a silently mislabeled sandbox. This is a source-contract
    # regression guard that runs on every platform.
    @testset "R2 launcher errors on icacls failure" begin
        launcher = joinpath(dirname(@__DIR__), "src", "_lowbox_launcher.jl")
        @test isfile(launcher)
        src = read(launcher, String)
        # The icacls block must turn a failure into an `error(...)` (abort).
        @test occursin("setintegritylevel", src)
        @test occursin("error(\"lowbox: failed to label", src)
        # And must NOT merely warn-and-continue on that failure.
        @test !occursin("@warn \"lowbox: failed to label", src)
    end
end
