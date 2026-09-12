# When a display value (App / plot) is returned in a project env whose Bonito is
# too old for the live-render bridge, BonitoMCP emits a `{"bonito_upgrade": …}`
# marker instead of degrading to a bare "App". The chat must render the one-click
# [Update env] card (not the raw json), and clicking it must submit the Pkg.add as
# a real user message (which the agent then runs in this env).
#
# UI-only: real dev_server, a mock agent that emits the real eval frames carrying
# the marker (exactly what a mismatched worker returns), DOM assertions only.

using Test, JSON
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const UPGRADE_MARKER = JSON.json(Dict("bonito_upgrade" => Dict(
    "current" => "4.5.0", "need" => "5.0.0", "env" => "/tmp/proj",
    "add" => "Pkg.add(url=\"https://github.com/SimonDanisch/Bonito.jl\", rev=\"sd/media-proxy\")")))

const APPCODE = "using WGLMakie\nApp() do\n    lines(1:10)\nend"

# Emit the real eval frames (as invoke_mcp would), but with the version-mismatch
# marker as the RESULT content.
function upgrade_agent(prompt::AbstractString)
    occursin("plot", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    open_ev = Dict{String,Any}(
        "type" => "bt_eval_open", "tool_id" => "upgrade-eval",
        "tool" => "mcp__btworker__bt_julia_eval", "code" => APPCODE, "env_path" => nothing)
    result_ev = Dict{String,Any}(
        "type" => "bt_eval_result", "tool_id" => "upgrade-eval",
        "tool" => "mcp__btworker__bt_julia_eval", "code" => APPCODE, "env_path" => nothing,
        "content" => Any[Dict("type" => "text", "text" => UPGRADE_MARKER)],
        "is_error" => false, "opened" => true)
    return Any[TK.text("rendering:"), open_ev, result_ev]
end

const CARD = ".bt-tool-msg[data-msg-id*=\"upgrade-eval\"]"

function run_suite(server)
    server.agent_fn[] = upgrade_agent

    @testset "bonito version-mismatch upgrade card" begin
        TK.new_chat(server; title = "UpgradeCard")
        TK.send_message(server, "show a plot")

        @test TK.wait_for(server, "eval card",
            "!!document.querySelector('$CARD')"; timeout = 180) == true
        # The upgrade card renders (auto-expanded) and names the problem.
        @test TK.wait_for(server, "upgrade card",
            "(() => { const b = document.querySelector('$CARD .bt-worker-stale'); return !!(b && (b.innerText||'').includes('newer Bonito')); })()";
            timeout = 20) == true
        @test TK.eval_js(server, "!!document.querySelector('$CARD .bt-worker-upgrade-btn')") == true
        # The raw marker json is NOT shown as output text.
        @test TK.eval_js(server,
            "!(document.querySelector('$CARD').innerText||'').includes('bonito_upgrade')") == true

        # Click [Update env] → the fix is submitted as a user message (carries the
        # Pkg.add pinning the git branch).
        TK.eval_js(server, "document.querySelector('$CARD .bt-worker-upgrade-btn').click(); true")
        @test TK.wait_for(server, "fix prompt submitted",
            "document.body.innerText.includes('sd/media-proxy')"; timeout = 20) == true

        @test isempty(TK.js_errors(server))
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = upgrade_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
