# End-to-end cross-worker registration, UI-only via TestKit. A second worker
# process registers against the same dev server (as a second machine running
# the installer would), the dashboard shows both online, and killing one drops
# the online count. We read only the rendered DOM; spawning/killing worker
# processes are real-world actions, not fake state pokes.
#
# Shared-runner safe: this suite spawns + kills a SECOND worker only; the main
# worker is untouched, so it can run mid-run. See run_all.jl.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Predicate: the "N /M workers online" header has exactly `n` online.
online_is(n) = "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) === $(n); })()"

agent_script(_p) = [TK.text("hi")]

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.to_dashboard(server)

    @testset "BonitoAgents cross-worker (UI-only)" begin
        @testset "one worker online initially" begin
            @test TK.wait_for(server, "1 online", online_is(1); timeout = 15) == true
        end

        local w2
        @testset "a second worker registers and shows online" begin
            w2 = TK.add_worker!(server; name = "worker-2")
            # The always-visible header count is the definitive signal that a
            # distinct second worker registered (its card lives under the
            # collapsible "Add another worker" section, so its name isn't in the
            # visible innerText — the count is what we assert on).
            @test TK.wait_for(server, "2 online", online_is(2); timeout = 20) == true
        end

        @testset "killing the second worker drops the online count" begin
            # SIGKILL, not the default SIGTERM: a machine "going offline" is abrupt
            # (power loss / network drop), and that's also what makes detection
            # deterministic. SIGTERM asks Julia to shut down gracefully, which has
            # to be serviced at a safepoint + run atexit — under the nworkers=4
            # parallel load the worker could take >15 s to actually exit (its
            # control WS stayed open until teardown, so the server still counted it
            # online and "back to 1 online" timed out). SIGKILL drops it at the
            # kernel level, so its sockets close at once and the server sees it go.
            kill(w2, Base.SIGKILL)   # the second machine goes offline, hard
            @test TK.wait_for(server, "back to 1 online", online_is(1); timeout = 15) == true
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
