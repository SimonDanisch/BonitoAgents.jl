# Agent subprocesses must not outlive the worker that started them.
#
# Two leaks, two mechanisms, and the second is the one that actually accumulated:
#
#   1. Killing an agent reached the agent ALONE. Its children — the MCP servers,
#      and the Julia eval workers under those — were in the worker's own process
#      group and simply carried on. Those are where the memory is: a julia eval
#      worker is hundreds of MB against the node agent's tens.
#   2. A worker killed with SIGKILL runs no cleanup at all, so its agents survive
#      and get reparented to init. Measured at 3 per full e2e run, reaching 55
#      live orphans (oldest 41 hours) over a few days. Individually invisible;
#      together they pushed the box to ~93% memory and made unrelated tests fail
#      on timing, which is a miserable way to find out.
#
# `detach` at spawn + `kill_process_group!` covers (1); `reap_stray_agents!` at
# startup covers (2), because nothing else can — the dead worker is gone.

using Test
using BonitoWorker
const BW = BonitoWorker

using AgentProviders

alive(pid) = ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(0)) == 0

# A REAL provider descriptor pointed at a script instead of an agent. The spawn
# paths read `bin`/`args`/`env`/`elicitation`, and taking them off the actual
# type means a field that moves breaks this test instead of sliding past a
# look-alike struct that duck-types just as well.
probe_provider(bin, args; env = Dict{String,String}()) =
    AgentProviders.MockAgent(bin, args, env, Dict{String,Any}())

