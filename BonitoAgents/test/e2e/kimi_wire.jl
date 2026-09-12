# The chat rendered tool cards correctly only for claude-agent-acp, because the
# tool's identity was read from claude's `_meta.claudeCode.toolName` extension.
# Every other ACP agent leaves that out, so `bt_julia_eval` lost its eval card,
# a shell call lost its command line and a delegation lost its Task card — the
# same tool looking completely different depending on the backend.
#
# This drives the FULL stack with the mock speaking KIMI's dialect instead
# (`TK.kimi_tool`, whose frame shape is copied from real `kimi acp` captures in
# AgentClientProtocol/test/fixtures/): no `_meta`, the name only in the opening
# title, that title later replaced by a human sentence, and the arguments
# streamed as partial-JSON content ahead of one late `rawInput`.
#
# UI-only: real dev_server, real Electron by URL, DOM assertions.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# One of each shape that was broken. `id`s are markers the DOM asserts on.
function kimi_wire_agent(prompt::AbstractString)
    occursin("tools", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    return Any[
        TK.text("running kimi-shaped tools:"),
        TK.kimi_tool("Bash"; id = "kw-bash", kind = "execute",
                     args = Dict("command" => "echo KIMIWIRE_SHELL"),
                     human_title = "Running: echo KIMIWIRE_SHELL",
                     content = [TK.text_block("KIMIWIRE_SHELL")]),
        TK.kimi_tool("Grep"; id = "kw-grep", kind = "read",      # kimi says "read", not "search"
                     args = Dict("pattern" => "KIMIWIRE_PATTERN"),
                     human_title = "Searching for KIMIWIRE_PATTERN",
                     content = [TK.text_block("notes.txt:1: KIMIWIRE_PATTERN here")]),
        TK.kimi_tool("Agent"; id = "kw-agent", kind = "other",
                     args = Dict("description" => "KIMIWIRE_SUBTASK",
                                 "prompt" => "count the lines",
                                 "subagent_type" => "explore"),
                     human_title = "Launching explore agent: KIMIWIRE_SUBTASK",
                     content = [TK.text_block("agent_id: agent-0\nstatus: completed")]),
        TK.kimi_tool("mcp__btworker__bt_julia_eval"; id = "kw-eval", kind = "other",
                     args = Dict("code" => "KIMIWIRE_CODE = 1 + 1"),
                     human_title = "Evaluating julia",
                     content = [TK.text_block("2")]),
    ]
end

card(id) = ".bt-tool-msg[data-msg-id*=\"$id\"]"
# innerText of a card, or "" when it isn't mounted yet.
card_text(id) = "(() => { const e = document.querySelector('$(card(id))'); return e ? (e.innerText||'') : ''; })()"

function run_suite(server)
    server.agent_fn[] = kimi_wire_agent

    @testset "kimi-dialect tool calls render like claude's" begin
        TK.new_chat(server; title = "KimiWire")
        TK.send_message(server, "run the tools")

        for id in ("kw-bash", "kw-grep", "kw-agent", "kw-eval")
            @test TK.wait_for(server, "card $id", "!!document.querySelector('$(card(id))')";
                              timeout = 120) == true
        end

        # The shell card must show the COMMAND. Without the name recovery this
        # is a nameless generic pill and the command never appears.
        @test TK.wait_for(server, "bash command",
            "$(card_text("kw-bash")).includes('echo KIMIWIRE_SHELL')"; timeout = 30) == true

        # Grep arrives tagged kind="read"; only the NAME makes it a search card,
        # and the pattern is the sole thing kimi sends about the query.
        @test TK.wait_for(server, "grep pattern",
            "$(card_text("kw-grep")).includes('KIMIWIRE_PATTERN')"; timeout = 30) == true

        # Delegation renders as a Task card carrying its description.
        @test TK.wait_for(server, "agent description",
            "$(card_text("kw-agent")).includes('KIMIWIRE_SUBTASK')"; timeout = 30) == true

        # And the MCP eval is routed to the TYPED eval card, not a generic pill:
        # the filter key is the resolved tool name and the header carries the
        # resolved MCP server.
        @test TK.wait_for(server, "typed eval card",
            """(() => { const c = document.querySelector('$(card("kw-eval"))');
                return !!(c && c.dataset.filterKey === 'tool:bt_julia_eval'
                          && (c.querySelector('.bt-tool-server')?.textContent || '').trim() === 'btworker'); })()""";
            timeout = 30) == true

        # NOTE: the recovered ARGUMENTS (code/env_path) are asserted in
        # `unit:agent_tool_naming` against the real captured kimi frames, not
        # here. The eval card's Code section is a lazily-mounted Monaco editor
        # that virtualises its text out of `innerText`, so asserting on it from
        # the DOM would be timing-dependent — a flake, for a fact the unit test
        # already pins deterministically. This suite owns the ROUTING claim:
        # the frames reach the typed card at all.

        # None of the half-typed argument JSON may be visible anywhere: those
        # prefixes stream through `content` and must never read as tool output.
        @test TK.eval_js(server, """(() => {
            const t = document.body.innerText || '';
            return t.includes('{"command":"echo K') || t.includes('{"pattern":"KIMI');
        })()""") == false

        @test isempty(TK.js_errors(server))
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = kimi_wire_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
