# End-to-end todo taskbar, UI-only via TestKit. No internal-API calls.
#
# Behaviour these tests assert (the user-facing contract of taskbar.jl):
#   * A LIVE todo list is a pinned panel (`.bt-taskbar-todo`), not a chat
#     bubble: every item shows, finished ones crossed out (`.bt-todo-done`),
#     the in-progress one highlighted (`.bt-todo-active`).
#   * A plan update mutates that one panel in place (2 items -> 3 items).
#   * When the turn ends the list finalizes into ONE history bubble
#     (`.bt-plan-msg`) and the pin drops.
#
# The mock drives this through `plan` SessionUpdates (the channel real
# claude-agent-acp uses — the TodoWrite tool_call path is inert), held open
# with `delay` events so the live panel is observable before the turn ends.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const PLAN_V1 = [(content = "step one", status = "in_progress"),
                 (content = "step two", status = "pending")]
const PLAN_V2 = [(content = "step one",   status = "completed"),
                 (content = "step two",   status = "in_progress"),
                 (content = "step three", status = "pending")]

# Emit the first plan, hold the turn open, grow it to three items, hold again
# (long enough for the collapse testset: two toggle round-trips plus a full
# 1 Hz re-render tick the collapsed state must survive), then a closing word
# so the turn ends (zombie-finalizing the still-open list).
agent_script(_prompt) = [TK.todo(PLAN_V1), TK.delay(3500),
                         TK.todo(PLAN_V2), TK.delay(8000),
                         TK.text("All wrapped up.")]

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents todo taskbar (UI-only)" begin
        TK.new_chat(server; title = "Plan")
        TK.send_message(server, "make a plan")

        @testset "live todo is a pinned panel, not a chat bubble" begin
            # FIRST render after the first send — on the cold standalone path (fresh
            # dev_server + electron + mock-agent spawn + first ACP turn), this is
            # slow in CI. Give it a cold-start budget like the other suites' first
            # wait (workflows 10s, chat_features 30s, …); the waits below run warm,
            # so they stay tight.
            @test TK.wait_for(server, "taskbar todo panel",
                "document.querySelector('.bt-taskbar-todo') !== null"; timeout = 20) == true
            @test TK.wait_for(server, "panel lists both items",
                "document.querySelectorAll('.bt-taskbar-todo-item').length >= 2"; timeout = 6) == true
            # While live there is no finalized plan bubble in the chat.
            @test TK.eval_js(server, "document.querySelectorAll('.bt-plan-msg').length") == 0
        end

        @testset "a plan update mutates the panel in place" begin
            @test TK.wait_for(server, "grows to three items",
                "document.querySelectorAll('.bt-taskbar-todo-item').length === 3"; timeout = 6) == true
            @test TK.eval_js(server,
                "(() => { const d = document.querySelector('.bt-taskbar-todo-item.bt-todo-done'); return d && d.textContent; })()") == "step one"
            @test TK.eval_js(server,
                "(() => { const a = document.querySelector('.bt-taskbar-todo-item.bt-todo-active'); return a && a.textContent; })()") == "step two"
        end

        @testset "todo card is collapsible, capped, and survives re-renders" begin
            # Done/total counter in the head (1 of 3 after PLAN_V2).
            @test TK.eval_js(server,
                "(() => { const c = document.querySelector('.bt-taskbar-todo-count'); return c && c.textContent; })()") == "1/3"
            # Rows are height-capped with internal scroll — a huge plan must
            # never bury the chat under the floating card.
            @test TK.eval_js(server,
                "getComputedStyle(document.querySelector('.bt-taskbar-todo-rows')).overflowY") == "auto"
            # Collapse via the chevron: rows hidden. The state lives on the
            # persistent .bt-taskbar (class), so it must SURVIVE the 1 Hz
            # KeyedList re-render that replaces the slot node.
            TK.click(server, ".bt-taskbar-todo-toggle")
            @test TK.wait_for(server, "rows hidden after collapse",
                "(() => { const r = document.querySelector('.bt-taskbar-todo-rows'); return r && r.offsetParent === null; })()"; timeout = 4) == true
            sleep(1.5)   # at least one re-render tick swaps the slot node
            @test TK.eval_js(server,
                "(() => { const r = document.querySelector('.bt-taskbar-todo-rows'); return r && r.offsetParent === null; })()") == true
            # Expand again for the finalize testset, and clear the persisted
            # choice so later suites on a shared server see the default.
            TK.click(server, ".bt-taskbar-todo-toggle")
            @test TK.wait_for(server, "rows visible after expand",
                "(() => { const r = document.querySelector('.bt-taskbar-todo-rows'); return r && r.offsetParent !== null; })()"; timeout = 4) == true
            TK.eval_js(server, "localStorage.removeItem('bt-todo-collapsed'); true")
            # The viewport meta carries the Android keyboard fix
            # (interactive-widget=resizes-content, set at module import in
            # bonitoagents.js) — asserted here since both live in that asset.
            @test TK.eval_js(server,
                "document.querySelector('meta[name=viewport]').content.includes('interactive-widget=resizes-content')") == true
        end

        @testset "turn end finalizes the list into one bubble and drops the pin" begin
            @test TK.wait_for(server, "finalized plan bubble",
                "document.querySelector('.bt-plan-msg') !== null"; timeout = 10) == true
            @test TK.wait_for(server, "pin dropped",
                "document.querySelector('.bt-taskbar-todo') === null"; timeout = 6) == true
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
