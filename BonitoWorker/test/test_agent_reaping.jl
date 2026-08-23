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

alive(pid) = ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(0)) == 0

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

        @testset "kill_process_group! tolerates an already-dead proc" begin
            proc = open(detach(Cmd(`true`)), "r+")
            sleep(0.3)
            @test BW.kill_process_group!(proc) === nothing   # no throw
            try; close(proc); catch; end
        end

        if isdir("/proc")
            @testset "startup reaps what carries OUR mark, and only that" begin
                mine   = BW.load_or_generate_worker_id()
                marked = open(detach(Cmd(`sleep 300`;
                    env = merge(Dict(ENV), Dict(BW.AGENT_OWNER_ENV => mine)))), "r+")
                # Another worker's agent, alive right now: same shape, different
                # owner. Reaping it would take down someone else's session.
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

                    n = BW.reap_stray_agents!()
                    @test n >= 1
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
    end
end
