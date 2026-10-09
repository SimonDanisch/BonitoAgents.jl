# A restart of a chat ends everything its old session ran (processes.jl):
#
#   1. a background run that never yields (a test suite, a GPU wait) is killed,
#      its Julia eval worker with it. Malt starts that worker in a process group
#      of its own, so the worker's kill of the agent's group never reached it: it
#      ran on for good. The same for a run on another worker, in the chat's eval
#      host there;
#   2. each run's card says it was lost with the restart, and its task-bar row goes.
#
# Real BonitoMCP processes (`real_process = true`), the real dev_server and a
# second worker, DOM assertions only: each run prints its eval worker's pid, and
# an eval in the new session reports whether those pids still live (both
# workers run on this machine). ISOLATED: its own dev_server.
@testitem "e2e:restart_cleanup" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    real_eval(code; kw...) = TK.bt_eval(code; real_process = true, kw...)
    real_call(tool; kw...) = TK.mcp_call(tool; real_process = true, kw...)
    remote_item = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)?.querySelector('.bt-header-menu .bt-header-remote')"

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    summary(id) = "($(card(id))?.querySelector('.bt-tool-summary')?.textContent || '')"
    body(id) = "($(card(id))?.querySelector('.bt-tool-body')?.innerText || '')"
    slot(id) = "$VP?.querySelector('.bt-taskbar-slot[data-task-id=\"$id\"]')"
    menu_open = "(() => { const p = $VP; const l = p?.querySelector('.bt-header-menu .bt-menu-list'); " *
                "return !!l && getComputedStyle(l).display !== 'none'; })()"

    SPIN = "println(\"SPIN_PID=\", getpid()); flush(stdout); while true; end"
    old_pids = Int[]
    function agent(prompt)
        if occursin("spin", prompt)
            # The remote one first: its eval host starts on first use.
            return [real_call("bt_julia_eval"; worker = "worker-b", background = true, id = "spin-b", code = SPIN),
                    real_eval(SPIN; background = true, id = "spin-a"), TK.end_turn()]
        elseif occursin("check", prompt)
            return [real_eval("""
                pids = $(repr(old_pids))
                lives(p) = success(`kill -0 \$p`)
                t0 = time()
                while any(lives, pids) && time() - t0 < 30; sleep(0.2); end
                println("OLD_ALIVE=", any(lives, pids))"""; id = "check", timeout = 60),
                    TK.end_turn()]
        end
        return [TK.end_turn()]
    end
    spin_pid(id) = "(() => { const m = $(body(id)).match(/SPIN_PID=(\\d+)/); return m ? m[1] : false; })()"

    server = TK.dev_server(agent = agent)
    try
        TK.open_browser(server)
        state = server.h.state
        TK.new_chat(server; cwd = mkpath(joinpath(mktempdir(), "restartproj")))
        TK.add_worker!(server; name = "worker-b")
        t0 = time()
        while time() - t0 < 30 && !any(w -> w.name == "worker-b" && w.online[], values(state.workers[]))
            sleep(0.1)
        end
        # The user turns "remote julia" on for this chat, in its ⋯ menu.
        @test TK.eval_js(server, "(() => { const t = $VP?.querySelector('.bt-header-menu .bt-menu-trigger'); if (!t) return false; t.click(); return true; })()") == true
        @test TK.wait_for(server, "the remote julia item", "!!$(remote_item)"; timeout = 30) == true
        @test TK.eval_js(server, "$(remote_item).click(); true") == true
        @test TK.wait_for(server, "remote julia on",
            "$(remote_item)?.classList.contains('bt-cap-on') === true"; timeout = 10) == true

        TK.send_message(server, "spin")
        for id in ("spin-b", "spin-a")
            @test TK.wait_for(server, "$id is in the bar", "!!$(slot(id))"; timeout = 420) == true
            push!(old_pids, parse(Int, TK.wait_for(server, "$id's eval worker pid", spin_pid(id); timeout = 180)))
        end

        # The user restarts the chat from its ⋯ menu.
        @test TK.eval_js(server, "(() => { const t = $VP?.querySelector('.bt-header-menu .bt-menu-trigger'); if (!t) return false; t.click(); return true; })()") == true
        @test TK.wait_for(server, "menu opened", menu_open; timeout = 5) == true
        @test TK.eval_js(server, "(() => { const b = [...$VP.querySelectorAll('.bt-header-menu .bt-menu-item')]" *
            ".find(x => (x.textContent || '').trim().startsWith('Restart session')); if (!b) return false; b.click(); return true; })()") == true

        for id in ("spin-a", "spin-b")
            @test TK.wait_for(server, "$id ends with the session",
                "$(summary(id)).includes('lost') && $(summary(id)).includes('the chat was restarted')";
                timeout = 60) == true
            @test TK.wait_for(server, "$id leaves the bar", "!$(slot(id))"; timeout = 30) == true
        end
        @test TK.wait_for(server, "the session is back",
            "(() => { const p = $VP; return !!p && !p.querySelector('.bt-header-restart-busy') && !!document.querySelector('.bt-text-input'); })()";
            timeout = 120) == true

        # The new session asks whether the old runs' eval workers still live.
        TK.send_message(server, "check the old workers")
        @test TK.wait_for(server, "the old eval workers are gone",
            "$(body("check")).includes('OLD_ALIVE=false')"; timeout = 180) == true
        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end

