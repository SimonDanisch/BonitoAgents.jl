# Dashboard layout, UI-only via TestKit.
#
# Regression guard for the width drift where the stats strip ("N/N workers
# online · …") stretched full-width while every other section stayed in the
# centered 1080px column — `.bt-stats` is a `map(...)`, so Bonito wraps it in an
# inline `bonito-fragment` that escaped the `.bt-dash > *` max-width cap. Only
# reproduces at a WIDE viewport (> the 1080 cap), so we force 2000px CSS via
# `set_window_size` (deterministic — sets deviceScaleFactor:0).
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# offsetWidth of a dashboard section (0 if absent).
secw(sel) = "(document.querySelector('$(sel)')?.offsetWidth || 0)"

function run_suite(server)
    TK.to_dashboard(server)
    TK.ECT.set_window_size(server.browser[], 2000, 1200)   # wide, deterministic CSS px
    try
        @testset "BonitoAgents dashboard layout (UI-only)" begin
            @test TK.wait_for(server, "dashboard rendered",
                "!!document.querySelector('.bt-stats') && !!document.querySelector('.bt-header')"; timeout = 20) == true
            sleep(1)
            @test TK.eval_js(server, "window.innerWidth") == 2000   # the wide viewport actually took
            # The cap is in effect (sections capped well under the 1800px content box).
            @test TK.eval_js(server, "$(secw(".bt-header")) <= 1100") == true
            # Every section shares the SAME width — the stats strip no longer escapes
            # the centered column. (Exact-equal: border-box makes padding count IN.)
            header = TK.eval_js(server, secw(".bt-header"))
            for sel in (".bt-stats", ".bt-cards", ".bt-section")
                @test TK.eval_js(server, secw(sel)) == header
            end
        end
    finally
        # Restore a normal viewport so later suites in the shared runner aren't
        # left at 2000px (responsive assertions elsewhere depend on the size).
        TK.ECT.set_window_size(server.browser[], 1280, 820)
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server()
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
