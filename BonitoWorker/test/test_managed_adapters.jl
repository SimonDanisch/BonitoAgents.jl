# The managed agent adapters for real: Node from nodejs.org (checksum-verified)
# and the real `claude-agent-acp` from npm, installed the way a worker does it
# (`sync_harnesses!`), then started the way a chat starts it (`agent_command`)
# and asked for an ACP `initialize`, which needs no login. That proves a fresh
# machine gets a working adapter without anything installed by hand.
#
# The install goes to a cache that outlives the run (a second run finds it
# current and only asks the registry for "latest"); BonitoAgents' unit items
# cover the same code against a local mirror on every run. Skipped, saying so,
# without a network.

using Test, JSON, HTTP
using BonitoWorker
const BW = BonitoWorker
const AP = BW.AgentProviders

online = try
    HTTP.get("https://nodejs.org/dist/index.json"; retry = false, request_timeout = 15).status == 200
catch e
    e isa HTTP.Exceptions.HTTPError || e isa Base.IOError || rethrow()
    false
end

@testset "managed adapters from nodejs.org and npm" begin
    if !online || !Sys.isunix()
        @info "skipping: nodejs.org is not reachable from here (or not a Unix machine)"
        return
    end
    root = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "bonitoagents-test", "harnesses")
    claude = AP.npm_package(AP.ClaudeCodeAgent())
    installed = BW.sync_harnesses!(BW.HarnessSpec("lts", Dict(claude => "latest")); root)
    @test occursin(r"^\d+\.\d+\.\d+$", installed["node"])
    @test occursin(r"^\d+\.\d+\.\d+", installed[claude])
    @test BW.installed_harnesses(root, [claude]) == installed

    # What a chat runs on this worker: the managed adapter, on the private Node.
    saved = get(ENV, "BONITOAGENTS_CONFIG_DIR", nothing)
    config = mktempdir()
    symlink(root, joinpath(config, "harnesses"))
    ENV["BONITOAGENTS_CONFIG_DIR"] = config
    agent = try
        withenv(() -> BW.agent_command(AP.ClaudeCodeAgent()), "CLAUDE_AGENT_ACP" => nothing)
    finally
        saved === nothing ? delete!(ENV, "BONITOAGENTS_CONFIG_DIR") : (ENV["BONITOAGENTS_CONFIG_DIR"] = saved)
    end
    release = realpath(joinpath(root, BW.node_asset(installed["node"]).name))
    @test startswith(realpath(agent.bin), realpath(root))
    @test realpath(agent.path) == BW.node_bin_dir(release)

    env = BW.inherited_env()
    env["PATH"] = agent.path * ":" * get(env, "PATH", "")
    proc = open(Cmd(`$(agent.bin)`; env, dir = mktempdir()), "r+")
    try
        println(proc, JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
            "params" => Dict("protocolVersion" => 1,
                             "clientCapabilities" => Dict("fs" => Dict("readTextFile" => false,
                                                                       "writeTextFile" => false))))))
        reply = Channel{Any}(1)
        reader = @async for line in eachline(proc)
            msg = JSON.parse(line)
            get(msg, "id", nothing) == 1 && (put!(reply, msg); break)
        end
        @test timedwait(() -> isready(reply) || istaskdone(reader), 60.0) === :ok
        msg = isready(reply) ? take!(reply) : nothing
        @test msg !== nothing && msg["result"]["protocolVersion"] isa Number
        # The adapter runs on the worker's own Node, not one the machine has.
        if Sys.islinux()
            node = readlink("/proc/$(getpid(proc))/exe")
            @test startswith(node, release)
        end
    finally
        kill(proc)
    end
end