# A worker killed outright (SIGKILL: an out-of-memory kill, a crash) runs no
# cleanup. When its chat's MCP server goes the same way, nothing is left to end
# the MCP's eval workers: they lead process groups of their own and carry no mark
# the restarted worker's sweep looks for. When the worker comes back as a new
# run, the server kills what the chats' record holds from its earlier runs
# (`kill_leftovers!`). Checked from a second chat, so the first one's session is
# not restarted (which would end its processes by itself).
@testitem "e2e:worker_restart_cleanup" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    import BonitoAgents as BT
    BW = BT.BonitoWorker
    real_eval(code; kw...) = TK.bt_eval(code; real_process = true, kw...)

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    body(id) = "($(card(id))?.querySelector('.bt-tool-body')?.innerText || '')"
    old_pid = Ref(0)
    function agent(prompt)
        if occursin("spin", prompt)
            # Its parent is the chat's MCP server.
            return [real_eval("println(\"SPIN_PID=\", getpid(), \" MCP_PID=\", ccall(:getppid, Cint, ())); " *
                              "flush(stdout); while true; end";
                              background = true, id = "lone-spin"), TK.end_turn()]
        elseif occursin("check", prompt)
            pid = old_pid[]
            return [real_eval("""
                t0 = time()
                while success(`kill -0 $pid`) && time() - t0 < 60; sleep(0.2); end
                println("OLD_ALIVE=", success(`kill -0 $pid`))"""; id = "lone-check", timeout = 90),
                    TK.end_turn()]
        end
        return [TK.end_turn()]
    end

    z = TK.dev_server(; agent)
    try
        TK.open_browser(z)
        state = z.h.state
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        wid = only(keys(state.workers[]))

        TK.new_chat(z; cwd = mkpath(joinpath(mktempdir(), "spinchat")))
        TK.send_message(z, "spin")
        got = TK.wait_for(z, "its eval worker's pid",
            "(() => { const m = $(body("lone-spin")).match(/SPIN_PID=(\\d+) MCP_PID=(\\d+)/); return m ? m[1] + ' ' + m[2] : false; })()";
            timeout = 300)
        old_pid[], mcp_pid = parse.(Int, split(got))

        # The worker dies, and the MCP with it, as an out-of-memory kill takes both.
        proc = z.h.worker_proc
        TK.kill_worker!(z)
        ccall(:kill, Cint, (Cint, Cint), mcp_pid, 9)
        @test timedwait(() -> !process_running(proc), 30) === :ok
        @test timedwait(() -> !BT.worker_connected(state, wid), 30) === :ok
        newproc, _ = BW.spawn_worker()
        @test newproc !== nothing
        z.h.worker_proc = newproc
        @test timedwait(() -> BT.worker_connected(state, wid), 180) === :ok

        TK.new_chat(z; cwd = mkpath(joinpath(mktempdir(), "checkchat")))
        TK.send_message(z, "check the old worker")
        @test TK.wait_for(z, "the eval worker the killed worker left is gone",
            "$(body("lone-check")).includes('OLD_ALIVE=false')"; timeout = 300) == true
    finally
        close(z)
    end
end
