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
#   • the chat is rooted at the checkout the WORKER provides, not at some working
#     dir (this suite's worker runs from the monorepo, so that is the server's
#     own checkout — no clone happens), and the worker picker offers that worker;
#   • the SAME button in a chat header goes to the same place, from wherever the
#     user noticed the problem;
#   • pressing it repeatedly reuses ONE chat — otherwise a debugging session's
#     history is scattered over N identical threads;
#   • the header's dev-mode toggle shows the flag it persisted, refuses to grant
#     it when the confirm is declined, and completes a session restart when it
#     is accepted (without that restart the flag is on disk and invisible to the
#     agent, so the button would have lied).
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
import BonitoAgents

# Where the debug chat must land: the checkout the worker provides. The suite's
# worker runs from the same monorepo as this server, so that is this server's
# own repo root.
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

# The visible pane. Several panes can be in the DOM at once (the fast-switch
# design keeps them), so visibility is what picks the live one; the header's
# menu items are queried THROUGH it (they are display:none while the menu is
# closed, so they cannot be picked by their own visibility).
const VISIBLE_PANE = """([...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null))"""
# The visible pane's dev-mode item in the ⋯ menu. Its CLASS is the state the
# click handler reads, and its LABEL is what the user reads — so the two answer
# different questions and both are used.
const DEVMODE_BTN = """($(VISIBLE_PANE)?.querySelector('.bt-header-devmode'))"""
const DEVMODE_LABEL = """($(DEVMODE_BTN)?.textContent || '')"""
const DEVMODE_ON = """(!!$(DEVMODE_BTN)?.classList.contains('bt-header-devmode-on'))"""
# Open the visible pane's ⋯ menu and click the item with `cls`: what a user does.
click_menu_item(server, cls) = TK.eval_js(server, """(() => {
    const p = $(VISIBLE_PANE);
    const t = p && p.querySelector('.bt-header-menu .bt-menu-trigger');
    const b = p && p.querySelector($(repr(cls)));
    if (!t || !b) return false;
    t.click(); b.click(); return true; })()""")
# `confirm()` is a NATIVE dialog in Electron: unstubbed it blocks the renderer
# and the suite hangs. Stubbing it is also how the gate itself gets tested —
# answering "no" must leave the flag alone.
answer_confirm(server, yes::Bool) =
    TK.eval_js(server, "window.confirm = () => $(yes); true")

function run_suite(server)
    server.agent_fn[] = _ -> [TK.text("ready"), TK.end_turn()]

    @testset "Debug BonitoAgents (UI-only)" begin
        # The expected landing path is the server's own checkout (see REPO_ROOT).
        @test REPO_ROOT !== nothing

        @testset "the dashboard button opens the debug chat" begin
            TK.to_dashboard(server)
            @test TK.wait_for(server, "the dashboard offers it",
                "!!document.querySelector('.bt-debug-btn')"; timeout = 30) == true
            # The worker picker lists the one connected worker: the chat runs
            # there, and that is where its checkout lives.
            @test TK.wait_for(server, "the picker offers the worker",
                "document.querySelectorAll('.bt-debug-worker option').length === 1";
                timeout = 30) == true
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
            # The FOLDER has to be called "Ordinary": the per-worker picker names
            # a project after its folder's basename and has no Name field, so
            # `new_chat`'s `title` no longer reaches the UI.
            TK.new_chat(server; cwd = joinpath(mktempdir(), "Ordinary"))
            @test TK.wait_for(server, "we're in the ordinary chat",
                "$(HEADER_TITLE) === 'Ordinary'"; timeout = 90) == true

            @test TK.eval_js(server, "!!$(VISIBLE_PANE)?.querySelector('.bt-header-debug')") === true
            @test click_menu_item(server, ".bt-header-debug") === true
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

        @testset "the dev-mode item reflects and flips the flag" begin
            # The debug chat got `dev_mode` from the button, so its item reads
            # ON (the class; the ": on" suffix is CSS-rendered, so it is not in
            # the text) — and the ⋯ trigger itself is red, so what the agent is
            # allowed to do is legible without opening the menu.
            @test TK.wait_for(server, "the debug chat reads ON", DEVMODE_ON; timeout = 60) == true
            @test TK.eval_js(server, DEVMODE_LABEL) == "Dev mode"
            @test TK.eval_js(server,
                "!!$(VISIBLE_PANE)?.querySelector('.bt-menu-trigger.bt-menu-trigger-danger')") === true

            # An ordinary chat starts OFF, and the same control is present there:
            # granting dev mode by hand is exactly what this item adds.
            TK.open_chat(server, "Ordinary")
            @test TK.wait_for(server, "the ordinary chat reads OFF",
                "$(DEVMODE_LABEL) === 'Dev mode' && !$(DEVMODE_ON)"; timeout = 60) == true
            @test TK.eval_js(server,
                "!!$(VISIBLE_PANE)?.querySelector('.bt-menu-trigger.bt-menu-trigger-danger')") === false

            # Declining the confirm must leave it OFF. This is the assertion the
            # whole gate exists for — the tools it hands out can drive every chat
            # on the server, so a stray click must not be enough.
            answer_confirm(server, false)
            @test click_menu_item(server, ".bt-header-devmode") === true
            sleep(2)   # nothing to wait FOR: the assertion is that nothing happened
            @test TK.eval_js(server, DEVMODE_ON) === false
            @test TK.eval_js(server, DEVMODE_LABEL) == "Dev mode"

            # Accepting flips it. The item reads ON once the flag is set; the
            # session restart that makes it real (`dev_mode` is read at bring-up)
            # shows in the header status while it runs and the trigger goes red.
            answer_confirm(server, true)
            @test click_menu_item(server, ".bt-header-devmode") === true
            @test TK.wait_for(server, "the ordinary chat is now ON", DEVMODE_ON; timeout = 120) == true
            @test TK.wait_for(server, "the restart behind the switch finished",
                "($(VISIBLE_PANE)?.querySelector('.bt-header-status')?.textContent || '') === ''";
                timeout = 120) == true

            # Turning it back OFF needs no confirm — giving the tools away is the
            # dangerous direction, taking them back isn't.
            answer_confirm(server, false)
            @test click_menu_item(server, ".bt-header-devmode") === true
            @test TK.wait_for(server, "the ordinary chat is OFF again",
                "!$(DEVMODE_ON)"; timeout = 120) == true

            TK.eval_js(server, "delete window.confirm; true")
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
