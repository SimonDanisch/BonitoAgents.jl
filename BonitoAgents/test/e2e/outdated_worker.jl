# An OUTDATED (pre-v3) BonitoMCP worker echoes the evaluated code back in a
# ```julia fence and labels the value with "result:" — the current worker does
# neither (code is the typed field, output is one clean terminal block + a
# descriptor). The chat must CATCH that deprecated shape and show a clear
# "update your worker" banner above the (still-shown) raw output, instead of a
# silently-mangled card.
#
# UI-only: real dev_server, a mock agent that emits a `bt_julia_eval` tool whose
# RESULT content is the pre-v3 shape (exactly what an old worker returns over the
# ACP wire), rendered-DOM assertions only. No worker is hand-spawned.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The pre-v3 wire shape: ONE result text block = a ```julia code echo + a
# "result:" label + the value, and NO v3 descriptor.
const STALE_OUTPUT = "```julia\n1 + 1\n```result:\n2"

# Emit the SAME ACP frames `invoke_mcp` produces for a real eval — a
# `bt_eval_open` then a `bt_eval_result` under `mcp__btworker__bt_julia_eval`, so
# the chat classifies it as a bt_julia_eval (JuliaEvalToolMsg) and renders it
# through the real typed eval path — but with the deprecated RESULT content an
# outdated worker would return. No real handler runs; nothing is hand-spawned.
function stale_agent(prompt::AbstractString)
    occursin("eval", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    open_ev = Dict{String,Any}(
        "type" => "bt_eval_open", "tool_id" => "stale-eval",
        "tool" => "mcp__btworker__bt_julia_eval", "code" => "1 + 1", "env_path" => nothing)
    result_ev = Dict{String,Any}(
        "type" => "bt_eval_result", "tool_id" => "stale-eval",
        "tool" => "mcp__btworker__bt_julia_eval", "code" => "1 + 1", "env_path" => nothing,
        "content" => Any[Dict("type" => "text", "text" => STALE_OUTPUT)],
        "is_error" => false, "opened" => true)
    return Any[TK.text("running it:"), open_ev, result_ev]
end

const CARD = ".bt-tool-msg[data-msg-id*=\"stale-eval\"]"

function run_suite(server)
    server.agent_fn[] = stale_agent

    @testset "outdated worker eval shows an upgrade banner" begin
        TK.new_chat(server; title = "StaleWorker")
        TK.send_message(server, "please eval")

        # The eval card renders (typed path — tool_name is bt_julia_eval).
        @test TK.wait_for(server, "stale eval card",
            "!!document.querySelector('$CARD')"; timeout = 180) == true
        # The amber upgrade banner appears, detected purely from the deprecated
        # ```julia echo shape, and names the problem.
        @test TK.wait_for(server, "upgrade banner",
            "(() => { const b = document.querySelector('$CARD .bt-worker-stale'); return !!(b && (b.innerText||'').includes('outdated BonitoMCP')); })()";
            timeout = 20) == true
        # Nothing is hidden — the raw (mangled) output is still shown below it.
        @test TK.eval_js(server, "!!document.querySelector('$CARD .bt-console')") == true
        @test isempty(TK.js_errors(server))
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = stale_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
