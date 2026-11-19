# "Add worker" shows `curl -fsSL <server>/install.sh | sh -s <credential>`: the
# credential is the script's argument, and it has to reach the Julia installer
# as that one's argument. Older commands set BONITOAGENTS_WORKER_CREDENTIAL,
# which the installer still reads when no argument comes.
@testitem "unit:install_credential_arg" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    spec = Dict{String,Any}("repo" => "r", "rev" => "main", "source_id" => "abc",
                            "bonito_url" => "u", "bonito_rev" => "master")
    if !Sys.iswindows()
        script = BT.render_install_script(read(joinpath(BT.ASSETS_DIR, "install.sh"), String),
                                          "https://team.example.com", spec)
        # Stand-ins: `curl` serves nothing, `julia` says what it was started with.
        bin = mktempdir()
        write(joinpath(bin, "curl"), "#!/bin/sh\nexit 0\n")
        write(joinpath(bin, "julia"), "#!/bin/sh\necho \"julia \$*\"\n")
        chmod(joinpath(bin, "curl"), 0o755); chmod(joinpath(bin, "julia"), 0o755)
        env = ("PATH" => bin * ":" * ENV["PATH"],)
        run_script(args...) = strip(read(pipeline(addenv(`sh -s $args`, env...); stdin = IOBuffer(script)), String))
        @test run_script("w-1a:2b") == "julia - w-1a:2b"
        @test run_script() == "julia -"          # a server on this machine: no credential
    end

    # The installer takes its first argument, else the variable older commands set.
    jl = BT.render_install_script(read(joinpath(BT.ASSETS_DIR, "install.jl"), String),
                                  "https://team.example.com", spec)
    line = only(filter(l -> startswith(l, "const CREDENTIAL"), split(jl, '\n')))
    credential(args, env) = withenv("BONITOAGENTS_WORKER_CREDENTIAL" => env) do
        m = Module()
        Core.eval(m, :(const ARGS = $args))
        Core.eval(m, Meta.parse(line))
        Core.eval(m, :CREDENTIAL)
    end
    @test credential(["w-1a:2b"], nothing) == "w-1a:2b"
    @test credential(String[], "w-old:env") == "w-old:env"
    @test credential(String[], nothing) == ""
end

# An update finds its own services on their ports: Authelia keeps running through
# it (a stop logs every browser out). The port check took that for a foreign
# program and failed, after it had already stopped the server: every update from
# 2026-10-18 on left the dashboard down. The check runs first now and accepts
# what this install's own units hold. Here: the installer's own functions, with
# `sudo` answering what `ss` and a process's cgroup would.
@testitem "unit:install_server_port_check" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    src = read(joinpath(BT.ASSETS_DIR, "install_server.sh"), String)
    fn(name) = match(Regex("^$name\\(\\) \\{.*?^\\}", "ms"), src).match
    if !Sys.iswindows()
        prog = """
        set -euo pipefail
        ok()   { echo "ok: \$*"; }
        info() { echo "info: \$*"; }
        fail() { echo "ERROR: \$*" >&2; exit 1; }
        sudo() {   # FAKE_SS: what ss lists; FAKE_CGROUP_<pid>: that process's cgroup
            case "\$1" in
                ss)  printf '%s' "\${FAKE_SS-}" ;;
                cat) local pid="\${2#/proc/}"; pid="\${pid%/cgroup}"; local v="FAKE_CGROUP_\$pid"
                     [[ -n "\${!v-}" ]] || return 1; printf '%s\\n' "\${!v}" ;;
                *)   echo "unexpected sudo \$*" >&2; return 99 ;;
            esac
        }
        $(fn("unit_of"))
        $(fn("check_port"))
        OWN_UNITS=(bonitoagents-server bonitoagents-authelia bonitoagents-caddy)
        check_port 9091
        """
        function check(ss; cgroups...)
            out, err = IOBuffer(), IOBuffer()
            env = ["FAKE_SS" => ss; ["FAKE_CGROUP_$(String(k)[2:end])" => v for (k, v) in cgroups]]
            p = run(pipeline(ignorestatus(addenv(`bash -c $prog`, env...)); stdout = out, stderr = err))
            return (; ok = success(p), out = String(take!(out)), err = String(take!(err)))
        end
        authelia = """LISTEN 0 4096 127.0.0.1:9091 0.0.0.0:* users:(("authelia",pid=350914,fd=8))"""

        @test check("").ok                                       # free
        r = check(authelia; p350914 = "0::/system.slice/bonitoagents-authelia.service")
        @test r.ok                                               # this install's Authelia
        @test occursin("bonitoagents-authelia", r.out)
        # cgroup v1 lists one line per controller
        @test check(authelia; p350914 = "12:pids:/system.slice/bonitoagents-authelia.service\n" *
                                        "1:name=systemd:/system.slice/bonitoagents-authelia.service").ok
        # another instance's Authelia, a program in someone's session, a process gone
        for cg in ("0::/system.slice/bonitoagents-roundtrip-authelia.service",
                   "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-python3.scope")
            r = check(authelia; p350914 = cg)
            @test !r.ok
            @test occursin("port 9091 is already in use on this machine", r.err)
        end
        @test !check(authelia).ok
        # a holder ss names no process for, and two holders of which one is foreign
        @test !check("LISTEN 0 4096 127.0.0.1:9091 0.0.0.0:*").ok
        two = authelia * "\n" * """LISTEN 0 5 [::1]:9091 [::]:* users:(("python3",pid=411241,fd=3))"""
        @test !check(two; p350914 = "0::/system.slice/bonitoagents-authelia.service",
                          p411241 = "0::/user.slice/user-1000.slice/session-4.scope").ok
    end

    # Nothing stops before the check: a failed check leaves the running install
    # as it was. The server is restarted (an update's server ran until then).
    lines = split(src, '\n')
    check_at = findfirst(l -> occursin("check_port \"\$p\"", l), lines)
    stops = findall(l -> occursin(r"systemctl (stop|restart|kill)\b", l), lines)
    @test check_at !== nothing
    @test all(>(check_at), stops)
    @test any(l -> occursin("systemctl restart \"\$UNIT_SERVER\"", l), lines)
    @test !any(l -> occursin("systemctl start \"\$UNIT_SERVER\"", l), lines)
