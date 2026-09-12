# An Edit card must show the DIFF, not the "The file … updated successfully …"
# success message. The real claude-agent-acp wire (verified on acp.jsonl):
#   tool_call        content=[]                (pending, streamed)
#   tool_call_update content=[diff]            (the diff)
#   tool_call_update status=completed, rawOutput="… updated successfully …"
# The ACP layer normalizes that terminal `rawOutput` (no content) into a lone
# TextContent; caching it verbatim used to REPLACE the diff → a wall of text with
# no diff. The chat now skips a completed edit snap whose content is text-only, so
# the diff stays.
#
# UI-only: real dev_server, a mock agent emitting those exact frames, DOM asserts.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const OLD = "function f(x)\n    return x\nend\n"
const NEW = "function f(x)\n    # doubled\n    return 2x\nend\n"
const SUCCESS = "The file src/thing.jl has been updated successfully. " *
                "(file state is current in your context — no need to Read it back)"

function edit_agent(prompt::AbstractString)
    occursin("edit", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    return [TK.text("editing:"),
            TK.tool(kind = "edit", title = "Edit src/thing.jl", tool_name = "Edit",
                    id = "ed1", content = Any[], complete = false,
                    raw_input = Dict("file_path" => "src/thing.jl",
                                     "old_string" => OLD, "new_string" => NEW)),
            TK.tool_update("ed1"; status = "in_progress",
                           content = [TK.diff_block("src/thing.jl", OLD, NEW)]),
            TK.tool_update("ed1"; status = "completed", raw_output = SUCCESS)]
end

const CARD = ".bt-tool-msg[data-msg-id*=\"ed1\"]"

function run_suite(server)
    server.agent_fn[] = edit_agent

    @testset "Edit card keeps the diff, not the success rawOutput" begin
        TK.new_chat(server; title = "EditDiff")
        TK.send_message(server, "make an edit")

        @test TK.wait_for(server, "edit card",
            "!!document.querySelector('$CARD')"; timeout = 120) == true
        # The DIFF renders (Monaco diff editor) — even after the completed snap.
        @test TK.wait_for(server, "diff renders",
            "(() => { const p = document.querySelector('$CARD'); return !!(p && p.querySelector('.monaco-diff-editor, .monaco-diff-editor-div')); })()";
            timeout = 30) == true
        # The success rawOutput text is NOT rendered as the body.
        @test TK.eval_js(server,
            "!((document.querySelector('$CARD').innerText)||'').includes('updated successfully')") == true

        @test isempty(TK.js_errors(server))
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = edit_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
