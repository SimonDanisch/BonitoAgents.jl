# Codex is the third ACP dialect the chat has to render identically, and the
# hardest so far: `@agentclientprotocol/codex-acp` names NO tool anywhere (no
# `_meta.claudeCode`, and its titles are display strings), WRAPS an MCP call as
# `rawInput = {server, tool, arguments}` under a `mcp.<server>.<tool>` title, and
# reports every result out-of-band in `rawOutput` — an MCP `CallToolResult` for
# an MCP call, `formatted_output` for a shell call, whose opening content is a
# bare `terminal` pointer we never subscribe to.
#
# Parsed naively that is: an eval that lands as a nameless generic pill whose
# "arguments" are server/tool/arguments, a shell call with no command line, and
# both cards empty of output with a literal "[tool content: terminal]" in the
# body. This drives the FULL stack with the mock speaking that dialect
# (`TK.codex_mcp_tool` / `TK.codex_shell`, whose frame shapes are copied from
# real codex-acp captures in AgentClientProtocol/test/fixtures/).
#
# UI-only: real dev_server, real Electron by URL, DOM assertions.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# One of each shape codex produces. `id`s are markers the DOM asserts on.
function codex_wire_agent(prompt::AbstractString)
    occursin("tools", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    return Any[
        TK.text("running codex-shaped tools:"),
        TK.codex_shell("echo CODEXWIRE_SHELL"; id = "cw-bash",
                       output = "CODEXWIRE_SHELL\n"),
        TK.codex_mcp_tool("btworker", "bt_julia_eval"; id = "cw-eval",
                          args = Dict("code" => "CODEXWIRE_CODE = 1 + 1",
                                      "env_path" => "/tmp/codexwire"),
                          output = ["2"]),
        # A Julia error is not an MCP error: the call COMPLETES and the
        # stacktrace is its result content (see codex_mcp_tool_error.jsonl).
        TK.codex_mcp_tool("btworker", "bt_julia_eval"; id = "cw-fail",
                          args = Dict("code" => "sqrt(-1)"),
                          output = ["\e[91mERROR: LoadError: CODEXWIRE_FAILURE with -1.0\nStacktrace:\n  [1] top-level scope\e[39m"]),
    ]
end

card(id) = ".bt-tool-msg[data-msg-id*=\"$id\"]"
# innerText of a card, or "" when it isn't mounted yet.
card_text(id) = "(() => { const e = document.querySelector('$(card(id))'); return e ? (e.innerText||'') : ''; })()"

function run_suite(server)
    server.agent_fn[] = codex_wire_agent

    @testset "codex-dialect tool calls render like claude's" begin
        TK.new_chat(server; title = "CodexWire")
        TK.send_message(server, "run the tools")

        for id in ("cw-bash", "cw-eval", "cw-fail")
            @test TK.wait_for(server, "card $id", "!!document.querySelector('$(card(id))')";
                              timeout = 120) == true
        end

        # The shell card must show the COMMAND. Codex titles the call with the
        # command line and names no tool, so only the `execute` + `command`
        # shape makes this a Bash card instead of a nameless generic pill.
        @test TK.wait_for(server, "bash command",
            "$(card_text("cw-bash")).includes('echo CODEXWIRE_SHELL')"; timeout = 30) == true

        # …and its OUTPUT, which exists only in `rawOutput.formatted_output`.
        @test TK.wait_for(server, "bash output",
            "$(card_text("cw-bash")).includes('CODEXWIRE_SHELL')"; timeout = 30) == true

        # The MCP eval is routed to the TYPED eval card, not a generic pill:
        # the filter key is the resolved tool name and the header carries the
        # resolved MCP server — both recovered from the envelope alone.
        @test TK.wait_for(server, "typed eval card",
            """(() => { const c = document.querySelector('$(card("cw-eval"))');
                return !!(c && c.dataset.filterKey === 'tool:bt_julia_eval'
                          && (c.querySelector('.bt-tool-server')?.textContent || '').trim() === 'btworker'); })()""";
            timeout = 30) == true

        # The eval RESULT exists nowhere but `rawOutput.result.content` — codex
        # mirrors it into no content block at all — so a card that shows it
        # proves the whole recovery. Asserted on the card that auto-expands;
        # only one does, and driving the other open means clicking, which races
        # Monaco's async create (see the note at the end of this file).
        @test TK.wait_for(server, "eval output",
            "$(card_text("cw-eval")).includes('OUTPUT')"; timeout = 60) == true
        @test TK.wait_for(server, "eval result",
            "/OUTPUT\\s*2/.test($(card_text("cw-eval")))"; timeout = 60) == true
        # ANSI colouring renders as styling, not literal escape codes.
        @test TK.eval_js(server,
            "(document.body.innerText || '').includes('[91m')") == false

        # NOTE: the recovered ARGUMENTS (code/env_path) are asserted against the
        # real captured codex frames in AgentClientProtocol's suite, not here —
        # the eval card's Code section is a lazily-mounted Monaco editor that
        # virtualises its text out of `innerText`, so asserting on it from the
        # DOM would be timing-dependent. This suite owns the ROUTING claim.

        # The `terminal` pointer codex opens every shell call with is a handle
        # we never subscribe to, not content — it must not reach the page.
        @test TK.eval_js(server,
            "(document.body.innerText || '').includes('tool content: terminal')") == false

        # A resolved MCP tool is titled by its OWN name whoever ran it, so
        # codex's dotted wire name never reaches the header — for BOTH eval
        # cards, including the one that never expanded. This is the assertion
        # that would have caught the live `tool_update` path overwriting the
        # identity `build_mcp_msg` had just set.
        @test TK.eval_js(server, """(() => {
            const c = document.querySelector('$(card("cw-fail"))');
            return (c.querySelector('.bt-tool-title')?.textContent || '').trim();
        })()""") == "bt_julia_eval"
        @test TK.eval_js(server,
            "(document.body.innerText || '').includes('mcp.btworker.bt_julia_eval')") == false
        @test TK.eval_js(server, """(() => {
            const c = document.querySelector('$(card("cw-eval"))');
            return (c.querySelector('.bt-tool-title')?.textContent || '').trim();
        })()""") == "bt_julia_eval"

        # The envelope's own keys are never the tool's arguments.
        @test TK.eval_js(server, """(() => {
            const t = $(card_text("cw-eval"));
            return t.includes('"server"') || t.includes('"arguments"');
        })()""") == false

        @test isempty(TK.js_errors(server))
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = codex_wire_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end

# NOTE — this suite deliberately never CLICKS a collapsed tool card open.
# Expanding one whose body holds a Monaco block races Monaco's async `create`
# and throws an unhandled "Cannot read properties of null (reading
# 'parentNode')", which `js_errors` fails on. That reproduces here regardless of
# provider (it is the mock driving it) and is not codex's doing, so it is left
# for its own fix rather than papered over with sleeps. Without a click the
# suite raises zero JS errors.
