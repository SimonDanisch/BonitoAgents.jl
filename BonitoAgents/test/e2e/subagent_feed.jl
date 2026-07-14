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
#   * Deterministic completion: a background subagent's `completed` tool_update
#     is the launch-ack lie (no `outputFile` ⇒ no wire done-signal), so the pill
#     STAYS pinned through it — no timeout, no staleness guess — and leaves only
#     on ⊗ stop (fd-close finalization is covered by e2e:subagent_poll). No JS
#     errors anywhere.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The scripted turn. The long tail `delay` holds the Task live so the feed /
# taskbar assertions run against a pinned, in-flight pill; the closing
# tool_update reports `completed` (the launch-ack lie, which must NOT finalize
# the pill). (`delay` never shortcuts, so the turn ends after ~27 s.)
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

        @testset "live subagent: pill AND bubble both say running — NOT completed-in-chat while pinned" begin
            # task-A's closing tool_update reports `completed`, but for a background
            # subagent that's the launch-ack LIE, not a done-signal. The pill stays
            # pinned (no outputFile ⇒ no end_turn to read ⇒ stays until ⊗ stop). The
            # CONSISTENCY that matters: while the pill is pinned/running the chat
            # bubble must NOT show `completed` either — a task shown running in the
            # taskbar but completed in the chat at the same time was the bug.
            state = server.h.state
            model = nothing
            @test poll_until(timeout = 10) do
                model = get(state.chat_models, pid, nothing)
                model !== nothing
            end
            # Wait for the mock's closing "All done." text — that lands AFTER the
            # `tool_update completed`, so once it shows we KNOW the client processed
            # the launch-ack `completed`.
            @test TK.wait_for(server, "turn's closing text",
                "[...document.querySelectorAll('.bt-agent-msg')].some(e => (e.innerText||'').includes('All done'))"; timeout = 40) == true
            task = lock(model.lock) do
                idx = findfirst(m -> m isa BA.TaskToolMsg && BA.tool_id(m) == "task-A",
                                model.msgs_store)
                idx === nothing ? nothing : model.msgs_store[idx]
            end
            @test task isa BA.TaskToolMsg
            @test BA.in_taskbar(task)                                  # completed ≠ done
            # The pill is pinned AND the bubble is NOT `completed` — they agree.
            @test TK.wait_for(server, "pill still pinned",
                "document.querySelector('.bt-taskbar-slot[data-task-id=\"task-A\"]') !== null"; timeout = 5) == true
            @test TK.eval_js(server,
                "document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent") != "completed"
            # ⊗ stop → the only exit here (no outputFile): the pill unpins and the
            # feed section stays in the bubble.
            BA.request_tool_stop!(model, task)
            @test !BA.in_taskbar(task)
            @test TK.wait_for(server, "pin dropped after ⊗ stop",
                "document.querySelector('.bt-taskbar-slot[data-task-id=\"task-A\"]') === null"; timeout = 10) == true
            @test TK.eval_js(server,
                "document.querySelectorAll('.bt-task-feed-entry').length") == 2
        end

        @testset "background subagent stays pinned past turn end; ⊗ stop unpins" begin
            # A run_in_background Task's tool_call completes at LAUNCH (the
            # ack) — the old behavior unpinned it there, leaving zero GUI
            # feedback of the running subagent. It must now survive its own
            # close AND the turn end (membership IS liveness — it's in the bar),
            # until the user stops it.
            # The real launch-ack wire shape: ONE tool_call frame reporting
            # "completed" and NO closing tool_update (`complete = false`). With
            # no outputFile there is no deterministic done-signal, so the bar's
            # loop leaves it pinned (`isdone(::TaskToolMsg)` is false).
            server.agent_fn[] = p -> Any[
                TK.tool(kind = "other", title = "Background investigation",
                        tool_name = "Task", id = "task-BG",
                        complete = false, open_status = "completed",
                        raw_input = Dict{String,Any}(
                            "run_in_background" => true,
                            "description"       => "bg work")),
                TK.text("launched, moving on"), TK.end_turn()]
            TK.send_message(server, "delegate in background")
            BA    = TK.BT
            model = server.h.state.chat_models[pid]
            # Wait until the TURN is over (busy off) — the moment the old code
            # would have unpinned the slot.
            t0 = time()
            while BA.shared(model).busy_active[] && time() - t0 < 30
                sleep(0.2)
            end
            @test !BA.shared(model).busy_active[]
            t = lock(BA.shared(model).lock) do
                i = findlast(m -> m isa BA.TaskToolMsg && BA.tool_id(m) == "task-BG",
                             BA.shared(model).msgs_store)
                i === nothing ? nothing : BA.shared(model).msgs_store[i]
            end
            @test t !== nothing
            @test BA.in_taskbar(t)
            @test BA.is_live(t)
            @test any(x -> BA.msg_id(x) == "task-BG", BA.shared(model).taskbar.items[])
            # The pill also survives in the DOM past turn end.
            @test TK.wait_for(server, "bg task pill pinned after turn end",
                "document.querySelector('.bt-taskbar-slot[data-task-id=\"task-BG\"]') !== null"; timeout = 10) == true
            # ⊗ stop: liveness clears, slot unpins.
            BA.request_tool_stop!(model, t)
            @test !BA.in_taskbar(t)
            @test !BA.is_live(t)
            @test TK.wait_for(server, "bg task pill unpinned after stop",
                "document.querySelector('.bt-taskbar-slot[data-task-id=\"task-BG\"]') === null"; timeout = 10) == true
        end

        @testset "between-turn frames: feed stays live, auto-wake message renders, pill finalizes" begin
            # The real wire (fixtures/bg_subagent_wire.jsonl): after end_turn
            # the bg subagent's tagged activity keeps flowing, then the main
            # agent auto-wakes with an untagged completion announcement. All
            # of it used to be dropped. Now: feed updates after turn end, the
            # announcement renders as a new agent bubble, and — single running
            # bg task — the pill finalizes on the announcement.
            server.agent_fn[] = p -> Any[
                TK.tool(kind = "other", title = "Background research",
                        tool_name = "Task", id = "task-BG2",
                        complete = false, open_status = "completed",
                        raw_input = Dict{String,Any}(
                            "run_in_background" => true,
                            "description"       => "bg research")),
                TK.text("launched bg research"),
                TK.post_turn(Any[
                        Dict("type" => "sub_text", "parent" => "task-BG2",
                             "text" => "POSTTURN-SUB scanning archives"),
                        Dict("type" => "text",
                             "text" => "The background agent completed and replied: DONE_MARKER_42")];
                    delay_ms = 800),
                TK.end_turn()]
            TK.send_message(server, "research in background")
            BA    = TK.BT
            model = server.h.state.chat_models[pid]
            t0 = time()
            while BA.shared(model).busy_active[] && time() - t0 < 30
                sleep(0.2)
            end
            @test !BA.shared(model).busy_active[]
            t = lock(BA.shared(model).lock) do
                i = findlast(m -> m isa BA.TaskToolMsg && BA.tool_id(m) == "task-BG2",
                             BA.shared(model).msgs_store)
                i === nothing ? nothing : BA.shared(model).msgs_store[i]
            end
            @test t !== nothing && BA.in_taskbar(t)   # pinned at turn end = in the bar
            # (1) The post-turn SUB activity lands in the feed (after end_turn!).
            t0 = time()
            while time() - t0 < 15
                any(e -> occursin("POSTTURN-SUB", e.label), t.activity) && break
                sleep(0.2)
            end
            @test any(e -> occursin("POSTTURN-SUB", e.label), t.activity)
            # (2) The auto-wake announcement renders as a NEW agent bubble.
            @test TK.wait_for(server, "auto-wake message rendered",
                "[...document.querySelectorAll('.bt-agent-msg')].some(e => (e.innerText||'').includes('DONE_MARKER_42'))";
                timeout = 15) == true
            # (3) The auto-wake does NOT guess the pill's completion (the old
            # "exactly one running → done" heuristic is gone). This mock task has
            # no transcript `outputFile`, so the poller has no done-signal — the
            # pill stays live/pinned. Deterministic finalization off a real file
            # is covered by e2e:subagent_poll.
            sleep(2)
            @test BA.in_taskbar(t) == true
            @test TK.eval_js(server,
                "document.querySelector('.bt-taskbar-slot[data-task-id=\"task-BG2\"]') !== null") == true
            # (4) The next prompt tears the between-turn sink down (persisted, final).
            server.agent_fn[] = p -> Any[TK.text("ack"), TK.end_turn()]
            TK.send_message(server, "thanks")
            @test TK.wait_for(server, "follow-up turn done",
                "[...document.querySelectorAll('.bt-agent-msg')].some(e => (e.innerText||'').includes('ack'))";
                timeout = 20) == true
            bt = lock(BA.shared(model).lock) do
                BA.shared(model).between_turn[]
            end
            @test bt === nothing   # torn down at begin_turn!
        end

        @testset "long feed (>50 activities) stays readable, never blank" begin
            # Regression: a long subagent used to render its feed BLANK. Two bugs
            # compounded: (1) `.bt-task-feed-list` is a flex column with a 180px
            # cap, and its rows defaulted to `flex-shrink: 1`, so once the entries
            # overflowed the cap the browser squished every row toward ~2px
            # (blank) instead of scrolling; (2) a title-less `tool_call_update`
            # (the ACP completion frame carries no title) for a tool whose
            # announcement row had already been EVICTED by the feed's own 50-entry
            # window spawned a new EMPTY row — cascading until the whole feed was
            # empty labels. Drive the real shape: announce 55 titled sub-tools,
            # THEN complete them title-less (so the early ones are evicted before
            # their completion lands).
            server.agent_fn[] = p -> begin
                evs = Any[TK.text("Delegating."),
                    TK.tool(kind = "other", title = "Long subagent", tool_name = "Task",
                            id = "task-LONG", open_status = "in_progress", complete = false,
                            raw_input = Dict{String,Any}("description" => "Long subagent",
                                                          "prompt" => "work"))]
                push!(evs, TK.delay(500))
                for i in 1:55
                    push!(evs, TK.sub_tool("task-LONG"; id = "lng-$i", kind = "search",
                                           title = "grep pattern$i src/chat.jl", status = "pending"))
                end
                push!(evs, TK.delay(150))
                for i in 1:55                                   # title-less completions
                    push!(evs, TK.sub_tool("task-LONG"; id = "lng-$i", status = "completed", update = true))
                end
                push!(evs, TK.tool_update("task-LONG"; status = "completed",
                                          content = [TK.text_block("done")]))
                push!(evs, TK.text("Long feed done."))
                evs
            end
            TK.send_message(server, "run a long subagent")
            @test TK.wait_for(server, "long feed turn done",
                "[...document.querySelectorAll('.bt-agent-msg')].some(e => (e.innerText||'').includes('Long feed done'))";
                timeout = 60) == true
            # Expand the (finished, collapsed) feed for THIS bubble.
            TK.eval_js(server, raw"""(() => {
                const heads = [...document.querySelectorAll('.bt-task-feed-head')];
                const h = heads[heads.length - 1];
                if (h && h.dataset.expanded !== 'true') (h.querySelector('.bt-tool-toggle')||h).click();
                return true; })()""")
            sleep(0.4)
            # The feed is bounded to 50 rows, none empty (the orphan-completion
            # fix), and each row keeps its content height (the flex-shrink fix) so
            # the list SCROLLS rather than squishing rows to an unreadable sliver.
            # Scope everything to the NEWEST feed: `.bt-task-feed-*` is not in the
            # harness pane-scope shim, and this suite's earlier Task bubbles
            # (task-A, task-BG2) contribute their own feed entries globally.
            metrics = TK.eval_js(server, raw"""(() => {
                const feeds = [...document.querySelectorAll('.bt-task-feed')];
                const feed = feeds[feeds.length - 1];
                if (!feed) return { rows: -1 };
                const list = feed.querySelector('.bt-task-feed-list');
                const rows = [...feed.querySelectorAll('.bt-task-feed-entry')];
                const empty = rows.filter(r => ((r.textContent||'').trim()) === '').length;
                const minH = Math.min(...rows.slice(0, 10).map(r => r.getBoundingClientRect().height));
                return { rows: rows.length, empty, minH,
                         scrolls: list ? (list.scrollHeight > list.clientHeight + 5) : false }; })()""")
            @test metrics["rows"] == 50
            @test metrics["empty"] == 0            # no blank rows
            @test metrics["minH"] >= 8             # rows not squished to a sliver (was ~2px)
            @test metrics["scrolls"] == true       # overflow scrolls instead of shrinking
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
