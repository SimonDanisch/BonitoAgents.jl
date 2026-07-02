# End-to-end subagent visibility: a turn opens a background Task tool, then
# streams SUBAGENT events (text + a sub-tool) tagged with
# `_meta.claudeCode.parentToolUseId` — the exact frames claude-agent-acp
# forwards for a running subagent (TestKit's `sub_text` / `sub_tool`).
#
# The user-facing contract asserted here:
#   * Subagent prose/tools NEVER appear in the main transcript — no agent
#     bubble carries the prose, no top-level tool bubble opens for the
#     sub-tool. They land in the parent Task bubble's activity feed
#     (`.bt-task-feed`, live-expanded, most-recent-last) instead.
#   * A sub-tool's status update rewrites its feed entry in place.
#   * The pinned taskbar pill shows the CURRENT activity one-liner next to
#     the elapsed clock.
#   * Staleness: once `last_activity_at` is old (backdated server-side, like
#     cancel_escalation backdates `cancel_at` — no real 2-minute wait), the
#     next 1 Hz clock tick flips the pill's activity line to the amber
#     `bt-task-stale` "no activity Xm" state.
#   * Turn end finalizes the Task pill with the persisted one-line feed
#     trace ("N steps, finished HH:MM") — and no JS errors anywhere.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The scripted turn. The long tail `delay` holds the Task live so the feed /
# taskbar / staleness assertions run against a pinned, in-flight pill; the
# closing tool_update + text give the finalize assertions a terminal
# transition. (`delay` never shortcuts, so the turn ends after ~27 s.)
agent_script(_prompt) = [
    TK.text("Delegating to a subagent."),
    TK.tool(kind = "other", title = "Investigate the code", tool_name = "Task",
            id = "task-A", open_status = "in_progress", complete = false,
            raw_input = Dict{String,Any}(
                "description" => "Investigate the code",
                "prompt" => "dig around",
                "run_in_background" => true)),
    # Let the tool_call clear the message consumer (the sink drops events
    # whose parent bubble doesn't exist yet — by design).
    TK.delay(1200),
    TK.sub_text("task-A", "SUBAGENT-PROSE scanning the sources"),
    TK.sub_tool("task-A"; id = "sub-grep", kind = "search",
                title = "Grep parse_update", status = "in_progress"),
    TK.delay(400),
    TK.sub_tool("task-A"; id = "sub-grep", status = "completed", update = true),
    TK.delay(25000),
    TK.tool_update("task-A"; status = "completed",
                   content = [TK.text_block("subagent finished")]),
    TK.text("All done."),
]

function poll_until(cond; timeout = 30.0, interval = 0.1)
    t0 = time()
    while time() - t0 < timeout
        cond() && return true
        sleep(interval)
    end
    return false
end

function run_suite(server)
    BA = TestKit.BT
    server.agent_fn[] = agent_script
    TK.clear_js_errors(server)

    @testset "BonitoAgents subagent feed" begin
        pid = TK.new_chat(server; title = "SubFeed")
        TK.send_message(server, "go delegate")

        @testset "task bubble opens with a live activity feed" begin
            # Cold-start budget for the first turn (fresh dev_server +
            # electron + mock spawn), like the sibling suites' first wait.
            @test TK.wait_for(server, "task tool bubble",
                "document.querySelectorAll('.bt-tool-msg').length === 1"; timeout = 30) == true
            @test TK.wait_for(server, "feed section with both entries",
                "document.querySelectorAll('.bt-task-feed-entry').length >= 2"; timeout = 15) == true
            # Live task → the feed section is auto-expanded.
            @test TK.eval_js(server,
                "document.querySelector('.bt-task-feed-list').style.display") != "none"
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-task-feed-entry')].some(r => r.textContent.includes('SUBAGENT-PROSE scanning the sources'))") == true
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-task-feed-entry')].some(r => r.textContent.includes('Grep parse_update'))") == true
            # The sub-tool's status update rewrote its entry in place.
            @test TK.wait_for(server, "sub-tool entry flips completed",
                "document.querySelectorAll('.bt-task-feed-entry.bt-feed-completed').length === 1"; timeout = 10) == true
            @test TK.eval_js(server,
                "document.querySelectorAll('.bt-task-feed-entry').length") == 2
        end

        @testset "subagent events never hit the main transcript" begin
            # Prose: only inside the feed, never as/inside an agent bubble.
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-agent-msg')].some(b => (b.innerText||'').includes('SUBAGENT-PROSE'))") == false
            # Sub-tool: no top-level tool bubble of its own (the Task is the
            # ONLY tool bubble in the transcript).
            @test TK.eval_js(server,
                "document.querySelectorAll('.bt-tool-msg').length") == 1
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-tool-title')].some(t => t.textContent.includes('Grep parse_update'))") == false
        end

        @testset "taskbar pill shows the current activity" begin
            @test TK.wait_for(server, "pinned task slot",
                "document.querySelector('.bt-taskbar-slot .bt-taskbar-activity') !== null"; timeout = 10) == true
            # Current activity = the feed's latest entry (the grep sub-tool),
            # re-rendered on the Julia-side 1 Hz clock tick.
            @test TK.wait_for(server, "activity one-liner next to the clock",
                "(document.querySelector('.bt-taskbar-slot .bt-taskbar-activity')?.textContent || '').includes('Grep parse_update')"; timeout = 10) == true
        end

        @testset "staleness flips the pill on the next clock tick" begin
            state = server.h.state
            model = nothing
            @test poll_until(timeout = 10) do
                model = get(state.chat_models, pid, nothing)
                model !== nothing
            end
            task = lock(model.lock) do
                idx = findfirst(m -> m isa BA.TaskToolMsg && m.id == "task-A",
                                model.msgs_store)
                idx === nothing ? nothing : model.msgs_store[idx]
            end
            @test task isa BA.TaskToolMsg
            # Backdate the feed server-side (mirrors cancel_escalation's
            # cancel_at backdating) — the pill must go amber on the next tick.
            lock(() -> (task.last_activity_at = time() - 200.0), model.lock)
            @test TK.wait_for(server, "stale class on the pill",
                "document.querySelector('.bt-taskbar-slot .bt-task-stale') !== null"; timeout = 10) == true
            @test TK.eval_js(server,
                "document.querySelector('.bt-taskbar-slot .bt-task-stale').textContent") == "no activity 3m"
        end

        @testset "turn end finalizes the pill with the feed trace" begin
            @test TK.wait_for(server, "task pill completed",
                "document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent === 'completed'"; timeout = 40) == true
            @test TK.wait_for(server, "persisted one-line feed summary",
                "/\\d+ steps, finished \\d\\d:\\d\\d/.test(document.querySelector('.bt-tool-msg .bt-tool-summary')?.textContent || '')"; timeout = 10) == true
            # The pill unpins with the tool; the feed section stays in the bubble.
            @test TK.wait_for(server, "pin dropped",
                "document.querySelector('.bt-taskbar-slot[data-task-id]') === null"; timeout = 10) == true
            @test TK.eval_js(server,
                "document.querySelectorAll('.bt-task-feed-entry').length") == 2
        end

        @testset "no JS errors" begin
            @test isempty(TK.js_errors(server))
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
