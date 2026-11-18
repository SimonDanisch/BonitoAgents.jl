module WorkerIdentityTests
using Test, BonitoWorker
const BW = BonitoWorker

@testset "Persistent worker identity" begin
    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            ids = fetch.([Threads.@spawn BW.load_or_generate_worker_id() for _ in 1:24])
            id = first(ids)
            @test all(==(id), ids)
            @test strip(read(BW.worker_id_path(), String)) == id
            @test !isfile(BW.worker_id_path() * ".lock")

            BW.write_config!(; server_url = "https://example.invalid", credential = "test:secret", name = "Test worker")
            config = BW.JSON.parsefile(BW.config_path())
            @test config["worker_id"] == id
            @test config["credential"] == "test:secret"
            Sys.iswindows() || @test filemode(BW.config_path()) & 0o777 == 0o600
            Sys.iswindows() || @test filemode(BW.worker_id_path()) & 0o777 == 0o600

            for remove in [p -> rm(p), p -> write(p, "")]
                remove(BW.worker_id_path())
                @test BW.load_or_generate_worker_id() == id
                @test read(BW.worker_id_path(), String) == id
            end

            # An installer rerun and an old running worker's update both retain the id.
            BW.write_config!(; server_url = "https://example.invalid", name = "Test worker")
            config = BW.JSON.parsefile(BW.config_path())
            @test config["worker_id"] == id
            @test config["credential"] == "test:secret"
            delete!(config, "worker_id")
            BW.write_update_spec!(Dict{String, Any}(config), Dict("repo" => "updated"))
            @test BW.JSON.parsefile(BW.config_path())["worker_id"] == id
            rm(BW.worker_id_path())
            @test BW.load_or_generate_worker_id() == id

            # Conflicting copies must never silently change the worker's identity.
            write(BW.worker_id_path(), "different-worker")
            @test_throws ErrorException BW.load_or_generate_worker_id()
            @test read(BW.worker_id_path(), String) == "different-worker"
            @test BW.JSON.parsefile(BW.config_path())["worker_id"] == id
        end
    end

    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            # Upgrade an installation written before config.json carried an id.
            id = BW.generate_worker_id()
            write(BW.worker_id_path(), id)
            write(BW.config_path(), BW.JSON.json(Dict("credential" => "old:secret")))
            @test BW.load_or_generate_worker_id() == id
            @test BW.JSON.parsefile(BW.config_path())["worker_id"] == id
            @test BW.JSON.parsefile(BW.config_path())["credential"] == "old:secret"
            rm(BW.worker_id_path())
            @test BW.load_or_generate_worker_id() == id
        end
    end

    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            write(BW.config_path(), BW.JSON.json(Dict("credential" => "old:secret")))
            @test_throws ErrorException BW.load_or_generate_worker_id()
            @test !isfile(BW.worker_id_path())
            @test BW.JSON.parsefile(BW.config_path())["credential"] == "old:secret"
        end
    end
end

# The whole config directory was wiped under a running worker (11-16: every file
# of the Scratch space). The worker ran on from memory, then minted a NEW id on
# its next agent spawn, and the reboot found no config at all. A running worker
# now puts its files back before anything that outlives it is spawned.
@testset "a running worker puts its identity files back" begin
    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            id = BW.load_or_generate_worker_id()
            spec = Dict("repo" => "r", "rev" => "main", "source_id" => "abc", "bonito_url" => "u", "bonito_rev" => "master")
            BW.write_config!(; server_url = "https://example.invalid", credential = "test:secret", name = "Test worker",
                               update_spec = spec, auto_update = true)
            installed = BW.JSON.parsefile(BW.config_path())
            @test installed["update_spec"] == spec && installed["auto_update"] === true
            c = BW.WorkerConfig(; server_url = "https://example.invalid", credential = "test:secret",
                                  worker_id = id, name = "Test worker", mcp_command = "julia",
                                  mcp_arguments = String[], projects_root = dir,
                                  update_config = Dict{String,Any}(installed))
            @test !BW.persist_identity!(c)                      # all there: nothing written
            @test BW.JSON.parsefile(BW.config_path()) == installed

            rm(BW.worker_id_path()); rm(BW.config_path())
            @test (@test_logs (:warn, r"identity file was missing") (:warn, r"config was missing") BW.persist_identity!(c))
            @test strip(read(BW.worker_id_path(), String)) == id
            restored = BW.JSON.parsefile(BW.config_path())
            @test restored["worker_id"] == id
            @test restored["credential"] == "test:secret"
            @test restored["server_url"] == "https://example.invalid"
            @test restored["update_spec"] == spec && restored["auto_update"] === true
            Sys.iswindows() || @test filemode(BW.config_path()) & 0o777 == 0o600
            # The next start is the same worker, with the same credential.
            @test BW.load_or_generate_worker_id() == id
            @test BW.read_config()["worker_id"] == id
            # What the spawn carries is the id the worker runs as, not a fresh one.
            @test BW.owner_env(c.worker_id)[BW.AGENT_OWNER_ENV] == id

            # Only the id file gone: the config is left as it is.
            rm(BW.worker_id_path())
            @test (@test_logs (:warn, r"identity file was missing") BW.persist_identity!(c))
            @test strip(read(BW.worker_id_path(), String)) == id
            @test BW.JSON.parsefile(BW.config_path()) == restored

            # Another install's identity on disk is reported, never overwritten.
            write(BW.worker_id_path(), "other-worker")
            @test !(@test_logs (:error, r"not this worker's") BW.persist_identity!(c))
            @test read(BW.worker_id_path(), String) == "other-worker"
            @test BW.owner_env(c.worker_id)[BW.AGENT_OWNER_ENV] == id

            # A worker that was not installed (dev, standalone) has no config to restore.
            rm(BW.worker_id_path()); rm(BW.config_path())
            bare = BW.WorkerConfig(; server_url = "http://127.0.0.1:1", worker_id = id, name = "n",
                                     mcp_command = "julia", mcp_arguments = String[], projects_root = dir)
            @test (@test_logs (:warn, r"identity file was missing") BW.persist_identity!(bare))
            @test strip(read(BW.worker_id_path(), String)) == id
            @test !isfile(BW.config_path())
        end
    end
