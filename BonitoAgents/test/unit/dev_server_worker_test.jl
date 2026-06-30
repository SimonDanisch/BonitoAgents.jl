@testitem "unit:dev_server_worker" tags = [:unit] begin

# dev_server runs the worker the way a real install does — and cleans it up.
#
# Regression guard for the "worker in a separate process via the real install
# path" rework. The invariants:
#   1. The worker is a SEPARATE OS process (not an in-process task) launched by
#      `spawn_worker` → detached `BonitoWorker.start()`.
#   2. It comes up through the REAL install path: a `config.json` in a throwaway
#      `BONITOAGENTS_CONFIG_DIR`, which `start()` reads to dial the server — proven
#      by the worker actually registering on the control WS.
#   3. `close()` tears everything down: the worker process dies (SIGTERM, then
#      SIGKILL escalation since a connected worker is parked in a socket read and
#      ignores SIGTERM), every throwaway tempdir is removed (the persist of
#      `discovered.json` on worker-drop must NOT resurrect `state_dir`), and the
#      env we set is cleared. A second `close()` is a no-op.
#
# Pure Julia + a spawned worker subprocess — no Electron, no claude-agent-acp
# (registration doesn't need an agent), so it runs in the default suite.

using Test
import BonitoAgents, BonitoWorker
const BT = BonitoAgents

@testset "dev_server worker subprocess lifecycle" begin
    # Snapshot the env keys dev_server/close touch so the test leaves them as it
    # found them regardless of the host's pre-existing values.
    touched = ("BONITOAGENTS_CONFIG_DIR", "CLAUDE_AGENT_ACP")
    saved = Dict(k => (haskey(ENV, k) ? ENV[k] : nothing) for k in touched)

    h = BT.dev_server(; port = 0)
    local wpid, dirs
    try
        @test h.worker_proc isa Base.Process
        wpid = getpid(h.worker_proc)
        # (1) separate process
        @test wpid != getpid()
        # (2) real install path: config.json written into the throwaway config dir
        @test isfile(joinpath(h.worker_config, "config.json"))

        # (2 cont.) the worker boots, reads that config, and registers on the
        # control WS. Poll up to ~30s (subprocess `using BonitoWorker` + dial).
        registered = false
        for _ in 1:60
            if !isempty(h.state.workers[])
                registered = true
                break
            end
            sleep(0.5)
        end
        @test registered
        @test BonitoWorker.process_running(wpid) === true

        dirs = (h.state_dir, h.working_dir, h.worker_root, h.worker_config)
    finally
        # Always attempt cleanup even if an assertion above threw, so a failing
        # run doesn't leak a worker process / tempdirs.
        close(h)
    end

    # (3) close() killed the worker and removed every tempdir.
    @test process_exited(h.worker_proc)
    @test BonitoWorker.process_running(wpid) === false
    for d in dirs
        @test !isdir(d)
    end
    # (3 cont.) env restored to "unset" (close deletes the keys it set).
    @test !haskey(ENV, "BONITOAGENTS_CONFIG_DIR")

    # Idempotent: a second close is a silent no-op (no throw, no double-kill).
    @test (close(h); true)

    # Restore any pre-existing env values the test/close clobbered.
    for (k, v) in saved
        if v === nothing
            haskey(ENV, k) && delete!(ENV, k)
        else
            ENV[k] = v
        end
    end
end

end
