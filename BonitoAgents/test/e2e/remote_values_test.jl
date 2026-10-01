# Julia VALUES between a chat's own session and one on ANOTHER worker, end to
# end through the real UI (`remote_session`, BonitoMCP's remote_values.jl):
#
#   1. a chat on worker A; worker B joins. `remote_session("worker-b")` in A's
#      session is refused while the chat's "remote julia" switch is off, and the
#      error says where the switch is;
#   2. the user turns the switch on; A sends a value over the websocket layers'
#      16 MiB message limit, and a remote eval on B reads it;
#   3. a value made on B comes back to A, a function sent from A runs on B, and an
#      error there comes back as one;
#   4. switching it off ends the exchange: the next request is refused.
#
# Two real worker processes, the real dev_server, real MCP processes on both
# (the eval host on B), the mock agent only where the agent's decisions would
# be. ISOLATED: it spawns a second worker, so it gets its own dev_server + browser.
@testitem "e2e:remote_values" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT
    real_eval(code; kw...) = TK.bt_eval(code; real_process = true, kw...)
    real_call(tool; kw...) = TK.mcp_call(tool; real_process = true, kw...)

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    # The tool card for `id` finished (either way) and its body shows `text`;
    # a collapsed card is expanded once, the way a user reads a result.
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
    remote_item = "$VP?.querySelector('.bt-header-menu .bt-header-remote')"
    open_menu = "(() => { const p=$VP; const t=p && p.querySelector('.bt-header-menu .bt-menu-trigger'); if(!t) return false; t.click(); return true; })()"
    menu_open = "$VP?.querySelector('.bt-header-menu')?.classList.contains('bt-menu-open') === true"
    set_switch(v) = """(() => { const b = $(remote_item); if (!b) return false;
        const on = b.classList.contains('bt-cap-on');
        if ((on ? 'on' : 'off') !== $(repr(v))) b.click();
        return true; })()"""
    function flip!(server, p, on)
        @test TK.eval_js(server, open_menu) == true
        @test TK.wait_for(server, "the ⋯ menu is open", menu_open; timeout = 10) == true
        @test TK.eval_js(server, set_switch(on ? "on" : "off")) == true
        t0 = time()
        while p.remote_eval != on && time() - t0 < 10; sleep(0.05); end
        @test p.remote_eval === on
    end
    function ask(server, text, calls...)
        server.agent_fn[] = _ -> [calls..., TK.end_turn()]
        TK.send_message(server, text)
    end

    server = TK.dev_server(agent = _ -> [TK.end_turn()])
    try
        TK.open_browser(server)
        state = server.h.state

        @testset "values between a chat's session and another worker's" begin
            @test TK.wait_for(server, "worker A online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
                timeout = 20) == true
            cwd = mkpath(joinpath(mktempdir(), "valuesproj"))
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

            # ── 1. off: refused, saying where the switch is ──────────────────
            @test p.remote_eval === false
            ask(server, "fetch from worker-b", real_eval("remote_session(\"worker-b\")[:x]"; id = "rv-off"))
            @test TK.wait_for(server, "refused while the switch is off",
                card_shows("rv-off", "switched OFF"); timeout = 120) == true
            @test TK.eval_js(server, card_shows("rv-off", "RemoteSessionError")) == true
            @test isempty(state.value_pairs)

            # ── 2. on: a value over one message's limit goes A → B ───────────
            flip!(server, p, true)
            ask(server, "send the data to worker-b", real_eval("""
                r = remote_session("worker-b")
                r[:rv_data] = collect(1.0:3.0e6)     # 24 MB
                println("sent to ", r.name, ": ", 3 * 10^6)
                """; id = "rv-send"))
            # First use spawns the eval host on B and its session (the server's
            # own bounds: EVAL_HOST_SPAWN_TIMEOUT_S plus a julia start).
            @test TK.wait_for(server, "the value was sent",
                card_shows("rv-send", "sent to worker-b: 3000000"); timeout = 420) == true
            ask(server, "look at it there", real_eval(
                "println(\"there: \", length(rv_data), \" sum \", Int(sum(rv_data)))";
                worker = "worker-b", id = "rv-there"))
            @test TK.wait_for(server, "B's session holds it",
                card_shows("rv-there", "there: 3000000 sum 4500001500000"); timeout = 120) == true

            # ── 3. B → A, a function A → B, an error B → A ───────────────────
            ask(server, "make something there", real_eval(
                "rv_made = Dict(\"host\" => get(ENV, \"BONITOAGENTS_EVAL_HOST_WORKER\", \"none\")); nothing";
                worker = "worker-b", id = "rv-make"))
            @test TK.wait_for(server, "made on B", card_shows("rv-make", ""); timeout = 120) == true
            # Returned, so it renders LIVE through this chat's own bridge, while
            # B's session has a bridge into the chat too: the two coexist.
            ask(server, "bring it back", real_eval("""
                r = remote_session("worker-b")
                string("fetched ", r[:rv_made]["host"], " doubled ", r(x -> 2 .* x, [1, 2, 3]))
                """; id = "rv-fetch"))
            @test TK.wait_for(server, "the value came back and the function ran there",
                card_shows("rv-fetch", "fetched $(worker_b.worker_id) doubled [2, 4, 6]"); timeout = 120) == true
            # Live values from both machines, alternating, all live.
            ask(server, "a live value there", real_eval("string(\"from \", \"b\")"; worker = "worker-b", id = "rv-live-b"))
            @test TK.wait_for(server, "B's value, live", card_shows("rv-live-b", "from b"); timeout = 120) == true
            ask(server, "and one here", real_eval("string(\"from \", \"a\")"; id = "rv-live-a"))
            @test TK.wait_for(server, "A's value, live", card_shows("rv-live-a", "from a"); timeout = 120) == true
            @test TK.eval_js(server, "document.body.innerText.includes('result not live')") == false
            @test length([k for k in keys(state.eval_workers) if startswith(k, pid)]) == 2
            ask(server, "fail there", real_eval(
                "remote_session(\"worker-b\")(() -> error(\"bad \" * \"on b\"))"; id = "rv-err"))
            @test TK.wait_for(server, "the error on B came back as one",
                card_shows("rv-err", "RemoteSessionError: on worker-b"); timeout = 120) == true
            @test TK.eval_js(server, card_shows("rv-err", "bad on b")) == true

            # A long call there, stopped from here: the stop ends it at once,
            # and the next request works (over a new connection).
            ask(server, "a long call", real_eval(
                "remote_session(\"worker-b\")(() -> (sleep(90); :late))"; id = "rv-long", timeout = 0.5))
            @test TK.wait_for(server, "the long call is running",
                "($(card("rv-long"))?.querySelector('.bt-tool-summary')?.textContent || '').includes('· running')";
                timeout = 60) == true
            ask(server, "stop it", real_call("bt_julia_interrupt"; id = "rv-stop"))
            @test TK.wait_for(server, "the long call stopped",
                "($(card("rv-long"))?.querySelector('.bt-tool-summary')?.textContent || '').includes('✗ interrupted')";
                timeout = 60) == true
            ask(server, "again", real_eval("""
                println("after the stop: ", remote_session("worker-b")[:rv_made]["host"])
                """; id = "rv-after-stop"))
            @test TK.wait_for(server, "the next request works",
                card_shows("rv-after-stop", "after the stop: $(worker_b.worker_id)"); timeout = 120) == true

            # ── 4. off: the exchange ends, the next request is refused ───────
            flip!(server, p, false)
            t0 = time()
            while !isempty(BT.eval_hosts_of(state, pid)) && time() - t0 < 30; sleep(0.1); end
            @test isempty(BT.eval_hosts_of(state, pid))
            ask(server, "and now?", real_eval("remote_session(\"worker-b\")[:rv_made]"; id = "rv-off2"))
            @test TK.wait_for(server, "refused again",
                card_shows("rv-off2", "switched OFF"); timeout = 120) == true
            @test isempty(state.value_pairs)

            kill(worker_b_proc)
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