@testset "agent process reaping" begin
    if !Sys.isunix()
        @test_skip "process groups / /proc are Unix-only"
    else
        @testset "the whole GROUP dies, not just the agent" begin
            # A detached parent (what the agent is, post-`detach`) that itself
            # spawns a child. The grandchild is the thing that used to survive.
            proc = open(detach(Cmd(`bash -c "sleep 300 & echo \$!; wait"`)), "r+")
            try
                grandchild = parse(Int, readline(proc))
                parent     = getpid(proc)
                @test alive(parent)
                @test alive(grandchild)
                # `detach` really did give it its own group — the premise of the
                # whole fix. Without this the kill below would be a no-op (the
                # guard refuses to signal our own group) and the test would pass
                # for the wrong reason.
                @test Int(ccall(:getpgid, Cint, (Cint,), Cint(parent))) == parent
                @test Int(ccall(:getpgid, Cint, (Cint,), Cint(parent))) !=
                      Int(ccall(:getpgid, Cint, (Cint,), 0))

                BW.kill_process_group!(proc)
                @test timedwait(() -> !alive(parent) && !alive(grandchild), 5.0) === :ok
            finally
                try; kill(proc, Base.SIGKILL); catch; end
                try; close(proc); catch; end
            end
        end

        @testset "it never signals our own group" begin
            # The guard that keeps this from killing the worker itself. A proc in
            # OUR group must be left entirely alone.
            proc = open(Cmd(`sleep 30`), "r+")     # no detach ⇒ our group
            try
                @test Int(ccall(:getpgid, Cint, (Cint,), Cint(getpid(proc)))) ==
                      Int(ccall(:getpgid, Cint, (Cint,), 0))
                BW.kill_process_group!(proc)
                sleep(0.5)
                @test alive(getpid(proc))          # untouched, and so are we
            finally
                try; kill(proc, Base.SIGKILL); catch; end
                try; close(proc); catch; end
            end
        end

        @testset "no test sweeps the REAL worker id" begin
            # The guard for the bug above, because the failure is invisible from
            # inside the suite: `reap_stray_agents!()` returns a count and the
            # assertions pass — the damage is to a live session in another
            # process, and it surfaces minutes later as "the worker went
            # offline".
            #
            # Scanned rather than argued about: any future test that reaches for
            # the no-argument sweep gets caught here instead of on someone's
            # running chat. Production may call it (`start()` does, after the
            # pidfile claim proves no other incarnation is alive) — this is only
            # about the test suite.
            offenders = String[]
            for f in readdir(@__DIR__; join = true)
                endswith(f, ".jl") || continue
                for (i, line) in enumerate(eachline(f))
                    startswith(lstrip(line), "#") && continue
                    occursin(r"reap_stray_agents!\(\)", line) &&
                        push!(offenders, "$(basename(f)):$i: $(strip(line))")
                end
            end
            @test isempty(offenders)
            isempty(offenders) ||
                @info "use reap_agents_owned_by(<synthetic id>) instead" offenders
        end

        @testset "kill_process_group! tolerates an already-dead proc" begin
            proc = open(detach(Cmd(`true`)), "r+")
            sleep(0.3)
            @test BW.kill_process_group!(proc) === nothing   # no throw
            try; close(proc); catch; end
        end

        if isdir("/proc")
            @testset "the sweep reaps what carries a given mark, and only that" begin
                # A SYNTHETIC owner id, and `reap_agents_owned_by` rather than
                # `reap_stray_agents!`.
                #
                # `reap_stray_agents!()` is `reap_agents_owned_by(load_or_generate_worker_id())`
                # — the id of the worker installed on THIS machine, read from its
                # real scratch space. Calling it here does exactly what its own
                # docstring warns against ("only call this once the worker owning
                # `worker_id` is gone"): the operator's worker is running, and
                # every agent it has spawned carries that mark. So the test
                # SIGKILLed the live chat session, its MCP servers and their Julia
                # eval workers — every time the suite ran. It reads as "the worker
                # keeps going offline", which is a long way from "a test killed
                # it".
                #
                # Nothing is lost by using an explicit id: the sweep is the same
                # function either way, and what is worth asserting — that it
                # matches on the mark, that it is prefix-safe, that it leaves
                # another owner alone — is independent of where the id came from.
                # The same convention the pidfile testset already follows for the
                # same reason.
                mine   = "test-owner-" * BW.generate_worker_id()
                marked = open(detach(Cmd(`sleep 300`;
                    env = merge(Dict(ENV), Dict(BW.AGENT_OWNER_ENV => mine)))), "r+")
                # Another worker's agent, alive right now: same shape, different
                # owner. Reaping it would take down someone else's session. The
                # id is ours plus a suffix, which is the prefix case the NUL
                # terminator in the mark exists for.
                other  = open(detach(Cmd(`sleep 300`;
                    env = merge(Dict(ENV), Dict(BW.AGENT_OWNER_ENV => mine * "-not-me")))), "r+")
                # Pids captured UP FRONT: `getpid(::Process)` throws ESRCH once
                # the process is reaped, so reading it after the kill turns a
                # passing assertion into an error.
                mpid, opid = getpid(marked), getpid(other)
                try
                    sleep(0.5)
                    @test alive(mpid)
                    @test alive(opid)

                    n = BW.reap_agents_owned_by(mine)
                    # EXACTLY one: a synthetic id matches the one process we
                    # planted and nothing else on the machine. `>= 1` was the
                    # honest bound while this swept the real id — it had to
                    # tolerate whatever live agents it was about to kill.
                    @test n == 1
                    @test timedwait(() -> !alive(mpid), 5.0) === :ok
                    sleep(0.5)
                    @test alive(opid)              # NOT ours, NOT touched
                finally
                    for p in (marked, other)
                        try; BW.kill_process_group!(p); catch; end
                        try; kill(p, Base.SIGKILL); catch; end
                        try; close(p); catch; end
                    end
                end
            end
        end

        # A session SCAN spawns a real provider process too, and it was the one
        # spawn that skipped all of the above.
        @testset "the session scan spawns and reaps like a session" begin
            @testset "every provider spawn carries our mark" begin
                prov = probe_provider("true", String[]; env = Dict("PROVIDER_ONLY" => "1"))
                env  = BW.provider_env(prov)
                # The mark is what makes a stray findable at all.
                @test env[BW.AGENT_OWNER_ENV] == BW.load_or_generate_worker_id()
                @test env["PROVIDER_ONLY"] == "1"
                @test haskey(env, "PATH")            # live ENV is the base
                # ...and a caller's overrides win over both.
                @test BW.provider_env(prov, Dict("PROVIDER_ONLY" => "2"))["PROVIDER_ONLY"] == "2"
            end

            @testset "a scan leaves nothing behind, even ignoring SIGTERM" begin
                # The real leak: `julia -m MockACP` still precompiling does not
                # die on the SIGTERM that ends the scan. Spawned bare and reaped
                # with a bare SIGTERM, the survivor had neither our mark nor a
                # group of its own, so BOTH halves of the reaper were blind to it
                # — 7 orphans over one e2e run, ~500 MB each.
                pidfile = tempname()
                prov = probe_provider("bash", ["-c", """
                    trap '' TERM
                    sleep 300 &
                    echo "\$\$ \$(ps -o pgid= -p \$\$ | tr -d ' ') \$!" > $(pidfile)
                    wait
                """])
                # Never answers `initialize`, so the scan gives up on the timeout
                # and takes the teardown path — which is the path under test.
                @test BW.acp_list_sessions(prov; timeout = 1.0) == Dict{String,Any}[]

                @test isfile(pidfile)
                pid, pgid, child = parse.(Int, split(read(pidfile, String)))
                # `detach` took: its own group is what lets one signal reach the
                # child too.
                @test pgid == pid
                @test timedwait(() -> !alive(pid), 5.0) === :ok
                @test timedwait(() -> !alive(child), 5.0) === :ok
                rm(pidfile; force = true)
            end
        end
    end
end
