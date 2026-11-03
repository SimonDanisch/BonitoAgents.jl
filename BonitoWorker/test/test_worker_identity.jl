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
end