end

# The installer, run without a credential on a machine that had lost its config,
# wrote `credential: ""` and reported success; the worker was then refused every
# 5 s for hours, the reason in a log nobody reads (11-18).
@testset "installing needs a credential for a server that checks one" begin
    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            url = "https://agents.example"
            err = try BW.write_config!(; server_url = url, name = "n"); nothing catch e e end
            @test err isa BW.InstallError
            msg = sprint(showerror, err)
            @test occursin("Add worker", msg) && occursin(url, msg)
            @test occursin("curl -fsSL $(url)/install.jl | julia - <credential>", msg)
            @test occursin("this machine has none", msg)
            @test !isfile(BW.config_path())                       # nothing half-installed

            # Not `name:password`: refused before anything is written.
            for bad in ("w-1", ":secret", "w-1:")
                @test_throws BW.InstallError BW.write_config!(; server_url = url, credential = bad, name = "n")
            end
            @test !isfile(BW.config_path())
            err = try BW.write_config!(; server_url = url, credential = "w-1", name = "n"); nothing catch e e end
            @test err isa BW.InstallError && occursin("name:password", sprint(showerror, err))

            # A server on this machine lets every worker in: no credential needed.
            for local_url in ("http://localhost:8038", "http://127.0.0.1:8038", "http://[::1]:8038")
                BW.write_config!(; server_url = local_url, name = "n")
                @test BW.JSON.parsefile(BW.config_path())["credential"] == ""
                @test BW.JSON.parsefile(BW.config_path())["server_url"] == local_url
            end
            @test BW.local_server("https://127.0.0.1:8443/") && !BW.local_server("https://127.example") &&
                  !BW.local_server("http://192.168.1.2:8038") && !BW.local_server(url)

            # A credential kept for another server is no use and is not thrown away either.
            BW.write_config!(; server_url = url, credential = "w-1:secret", name = "n")
            err = try BW.write_config!(; server_url = "https://other.example", name = "n"); nothing catch e e end
            @test err isa BW.InstallError
            @test occursin("is for $(url)", sprint(showerror, err))
            @test BW.JSON.parsefile(BW.config_path())["credential"] == "w-1:secret"
            @test BW.JSON.parsefile(BW.config_path())["server_url"] == url
            # The install.jl served by the server prints an InstallError as the outcome.
            script = read(joinpath(@__DIR__, "..", "..", "BonitoAgents", "assets", "install.jl"), String)
            @test occursin("BonitoWorker.InstallError", script) && occursin("==> Not installed", script)
        end
    end
end

