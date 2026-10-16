# Julia RUNS through the real UI: background evals on two workers from one chat.
#
#   1. one turn starts three background runs — two on the chat's own worker, one
#      on worker B — and ends. The cards stay live (they follow their run, not
#      the call that returned at once), stream their output after the turn is
#      over, and each run has a task-bar row naming its id, worker and env;
#   2. a failing run ends on its own: its card shows ✗ and the failure's first
#      line, and the agent — idle — is told in an app message, answers with
#      bt_julia_wait and gets the result;
#   3. the ⊗ on worker B's row stops that run and nothing else;
#   4. collected runs leave the task bar;
#   5. a continue that comes long after its eval says what it waits on (run
#      id, the eval's first code line), the run's row says the agent waits on
#      it, and its ↑ chip brings the eval back into view.
#
# (That a cancelled turn leaves background runs running is pinned in BonitoMCP's
# test_runs.jl, on the `handle_cancelled!` a `notifications/cancelled` reaches:
# the mock agent does not forward cancels to a real MCP process.)
#
# Real BonitoMCP processes all the way (`real_process = true`: the mock agent
# launches the MCP from the worker's launch config, and worker B gets a real
# eval host), the real dev_server, DOM assertions only. One run is started by an
# "anonymous" agent (no Claude tool id on the call), so the card is found by its
# worker and env the way it is for every non-Claude agent. ISOLATED: it spawns a
# second worker, so it gets its own throwaway dev_server + browser.
@testitem "e2e:eval_runs" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    real_eval(code; kw...) = TK.bt_eval(code; real_process = true, kw...)
    real_call(tool; kw...) = TK.mcp_call(tool; real_process = true, kw...)

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    live(id) = "($(card(id))?.classList.contains('bt-tool-live') === true)"
    summary(id) = "($(card(id))?.querySelector('.bt-tool-summary')?.textContent || '')"
    body(id) = "($(card(id))?.querySelector('.bt-tool-body')?.innerText || '')"
    slot(id) = "$VP?.querySelector('.bt-taskbar-slot[data-task-id=\"$id\"]')"
    slot_text(id) = "($(slot(id))?.innerText || '')"
    # A finished card shows its result in the body; bodies of finished cards
    # render on expand, so expand ONCE (a second click would collapse it).
    card_shows(id, text) = """(() => {
        const c = $(card(id)); if (!c) return false;
        const h = c.querySelector('.bt-tool-header');
        if (h && !c.dataset.probeExpanded && h.dataset.expanded !== 'true') {
            c.dataset.probeExpanded = '1'; h.click(); return false; }
        return (c.querySelector('.bt-tool-body')?.innerText || '').includes($(repr(text))); })()"""
    notes = "[...($VP?.querySelectorAll('.bt-user-msg-auto') || [])].map(n => n.innerText).join('\\n')"
    remote_item = "$VP?.querySelector('.bt-header-menu .bt-header-remote')"
    open_menu = "(() => { const t = $VP?.querySelector('.bt-header-menu .bt-menu-trigger'); if (!t) return false; t.click(); return true; })()"

    # ONE agent for the whole test, routed by the prompt, so a finish note can
    # never be answered by the script meant for a user message. It answers a
    # note by collecting exactly the runs it names.
    function agent(prompt)
        if occursin("Background Julia run", prompt)
            ids = unique([m.match for m in eachmatch(r"\br\d+\b", prompt)])
            return [real_call("bt_julia_wait"; runs = ids, seconds = 60,
                              id = "wait-" * join(ids, "-")), TK.end_turn()]
        elseif occursin("late continue", prompt)
            return [
                real_eval("for i in 1:24; println(\"suite \", i); sleep(0.5); end; :suite_ok";
                          env_path = env_b, timeout = 2, id = "run-e"),
                TK.text("While that runs, something else entirely. " ^ 40),
                TK.bash("ls", "Project.toml\nsrc\ntest"; id = "late-ls"),
                TK.text("And more of it. " ^ 40),
                real_call("bt_julia_continue"; env_path = env_b, timeout = 40, id = "cont-e"),
                TK.end_turn()]
        elseif occursin("start three runs", prompt)
            # Worker B's run first: its eval host starts on first use (up to
            # minutes), and the local runs' clocks should start after that.
            # Run ids follow the order: run-c = r1, run-a = r2, run-b = r3.
            return [
                real_call("bt_julia_eval"; worker = "worker-b", background = true,
                          anonymous = true, id = "run-c",
                          code = "for i in 1:600; println(\"c tick \", i); sleep(0.5); end"),
                real_eval("for i in 1:120; println(\"a tick \", i); sleep(0.5); end; :a_done";
                          background = true, id = "run-a"),
                real_eval("sleep(8); error(\"Some tests did not pass: 3 passed, 1 failed\")";
                          env_path = env_b, background = true, id = "run-b"),
                TK.end_turn()]
        end
        return [TK.end_turn()]
    end

    cwd = mkpath(joinpath(mktempdir(), "runsproj"))
    env_b = mkpath(joinpath(cwd, "envB"))
    server = TK.dev_server(agent = agent)
    try
        TK.open_browser(server)
        state = server.h.state
        @test TK.wait_for(server, "worker A online",
            "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
            timeout = 20) == true
        pid = TK.new_chat(server; cwd = cwd)
        TK.add_worker!(server; name = "worker-b")
        t0 = time()
        while time() - t0 < 30 && !any(w -> w.name == "worker-b" && w.online[], values(state.workers[]))
            sleep(0.1)
        end
        # The user turns "remote julia" on for this chat, in its ⋯ menu.
        @test TK.eval_js(server, open_menu) == true
        @test TK.wait_for(server, "the remote julia item", "!!$(remote_item)"; timeout = 30) == true
        @test TK.eval_js(server, "$(remote_item).click(); true") == true
        @test TK.wait_for(server, "remote julia on",
            "$(remote_item)?.classList.contains('bt-cap-on') === true"; timeout = 10) == true

        @testset "three background runs outlive the turn that started them" begin
            TK.send_message(server, "start three runs")
            # The eval host on B comes up on first use (a julia start + `using
            # BonitoMCP`, bounded server-side by EVAL_HOST_SPAWN_TIMEOUT_S = 180 s).
            @test TK.wait_for(server, "the turn is over",
                "$VP?.querySelector('.bt-busy')?.classList.contains('bt-busy-active') === false && !!$(card("run-c"))";
                timeout = 420) == true
            for id in ("run-a", "run-b", "run-c")
                @test TK.wait_for(server, "$id stays live after the turn", live(id); timeout = 60) == true
            end
            @test TK.wait_for(server, "each run names itself on its card",
                "$(summary("run-a")).includes('r2 · running') && $(summary("run-c")).includes('r1 · running')";
                timeout = 30) == true
            # Output keeps arriving with the turn over.
            @test TK.wait_for(server, "run-a streams after the turn",
                "$(body("run-a")).includes('a tick 8')"; timeout = 60) == true
            @test TK.wait_for(server, "run-c (worker B) streams too",
                "$(body("run-c")).includes('c tick 4')"; timeout = 60) == true
            # A task-bar row per run: its id, its worker, its env.
            @test TK.wait_for(server, "task bar rows",
                "$(slot_text("run-a")).includes('r2') && $(slot_text("run-c")).includes('worker-b') && $(slot_text("run-b")).includes('envB')";
                timeout = 30) == true
        end

        @testset "a failing run ends on its own; the idle agent is told and collects it" begin
            @test TK.wait_for(server, "run-b ends failed with its first line",
                "$(summary("run-b")).includes('✗ failed after') && $(summary("run-b")).includes('— Some tests did not pass: 3 passed, 1 failed')";
                timeout = 60) == true
            @test TK.eval_js(server, live("run-b")) == false
            @test TK.wait_for(server, "the agent is told, once idle",
                "($(notes)).includes('Background Julia run finished: r3')"; timeout = 60) == true
            # …and collects it with bt_julia_wait. Polled here rather than with
            # `wait_for` (which throws) so a miss says what the card DID show.
            ok = timedwait(() -> TK.eval_js(server, card_shows("wait-r3", "Some tests did not pass")) === true,
                           90.0; pollint = 0.5) === :ok
            ok || @info "the wait card" card = TK.eval_js(server,
                "($(card("wait-r3"))?.innerText || '(no card)')") notes = TK.eval_js(server, notes)
            @test ok
            # run-a is still going: the note named only r3.
            @test TK.eval_js(server, live("run-a")) == true
        end

        @testset "⊗ on worker B's row stops that run only" begin
            @test TK.eval_js(server,
                "(() => { const b = $(slot("run-c"))?.querySelector('.bt-taskbar-slot-stop'); if (!b) return false; b.click(); return true; })()") == true
            @test TK.wait_for(server, "run-c interrupted",
                "$(summary("run-c")).includes('✗ interrupted')"; timeout = 60) == true
            @test TK.eval_js(server, live("run-a")) == true
            @test TK.wait_for(server, "the agent is told about r1",
                "($(notes)).includes('finished: r1')"; timeout = 60) == true
        end

        @testset "collected runs leave the task bar" begin
            # run-a ends on its own; the agent is told and collects it.
            @test TK.wait_for(server, "run-a ends passed",
                "$(summary("run-a")).includes('✓ passed')"; timeout = 90) == true
            # (Its heading, not its last line: the output above it is 120 lines.)
            ok = timedwait(() -> TK.eval_js(server, card_shows("wait-r2", "── r2 (passed) ──")) === true,
                           90.0; pollint = 0.5) === :ok
            ok || @info "run-a was not collected as expected" cards = TK.eval_js(server,
                "[...$VP.querySelectorAll('.bt-tool-msg')].map(c => c.dataset.msgId + ' | ' + (c.querySelector('.bt-tool-summary')?.textContent||'') + ' | ' + (c.querySelector('.bt-tool-body')?.innerText||'').slice(0, 300)).join('\\n')") notes = TK.eval_js(server, notes)
            @test ok
            @test TK.wait_for(server, "no run rows left in the task bar",
                "!$(slot("run-a")) && !$(slot("run-b")) && !$(slot("run-c"))";
                timeout = 120) == true
        end

        @testset "a late continue says what it waits on and leads back to it" begin
            TK.send_message(server, "late continue")
            @test TK.wait_for(server, "the continue blocks",
                "$(card("cont-e"))?.querySelector('.bt-tool-status')?.textContent === 'pending'";
                timeout = 90) == true
            # It names the run and what that run is, not just an env.
            @test TK.wait_for(server, "the continue names its run and code",
                "$(summary("cont-e")).startsWith('↳ r4 · for i in 1:24')"; timeout = 20) == true
            @test TK.eval_js(server, "$(card("cont-e")).querySelector('.bt-tool-jump')?.textContent") == "↑ r4"
            # The run's row says the agent is blocked on it.
            @test TK.wait_for(server, "the run's row says the agent waits",
                "$(slot_text("run-e")).includes('agent waiting')"; timeout = 20) == true
            # The chip brings the eval, far above, back into view, lit up.
            @test TK.eval_js(server, "$(card("cont-e")).querySelector('.bt-tool-jump').click(); true") == true
            @test TK.wait_for(server, "the eval is in view, lit up",
                """(() => { const e = $(card("run-e")); if (!e) return false;
                    const r = e.getBoundingClientRect(), v = $VP.querySelector('.bt-messages').getBoundingClientRect();
                    return r.top >= v.top - 2 && r.top < v.bottom && e.classList.contains('bt-jump-flash'); })()""";
                timeout = 10) == true
            # Back down, the way a user does (the jump left follow mode, and the
            # virtual list renders what is near the view): the pill, which shows
            # while the end of the chat is out of view. A jump that left the end
            # partly in view has none, as nothing is hidden below (seen once in a
            # full suite run); the end being hidden without a pill is the failure.
            @test TK.wait_for(server, "back to the bottom",
                "(() => { const b = [...document.querySelectorAll('.bt-new-msg-pill-visible')].find(x => x.offsetParent !== null); if (b) { b.click(); return true; } return !$VP.querySelector('.bt-messages').__bt_chat.lastMessageFullyOutOfView(); })()";
                timeout = 10) == true
            # It ends with the run's outcome, the row gone with the collection.
            @test TK.wait_for(server, "the continue ends with the run's outcome",
                "$(summary("cont-e")).includes('✓ passed')"; timeout = 60) == true
            @test TK.wait_for(server, "and the run's row leaves",
                "!$(slot("run-e"))"; timeout = 60) == true
        end
    finally
        close(server)
    end
end
