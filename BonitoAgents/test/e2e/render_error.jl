# A returned App that throws at RENDER time (an invalid Makie attribute, etc.)
# must not silently claim it displayed. At EVAL time `format_value` pre-renders
# the App to compact HTML (`RemoteProxy.summary_html`, a throwaway NoConnection
# render). Because that runs the App body inside the eval's captured stdout, the
# throw comes back as a `CapturedException`: the terminal-faithful red error is
# echoed into the card's Output stream (so the AGENT sees WHY), and the exception
# is parked as the embed (so the USER sees it rendered too). No probe, no second
# throwaway render.
#
# UI-only: real dev_server + real eval worker (evalenv), real bt_julia_eval, DOM
# assertions.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const RENDER_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))

# `notanattr_zqx` is not a valid Lines attribute → the plot creation (which runs
# inside the App body, i.e. at render) throws. Unique marker so the assert can't
# match anything else.
const BADAPP = """using WGLMakie
App() do
    fig = Figure()
    lines!(Axis(fig[1, 1]), 1:10; notanattr_zqx = 5)
    fig
end"""

function render_err_agent(prompt::AbstractString)
    occursin("plot", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    return Any[TK.text("plotting:"), TK.bt_eval(BADAPP; env_path = RENDER_ENV, id = "bad-app")]
end

const CARD = ".bt-tool-msg[data-msg-id*=\"bad-app\"]"

function run_suite(server)
    server.agent_fn[] = render_err_agent

    @testset "render-time app error reaches the result" begin
        TK.new_chat(server; title = "RenderErr")
        TK.send_message(server, "show a plot")

        @test TK.wait_for(server, "eval card",
            "!!document.querySelector('$CARD')"; timeout = 180) == true
        # The render error surfaces in the card — `summary_html` returned the
        # CapturedException, so the red error is echoed into the Output stream and
        # the exception is parked as the embed. Either way the marker is visible.
        @test TK.wait_for(server, "render error shown",
            "(() => { const e = document.querySelector('$CARD'); return !!(e && (e.innerText||'').includes('notanattr_zqx')); })()";
            timeout = 30) == true
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = render_err_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
