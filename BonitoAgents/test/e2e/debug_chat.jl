# "Debug BonitoAgents", end to end through the browser.
#
# The dev API itself is covered headlessly (`unit:dev_api` for the ops,
# `unit:mcp_ctrl` for the MCP → server wire). What is only testable HERE is the
# thing the user actually does: press a button and land in a chat that is
# pointed at the server's own source.
#
# What each case guards:
#   • the dashboard button opens the debug chat and NAVIGATES there — a button
#     that quietly created a project and left you on the dashboard is the most
#     likely way for this to be broken;
#   • the chat is rooted at the repo checkout, not at some working dir;
#   • the SAME button in a chat header goes to the same place, from wherever the
#     user noticed the problem;
#   • pressing it repeatedly reuses ONE chat — otherwise a debugging session's
#     history is scattered over N identical threads.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
import BonitoAgents

# Where the debug chat must land: the git checkout this server's code lives in.
const REPO_ROOT = BonitoAgents.bonitoagents_repo_root()

# The VISIBLE chat pane's header fields. Several panes can be in the DOM at once
# (the fast-switch design keeps them), so visibility is what picks the live one.
const HEADER_TITLE = """([...document.querySelectorAll('.bt-header-title-edit')]
    .filter(e => e.offsetParent)[0]?.value || '')"""
const HEADER_ENV = """([...document.querySelectorAll('.bt-header-env')]
    .filter(e => e.offsetParent)[0]?.textContent || '')"""
# Sidebar entries whose label is the debug chat — one, no matter how often the
# button is pressed.
const DEBUG_ENTRIES = """[...document.querySelectorAll('.bt-side-item')]
    .filter(e => (e.textContent || '').includes('Debug BonitoAgents')).length"""

function run_suite(server)
    server.agent_fn[] = _ -> [TK.text("ready"), TK.end_turn()]

    @testset "Debug BonitoAgents (UI-only)" begin
        # This install has to be a checkout for the feature to exist at all; if
        # it isn't, the button is deliberately absent and there's nothing to test.
        @test REPO_ROOT !== nothing

        @testset "the dashboard button opens the debug chat" begin
            TK.to_dashboard(server)
            @test TK.wait_for(server, "the dashboard offers it",
                "!!document.querySelector('.bt-debug-btn')"; timeout = 30) == true
            TK.eval_js(server, "document.querySelector('.bt-debug-btn').click(); true")

            # Landing in the chat is the whole point of the button.
            @test TK.wait_for(server, "we land in the debug chat",
                "$(HEADER_TITLE) === 'Debug BonitoAgents'"; timeout = 90) == true
            # …and it is rooted at the server's own source, not a working dir.
            @test TK.wait_for(server, "the chat is rooted at the checkout",
                "$(HEADER_ENV) === $(TK.json(replace(REPO_ROOT, homedir() => "~")))";
                timeout = 30) == true
            @test TK.eval_js(server, DEBUG_ENTRIES) == 1
        end

        @testset "the chat-header button goes to the same place" begin
            # Open an ordinary chat, then press Debug from inside it — the point
            # of having the button there is reaching this from wherever you were.
            TK.new_chat(server; title = "Ordinary")
            @test TK.wait_for(server, "we're in the ordinary chat",
                "$(HEADER_TITLE) === 'Ordinary'"; timeout = 90) == true

            @test TK.eval_js(server, "!!document.querySelector('.bt-header-debug')") === true
            TK.eval_js(server, """(() => {
                [...document.querySelectorAll('.bt-header-debug')]
                    .filter(e => e.offsetParent)[0].click();
                return true; })()""")
            @test TK.wait_for(server, "back in the debug chat",
                "$(HEADER_TITLE) === 'Debug BonitoAgents'"; timeout = 90) == true
        end

        @testset "pressing it again reuses the SAME chat" begin
            # Otherwise a debugging session's history scatters across identical
            # threads and the whole point of a persistent chat is lost.
            TK.to_dashboard(server)
            TK.eval_js(server, "document.querySelector('.bt-debug-btn').click(); true")
            @test TK.wait_for(server, "still the debug chat",
                "$(HEADER_TITLE) === 'Debug BonitoAgents'"; timeout = 90) == true
            @test TK.eval_js(server, DEBUG_ENTRIES) == 1
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = _ -> [TK.text("ready"), TK.end_turn()])
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
