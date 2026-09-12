# The bug this suite exists for: a todo pill whose worker went away kept sitting
# in the taskbar, counting. Observed live at `Todos 0/1`, `1/3`, `0/4` after 21 to
# 35 HOURS. Nothing on the wire reports it — the socket simply dies mid-plan, the
# entries stay at whatever they reached, and a list judged on its entries alone is
# "still in progress" forever.
#
# Every layer under this is covered (ACP seals the plan when a real severed
# WebSocket ends the stream; the renderer finalizes on the sealed `Plan`), and all
# of that was green while the pill was broken end-to-end. So this asserts the only
# thing the user actually sees: the pin leaves the DOM, and the list lands in the
# chat as history with the statuses it had.
#
# Own dev_server: this SIGKILLs the chat's OWN worker, which would wreck the
# shared soak server for every item after it (cross_worker gets its own for the
# same reason, though it only kills a second worker).
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const PLAN = [(content = "write the thing", status = "in_progress"),
              (content = "check it",        status = "pending")]

# A plan the agent NEVER finishes: post it, then hold the turn open. The delay
# outlives the test, so nothing but the kill can end this episode — no `end_turn`,
# no all-entries-completed, no frame of any kind.
agent_script(_prompt) = [
    # A backgrounded subagent alongside the plan: its tool_call reports
    # "completed" at LAUNCH (the ack) and it carries no `outputFile`, so the bar
    # has no deterministic done-signal for it — the shape from subagent_feed.
    TK.tool(kind = "other", title = "Background investigation",
            tool_name = "Task", id = "task-BG", complete = false,
            open_status = "completed",
            raw_input = Dict{String,Any}("run_in_background" => true,
                                         "description" => "bg work")),
    TK.todo(PLAN), TK.delay(600_000)]

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "a dead worker takes its live todo pill with it" begin
        TK.new_chat(server; title = "Wedged")     # no space: TK.new_chat hangs on spaced titles
        TK.send_message(server, "make a plan")

        @testset "the pill is live while the worker is" begin
            @test TK.wait_for(server, "taskbar todo panel",
                "document.querySelector('.bt-taskbar-todo') !== null"; timeout = 20) == true
            @test TK.wait_for(server, "panel lists both items",
                "document.querySelectorAll('.bt-taskbar-todo-item').length >= 2"; timeout = 6) == true
            # Nothing is finalized yet — this is what "live" means here, and it is
            # what makes the assertions after the kill meaningful.
            @test TK.eval_js(server, "document.querySelectorAll('.bt-plan-msg').length") == 0
        end

        @testset "killing the worker retires it" begin
            # SIGKILL, not SIGTERM: a machine going offline is abrupt and gets no
            # chance to say anything. That is the whole difficulty — there is no
            # frame to react to, so the seal has to come from the stream ending.
            kill(server.h.worker_proc, Base.SIGKILL)

            @test TK.wait_for(server, "pin dropped",
                "document.querySelector('.bt-taskbar-todo') === null"; timeout = 30) == true
            # NOT enough on its own: a chat that tore its whole UI down would also
            # satisfy it. The list has to arrive in the conversation as history —
            # that is the difference between "sealed" and "vanished".
            @test TK.wait_for(server, "finalized plan bubble",
                "document.querySelector('.bt-plan-msg') !== null"; timeout = 15) == true
            # Finalized, not still pulsing (`bt-plan-live` is what drives that).
            @test TK.eval_js(server,
                "document.querySelectorAll('.bt-plan-msg.bt-plan-live').length") == 0
            # Both entries kept, with the statuses the agent last reported — NOT a
            # completion invented on its behalf. `▶` = in_progress, `○` = pending,
            # `✓` = completed (msg_to_dict), so this reads exactly 0/2 done: the
            # honest record of how far it got before the machine went away.
            @test TK.eval_js(server,
                "Array.from(document.querySelectorAll('.bt-plan-msg .bt-plan-status'))" *
                ".map(e => e.textContent).join('')") == "▶○"
        end

        # OBSERVATION, not yet a contract — see the note in the summary. A
        # backgrounded subagent's liveness is deliberately NOT the stream's to
        # decide (its output file outlives the turn, and the worker may come
        # back), so the pill is expected to stay. Recorded here so the choice is
        # visible and a future change to it fails loudly.
        @testset "a backgrounded subagent's pill is NOT dropped by the death" begin
            @test TK.eval_js(server,
                "document.querySelector('.bt-taskbar-slot[data-task-id=\"task-BG\"]') !== null") == true
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
