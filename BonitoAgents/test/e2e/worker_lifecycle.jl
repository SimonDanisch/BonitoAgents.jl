# End-to-end worker lifecycle, UI-only via TestKit. We simulate a real worker
# going away by killing its OS process (a worker has no "disconnect" button — a
# real worker machine just dies), then assert the dashboard reflects it. We read
# only the rendered DOM; the kill is a real-world action, not a fake state poke.
#
# DESTRUCTIVE: this suite kills the MAIN worker process (server.h.worker_proc).
# Under the shared runner it MUST run LAST — any chat-spawning suite after it
# would have no worker to bind a session. run_all.jl orders it last.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The "N /M workers online" header — capture N (the online count).
online_count(s) = TK.eval_js(s, "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m ? parseInt(m[1]) : -1; })()")
online_dots(s)  = TK.eval_js(s, "document.querySelectorAll('.bt-dot-online').length")

agent_script(_p) = [TK.text("hi")]

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.to_dashboard(server)

    @testset "BonitoAgents worker lifecycle (UI-only)" begin
        @testset "worker shows online on the dashboard" begin
            @test TK.wait_for(server, "1 online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) === 1; })()"; timeout = 15) == true
            @test online_dots(server) >= 1
        end

        @testset "killing the worker process shows it offline" begin
            wp = server.h.worker_proc
            @test wp !== nothing
            kill(wp)   # real disconnect: the worker machine goes away
            @test TK.wait_for(server, "0 online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) === 0; })()"; timeout = 15) == true
            @test TK.wait_for(server, "no online dots",
                "document.querySelectorAll('.bt-dot-online').length === 0"; timeout = 5) == true
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