# A missing config made the unit crash-loop: exit 1, restart in 5 s, 4 s of CPU
# per attempt, for as long as nobody looked (11-18: 33 rounds). It is nothing a
# restart fixes, so the worker says so once and exits with a status the unit does
# not restart on.
@testset "a missing config stops the service instead of restarting it" begin
    mktempdir() do dir
        withenv("BONITOAGENTS_CONFIG_DIR" => dir) do
            @test_throws BW.ConfigMissing BW.read_config()
            msg = sprint(showerror, BW.ConfigMissing(BW.config_path()))
            @test occursin(BW.config_path(), msg) && occursin("Add worker", msg) && occursin("install.jl", msg)
            @test occursin("RestartPreventExitStatus=78", BW.render_service_unit(; projects_root = dir))
            write(BW.config_path(), BW.JSON.json(Dict("server_url" => "https://a.example", "credential" => "w:p")))
            @test BW.read_config()["server_url"] == "https://a.example"
            rm(BW.config_path())

            # The unit's own command, on this machine, without a config: status
            # 78, the reason in the log the fleet tool reads AND on stderr for journald.
            errfile = joinpath(dir, "stderr.txt")
            cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e "using BonitoWorker; BonitoWorker.start()"`
            p = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = errfile))
            @test p.exitcode == BW.EXIT_CONFIG == 78
            @test occursin("no config at $(BW.config_path())", read(errfile, String))
            @test occursin("no config at $(BW.config_path())", read(BW.worker_log_path(), String))
            @test !isfile(BW.pidfile_path())                      # it never claimed to run
        end
    end
end

# The installer waits for the worker it started and says what it found out: a
# refused credential shows up here and now, not in a log later.
@testset "the installer reports the worker's first connection" begin
    mktempdir() do dir
        log = joinpath(dir, "worker.log")
        write(log, "2026-11-18T11:00:00 INFO: BonitoWorker: registered with server  name=Old  @ BonitoWorker worker.jl:247\n")
        mark = BW.log_mark(log)                                   # the old run's lines do not count
        refusal = "2026-11-18T12:16:45 ERROR: BonitoWorker: the server refused this worker. This worker dials " *
                  "without a credential  reason=unauthorized: no valid worker credential  @ BonitoWorker worker.jl:187"
        writer = @async (sleep(0.3); open(io -> println(io, refusal), log, "a"))
        outcome = BW.first_connection(log, mark; timeout = 10)
        wait(writer)
        @test outcome !== nothing && !outcome.ok
        @test startswith(outcome.line, "2026-11-18T12:16:45 ERROR: BonitoWorker: the server refused this worker")
        @test occursin("reason=unauthorized", outcome.line) && !occursin("@ BonitoWorker", outcome.line)

        mark = BW.log_mark(log)
        writer = @async (sleep(0.3); open(io -> println(io, "2026-11-18T12:17:00 INFO: BonitoWorker: registered with server  name=Desktop  @ BonitoWorker worker.jl:247"), log, "a"))
        outcome = BW.first_connection(log, mark; timeout = 10)
        wait(writer)
        @test outcome.ok && outcome.line == "2026-11-18T12:17:00 INFO: BonitoWorker: registered with server  name=Desktop"
        @test BW.first_connection(log, BW.log_mark(log); timeout = 0.5) === nothing      # nothing yet
        @test BW.connection_outcome("x INFO: BonitoWorker: connecting  url=wss://a/w") === nothing
        @test !BW.connection_outcome("x ERROR: BonitoWorker: connection failed  exception=timeout").ok
        @test !BW.connection_outcome("x ERROR: BonitoWorker: the server did not take the connection (502)").ok

        # A first install has no log yet: it is waited for, not an error.
        later = joinpath(dir, "later", "worker.log")
        writer = @async (sleep(0.3); write(later, "x INFO: BonitoWorker: registered with server  name=N\n"))
        @test BW.first_connection(later, 0; timeout = 10).ok
        wait(writer)
        # Nothing to wait for when no worker was (re)started.
        @test BW.report_connection(false, later, 0) === nothing
        @test BW.report_connection(true, later, 0; timeout = 5).ok
    end
end

# The refusal the log shows for a worker without a credential names the cure
# (11-18: "unauthorized" every 5 s, and nothing about what to do).
@testset "a refused worker without a credential is told the cure" begin
    without = BW.WorkerConfig(; server_url = "https://agents.example", worker_id = "w", name = "n",
                                mcp_command = "julia", mcp_arguments = String[], projects_root = "/tmp")
    hint = BW.refusal_hint(without)
    @test occursin("without a credential", hint) && occursin("Add worker", hint)
    @test occursin("curl -fsSL https://agents.example/install.jl | julia - <credential>", hint)
    with = BW.WorkerConfig(; server_url = "https://agents.example", credential = "w:p", worker_id = "w", name = "n",
                             mcp_command = "julia", mcp_arguments = String[], projects_root = "/tmp")
    @test BW.refusal_hint(with) == ""
end
end