end

# The server ran out of memory every second or third update, precompiling
# BonitoAgents next to the running server (2026-11-18). An update compiled the
# whole env twice: once into the INSTALLER's depot, which the server never reads,
# then into the service's. And BonitoAgents' compile peaked at 4.7 GB; one image
# thread and a heap hint bring it to 3.2 GB. Here the installer's own functions
# run with a `sudo` and two `julia`s that print what they were given.
@testitem "unit:install_server_precompile_env" tags = [:unit] begin
    using BonitoAgents
    const BT = BonitoAgents

    if !Sys.iswindows()
        src = read(joinpath(BT.ASSETS_DIR, "install_server.sh"), String)
        fn(name) = match(Regex("^$name\\(\\) \\{.*?^\\}", "ms"), src).match
        as_service = match(r"^as_service\(\) \{.*\}$"m, src).match
        dir = mktempdir()
        data = mkpath(joinpath(dir, "data"))
        for name in ("installer-julia", "service-julia")
            path = joinpath(dir, name)
            write(path, """
                #!/usr/bin/env bash
                echo "$name auto=\${JULIA_PKG_PRECOMPILE_AUTO-unset} threads=\${JULIA_IMAGE_THREADS-unset} heap=\${JULIA_HEAP_SIZE_HINT-unset} home=\$HOME pwd=\$PWD \$*"
                """)
            chmod(path, 0o755)
        end
        prog = """
        set -euo pipefail
        sudo() { [[ "\$1" == -u ]] && shift 2; "\$@"; }   # as root: runs the command
        SERVICE_USER=bonitoagents DATA_DIR=$data MONOREPO_DIR=/repo
        JULIA_BIN=$(joinpath(dir, "installer-julia")) SERVICE_JULIA=$(joinpath(dir, "service-julia"))
        $as_service
        $(fn("update_env"))
        $(fn("precompile_service"))
        update_env
        precompile_service
        """
        # Only what the installer sets: the caller's own settings are removed (an
        # eval session runs with JULIA_PKG_PRECOMPILE_AUTO=0).
        lines = readlines(addenv(`bash -c $prog`, "JULIA_PKG_PRECOMPILE_AUTO" => nothing,
                                 "JULIA_IMAGE_THREADS" => nothing, "JULIA_HEAP_SIZE_HINT" => nothing))
        update = only(filter(startswith("installer-julia"), lines))
        @test occursin("auto=0", update)                 # no compile into the installer's depot
        @test occursin("Pkg.update()", update)
        service = only(filter(startswith("service-julia"), lines))
        @test occursin("auto=unset", service)            # the server's depot IS compiled
        @test occursin("threads=1", service)
        @test occursin("heap=2G", service)
        @test occursin("home=$data pwd=$data", service)
        @test occursin("--project=/repo", service)
        @test occursin("using BonitoAgents", service)
    end
end
