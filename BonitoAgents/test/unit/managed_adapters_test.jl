# The worker's managed agent adapters (BonitoWorker's harnesses.jl), installed for
# real from a local Node mirror (test/testkit/fake_node.jl): real archives, real
# checksums, a real unpack, and an `npm` that installs from a local registry.
# `BonitoWorker/test/test_managed_adapters.jl` does the same against nodejs.org
# and npm themselves.

@testitem "unit:managed adapters install from a Node mirror" tags = [:unit] begin
    import BonitoAgents
    using Test, HTTP, SHA, JSON
    const BonitoWorker = BonitoAgents.BonitoWorker
    const BW = BonitoWorker
    const AP = BW.AgentProviders
    include(joinpath(@__DIR__, "..", "testkit", "fake_node.jl"))
    Sys.isunix() || return

    claude = "@agentclientprotocol/claude-agent-acp"
    codex = "@agentclientprotocol/codex-acp"
    dist = fake_node_dist(; published = Dict(claude => "1.0.0", codex => "2.0.0"))
    ENV["BT_FAKE_NPM_REGISTRY"] = dist.registry
    root = mktempdir()
    sync(spec) = BW.sync_harnesses!(spec; root, dist = dist.url)
    release_dir(version) = joinpath(root, BW.node_asset(version).name)
    try
        spec = BW.HarnessSpec("lts", Dict(claude => "latest", codex => "2.0.0"))
        @test sync(spec) == Dict("node" => "24.9.0", claude => "1.0.0", codex => "2.0.0")
        @test sort(installs(dist)) == ["$(claude)@1.0.0", "$(codex)@2.0.0"]
        # What a chat runs: the managed adapter, with the private Node first on PATH.
        managed = BW.managed_agent(AP.ClaudeCodeAgent(); root)
        @test read(`$(managed.bin)`, String) == "$(claude) 1.0.0\n"
        @test managed.path == BW.node_bin_dir(release_dir("24.9.0"))

        # Met already: nothing is downloaded or installed again.
        @test sync(spec)[claude] == "1.0.0"
        @test length(installs(dist)) == 2
        # "latest" follows the registry.
        publish!(dist, claude, "1.1.0")
        @test sync(spec)[claude] == "1.1.0"
        @test last(installs(dist)) == "$(claude)@1.1.0"

        # Another Node and a pinned adapter version: the old release goes, the
        # `node-version` marker names the new one.
        @test sync(BW.HarnessSpec("25", Dict(claude => "0.9.0")))["node"] == "25.1.0"
        @test !isdir(release_dir("24.9.0"))
        @test BW.current_node_dir(root) == release_dir("25.1.0")
        @test read(`$(BW.managed_agent(AP.ClaudeCodeAgent(); root).bin)`, String) == "$(claude) 0.9.0\n"

        # A download that does not match its published checksum is never unpacked,
        # and what was installed stays in use.
        corrupt_checksum!(dist, "22.20.0")
        err = try sync(BW.HarnessSpec("22", Dict(claude => "0.9.0"))); "" catch e; sprint(showerror, e) end
        @test occursin("checksum mismatch", err)
        @test !isdir(release_dir("22.20.0"))
        @test !any(f -> endswith(f, ".tar.gz"), readdir(root))
        @test BW.current_node_dir(root) == release_dir("25.1.0")

        # What the mirror or the registry does not have fails, naming it.
        err = try sync(BW.HarnessSpec("18", Dict(claude => "0.9.0"))); "" catch e; sprint(showerror, e) end
        @test occursin("lists no Node 18 release", err)
        @test_throws ProcessFailedException sync(BW.HarnessSpec("25", Dict("@x/not-published" => "latest")))
        # A version that is none is refused before anything is fetched.
        err = try BW.resolve_node_version("latest"; dist = dist.url); "" catch e; sprint(showerror, e) end
        @test occursin("\"lts\", a major", err)
        # An exact version needs no index: nothing is asked (this address answers nothing).
        @test BW.resolve_node_version("v22.1.0"; dist = "http://127.0.0.1:1") == "22.1.0"
        @test BW.resolve_node_version("22.1.0"; dist = "http://127.0.0.1:1") == "22.1.0"
    finally
        close(dist)
        delete!(ENV, "BT_FAKE_NPM_REGISTRY")
    end
end

# The worker keeps the adapters at the server's spec on its own: it waits for
# every chat to end, tries a failed install again soon, and meets a new spec at once.
@testitem "unit:managed adapters sync loop" tags = [:unit] begin
    import BonitoAgents
    using Test, HTTP, SHA, JSON
    const BonitoWorker = BonitoAgents.BonitoWorker
    const BW = BonitoWorker
    include(joinpath(@__DIR__, "..", "testkit", "fake_node.jl"))
    Sys.isunix() || return

    claude = "@agentclientprotocol/claude-agent-acp"
    dist = fake_node_dist(; published = Dict(claude => "1.0.0"))
    saved = Dict(k => get(ENV, k, nothing) for k in ("BONITOAGENTS_CONFIG_DIR", "BONITOAGENTS_NODE_DIST",
                                                     "BT_FAKE_NPM_REGISTRY"))
    ENV["BONITOAGENTS_CONFIG_DIR"] = mktempdir()
    ENV["BT_FAKE_NPM_REGISTRY"] = dist.registry
    # The mirror is down at first.
    ENV["BONITOAGENTS_NODE_DIST"] = "http://127.0.0.1:1"
    w = BW.Worker(BW.WorkerConfig(; server_url = "http://127.0.0.1:1", worker_id = "loop", name = "loop",
        mcp_command = "julia", mcp_arguments = String[], projects_root = mktempdir()))
    loop = nothing
    try
        # A chat is running when the spec arrives.
        @test BW.hold_adapters!(w)
        loop = lock(w.lock) do
            w.harness.spec = BW.HarnessSpec("lts", Dict(claude => "latest"))
            w.harness.pending = true
            w.harness.task = @async BW.harness_loop(w; recheck = 3600.0, retry = 1.0, idle_poll = 0.2)
        end
        sleep(1.0)
        @test !lock(() -> w.harness.syncing, w.lock)
        @test !isdir(BW.harness_root())
        # The chat ends: the install starts, and fails (no mirror).
        BW.release_adapters!(w)
        @test timedwait(() -> isdir(BW.harness_root()), 10.0) === :ok
        @test isempty(installs(dist))
        # The mirror is back: the next attempt comes after `retry`, not `recheck`.
        ENV["BONITOAGENTS_NODE_DIST"] = dist.url
        @test timedwait(() -> !isempty(installs(dist)), 20.0) === :ok
        @test timedwait(() -> BW.installed_harnesses(BW.harness_root(), [claude]) ==
                              Dict("node" => "24.9.0", claude => "1.0.0"), 10.0) === :ok
        # A new spec from the server is met right away, by the same loop.
        BW.schedule_harness_sync!(w, BW.HarnessSpec("lts", Dict(claude => "0.5.0")))
        @test lock(() -> w.harness.task, w.lock) === loop
        @test timedwait(() -> "$(claude)@0.5.0" in installs(dist), 20.0) === :ok
        # A session that starts now waits out an install, then holds the next one off.
        @test BW.hold_adapters!(w; timeout = 20.0)
        BW.release_adapters!(w)
    finally
        close(w)
        loop === nothing || wait(loop)
        close(dist)
        for (k, v) in saved
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end
