# Running Julia on ANOTHER worker, end to end through the real UI:
#
#   1. a chat on worker A; worker B joins. `bt_julia_eval(worker = "worker-b")`
#      is refused while the chat's "remote julia" switch is off — the eval card
#      still wears the ⇢ worker-b badge (what was asked is visible either way),
#      and the tool's result tells the agent where the switch is;
#   2. the switch, a pill in the chat header next to the permissions pill, is
#      turned on by the user; the same call now runs on B: the server spawns a
#      BonitoMCP eval host on worker B for this chat, relays the eval, and the
#      result names B's worker id (the host's own environment);
#   3. `bt_julia_list_sessions` lists worker B and its live host;
#   4. `bt_sync_folder` copies a folder from A to B through the server;
#   5. switching it off shuts the host down and the refusal is back.
#
# Two real worker processes (TestKit's `add_worker!`), the real dev_server, the
# mock agent only where the agent's decisions would be. ISOLATED: it spawns a
# second worker, so it gets its own throwaway dev_server + browser.
@testitem "e2e:remote_eval" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    # The tool card for `id` finished (either way) and its body shows `text`.
    # Bodies render lazily on expand (what a user does to read a result), so a
    # collapsed finished card is expanded — ONCE, marked on the node: this runs
    # from a poll, and clicking a second time collapses the card again (and
    # tears a half-built Monaco editor out of the document under itself).
    card_shows(id, text) = """(() => {
        const c = $(card(id)); if (!c) return false;
        const st = c.querySelector('.bt-tool-status')?.textContent || '';
        if (!(st === 'completed' || st === 'failed')) return false;
        const h = c.querySelector('.bt-tool-header');
        if (h && !c.dataset.probeExpanded) {
            c.dataset.probeExpanded = '1';
            if (h.dataset.expanded !== 'true') h.click();
            return false;
        }
        return (c.querySelector('.bt-tool-body')?.innerText || '').includes($(repr(text))); })()"""
    card_badge(id) = "(() => { const c = $(card(id)); const b = c && c.querySelector('.bt-tool-worker'); return b ? b.textContent : ''; })()"
    # The switch is a TOGGLE (two states), so the test clicks it like a user and
    # reads the state off the pill rather than driving a <select>'s value.
    remote_pill = "$VP?.querySelector('.bt-header-remote')"
    remote_state = "($(remote_pill)?.classList.contains('bt-header-remote-on') ? 'on' : 'off')"
    set_switch(v) = """(() => { const b = $(remote_pill); if (!b) return false;
        const on = b.classList.contains('bt-header-remote-on');
        if ((on ? 'on' : 'off') !== $(repr(v))) b.click();
        return true; })()"""

    server = TK.dev_server(agent = _ -> [TK.end_turn()])
    try
        TK.open_browser(server)
        state = server.h.state

        @testset "remote julia: off by default, on by the header switch" begin
            # The chat is created while worker A is the only worker (which card
            # `new_chat` presses "+ Project" on follows the worker list's order).
            @test TK.wait_for(server, "worker A online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
                timeout = 20) == true
            cwd = mkpath(joinpath(mktempdir(), "remoteproj"))
            pid = TK.new_chat(server; cwd = cwd)
            p = state.projects[][pid]
            worker_b_proc = TK.add_worker!(server; name = "worker-b")
            t0 = time()
            while time() - t0 < 30 &&
                  !any(w -> w.name == "worker-b" && w.online[], values(state.workers[]))
                sleep(0.1)
            end
            worker_b = only(w for w in values(state.workers[]) if w.name == "worker-b")
            @test worker_b.online[]

            # ── 1. off by default ────────────────────────────────────────────
            @test TK.wait_for(server, "the switch is in the header, off",
                "$(remote_state) === 'off'"; timeout = 30) == true
            @test p.remote_eval === false
            server.agent_fn[] = _ -> [TK.bt_eval("1 + 1"; worker = "worker-b", id = "re-off"),
                                      TK.end_turn()]
            TK.send_message(server, "try it on worker-b")
            @test TK.wait_for(server, "the card wears the worker badge",
                "$(card_badge("re-off")).includes('worker-b')"; timeout = 60) == true
            @test TK.wait_for(server, "refused while off, saying where the switch is",
                card_shows("re-off", "switched OFF"); timeout = 60) == true
            @test isempty(state.eval_hosts)

            # ── 2. the user switches it on; the eval runs on B ───────────────
            @test TK.eval_js(server, set_switch("on")) == true
            t0 = time()
            while !p.remote_eval && time() - t0 < 10; sleep(0.05); end
            @test p.remote_eval === true
            @test TK.wait_for(server, "the switch reads on",
                "$(remote_state) === 'on'"; timeout = 10) == true
            server.agent_fn[] = _ -> [TK.bt_eval(
                "string(\"host=\", get(ENV, \"BONITOAGENTS_EVAL_HOST_WORKER\", \"none\"))";
                worker = "worker-b", id = "re-on"), TK.end_turn()]
            TK.send_message(server, "now for real")
            # First use spawns the host on B and waits for it to dial back (a
            # julia start + `using BonitoMCP`), then starts an eval worker there
            # and runs the eval. The budget has to clear the SERVER's own bound
            # for that — `EVAL_HOST_SPAWN_TIMEOUT_S` (180 s) plus the eval — or a
            # slow machine reads as a product failure.
            @test TK.wait_for(server, "the eval ran on worker B",
                card_shows("re-on", "host=" * worker_b.worker_id); timeout = 420) == true
            @test TK.eval_js(server, card_badge("re-on")) == "⇢ worker-b"
            @test length(BT.eval_hosts_of(state, pid)) == 1
            @test first(BT.eval_hosts_of(state, pid))[1] == worker_b.worker_id

            # ── 3. the listing names B and its live host ─────────────────────
            server.agent_fn[] = _ -> [TK.mcp_call("bt_julia_list_sessions"; id = "re-list"),
                                      TK.end_turn()]
            TK.send_message(server, "what do we have")
            @test TK.wait_for(server, "the listing names worker-b's host",
                card_shows("re-list", "eval host running"); timeout = 60) == true
            @test TK.eval_js(server, card_shows("re-list", "worker-b")) == true

            # ── 4. a folder travels A → B ────────────────────────────────────
            src = mkpath(joinpath(mktempdir(), "payload"))
            write(joinpath(src, "hello.txt"), "from A\n")
            mkpath(joinpath(src, "deep")); write(joinpath(src, "deep", "n.txt"), "nested\n")
            dst = BT.worker_join(worker_b.projects_root, "payload-on-b")
            server.agent_fn[] = _ -> [TK.mcp_call("bt_sync_folder"; id = "re-sync",
                                                  src = src, worker = "worker-b", dst = dst),
                                      TK.end_turn()]
            TK.send_message(server, "ship the folder")
            @test TK.wait_for(server, "the folder synced",
                card_shows("re-sync", "synced"); timeout = 120) == true
            @test read(joinpath(dst, "hello.txt"), String) == "from A\n"
            @test read(joinpath(dst, "deep", "n.txt"), String) == "nested\n"

            # ── 5. off again: the host goes, the refusal is back ─────────────
            @test TK.eval_js(server, set_switch("off")) == true
            t0 = time()
            while (p.remote_eval || !isempty(BT.eval_hosts_of(state, pid))) && time() - t0 < 30
                sleep(0.1)
            end
            @test p.remote_eval === false
            @test isempty(BT.eval_hosts_of(state, pid))
            server.agent_fn[] = _ -> [TK.bt_eval("1 + 1"; worker = "worker-b", id = "re-off2"),
                                      TK.end_turn()]
            TK.send_message(server, "and now?")
            @test TK.wait_for(server, "refused again",
                card_shows("re-off2", "switched OFF"); timeout = 60) == true

            kill(worker_b_proc)
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
