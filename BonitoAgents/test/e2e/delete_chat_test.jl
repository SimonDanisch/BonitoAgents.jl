# "Delete chat", end to end through the real UI.
#
# The contract:
#   1. declining the confirmation changes nothing,
#   2. the chat's ⋯ menu deletes it for good: the window goes home, it's gone from
#      the sidebar and the overview, also after a reload, and its transcript, its
#      entry in projects.json, the agent's session on the worker and its shared
#      links are gone too,
#   3. what doesn't belong to that chat stays: the project's files, the project
#      memory, other sessions in the folder and other chats,
#   4. the overview card deletes too, without opening the chat,
#   5. with the worker offline it's refused and nothing changes, and the chat is
#      still there, still reachable.
#
# ISOLATED, like worker_move_test.jl: it kills a worker, so it gets its own
# throwaway `dev_server` + browser.
@testitem "e2e:delete_chat" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT
    const AgentProviders = BT.AgentProviders

    agent_script(prompt) = [TK.text("echo: $(prompt)"), TK.end_turn()]

    mock_fmt = AgentProviders.session_state_format(AgentProviders.MockAgent())
    transcript_dir(cwd) = AgentProviders.transcript_dir(mock_fmt, homedir(), cwd)
    seeded_dirs = String[]

    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    pane_text = "(() => { const p=$VP; return p ? (p.innerText || '') : ''; })()"
    open_menu = "(() => { const p=$VP; const t=p && p.querySelector('.bt-header-menu .bw-menu-trigger'); if(!t) return false; t.click(); return true; })()"
    click_delete = "(() => { const p=$VP; const b=p && p.querySelector('.bt-header-delete'); if(!b) return false; b.click(); return true; })()"
    in_sidebar(pid) = "[...document.querySelectorAll('.bt-side-item')].some(e => e.getAttribute('data-project-id') === $(repr(pid)))"
    card(pid) = "[...document.querySelectorAll('.bt-ov-card')].find(e => e.dataset.projectId === $(repr(pid)))"
    has_card(pid) = "!!$(card(pid))"
    click_card_delete(pid) = "(() => { const c=$(card(pid)); const b=c && c.querySelector('.bt-ov-delete'); if(!b) return false; b.click(); return true; })()"
    on_home = "!document.querySelector('.bt-chatpane[aria-hidden=false]')"
    modal = ".bw-modal-open .bt-delete-chat"
    function wait_modal(server)
        @test TK.wait_for(server, "delete options", "!!document.querySelector('$modal')"; timeout = 30)
    end
    function submit_delete(server)
        wait_modal(server)
        TK.real_click(server, "$modal .bt-delete-submit")
    end

    wait_session(p) = begin
        t0 = time()
        while p.resume_session_id === nothing && time() - t0 < 30; sleep(0.1); end
        p.resume_session_id
    end
    wait_online(state, name) = begin
        t0 = time()
        while time() - t0 < 30 && !any(w -> w.name == name && w.online[], values(state.workers[]))
            sleep(0.1)
        end
        only(w for w in values(state.workers[]) if w.name == name)
    end
    home!(server) = TK.eval_js(server, "(() => { const h=[...document.querySelectorAll('.bt-side-item')].find(e => (e.innerText||'').trim() === 'Home'); if(!h) return false; h.click(); return true; })()")

    # strict_load: the mock writes a real transcript per session, each with its own id.
    server = TK.dev_server(agent = agent_script, strict_load = true)
    try
        TK.open_browser(server)
        state = server.h.state
        chat_dir(pid) = joinpath(state.state_dir, "chats", pid)

        cwd = mktempdir()
        write(joinpath(cwd, "README.md"), "project file\n")
        pid = TK.new_chat(server; cwd = cwd, title = "deleteme")
        p = state.projects[][pid]
        TK.send_message(server, "first-chat")
        @test TK.wait_for(server, "reply", "$(pane_text).includes('echo: first-chat')"; timeout = 30) == true
        sid = wait_session(p)

        tdir = transcript_dir(p.worker_path)
        push!(seeded_dirs, tdir)
        mkpath(joinpath(tdir, sid))
        write(joinpath(tdir, sid, "sub.jsonl"), "{}\n")
        mkpath(joinpath(tdir, "memory"))
        write(joinpath(tdir, "memory", "MEMORY.md"), "- shared by the folder\n")
        write(joinpath(tdir, "someone-else.jsonl"), "{}\n")
        link = BT.share_project_file!(state, pid, joinpath(p.worker_path, "README.md"))

        @testset "declining changes nothing" begin
            @test TK.eval_js(server, open_menu) == true
            @test TK.eval_js(server, click_delete) == true
            wait_modal(server)
            @test TK.eval_js(server, "document.querySelector('$modal .bt-delete-session').checked")
            @test !TK.eval_js(server, "document.querySelector('$modal .bt-delete-memory').checked")
            @test TK.eval_js(server, "document.querySelector('$modal').innerText.includes('Project files stay')")
            TK.real_click(server, "$modal .bt-delete-cancel")
            @test TK.wait_for(server, "closed", "!document.querySelector('$modal')"; timeout = 30)
            @test TK.eval_js(server, "$(pane_text).includes('echo: first-chat')") == true
        end

        @testset "the ⋯ menu deletes for good, and only this chat" begin
            @test TK.eval_js(server, open_menu) == true
            @test TK.eval_js(server, click_delete) == true
            submit_delete(server)
            @test TK.wait_for(server, "back home", on_home; timeout = 30) == true
            @test TK.wait_for(server, "gone from the sidebar", "!($(in_sidebar(pid)))"; timeout = 30) == true
            @test TK.wait_for(server, "gone from the overview", "!($(has_card(pid)))"; timeout = 30) == true


            # And it stays gone: nothing wrote it back, and a fresh page agrees.
            sleep(2)
            TK.navigate(server, "/")
            @test TK.wait_for(server, "dashboard after a reload", "!!document.querySelector('.bt-overview')"; timeout = 30) == true
            @test TK.eval_js(server, "!($(in_sidebar(pid))) && !($(has_card(pid)))") == true
        end

        @testset "the overview card deletes without opening the chat" begin
            cwd2 = mktempdir()
            pid2 = TK.new_chat(server; cwd = cwd2, title = "cardchat")
            p2 = state.projects[][pid2]
            TK.send_message(server, "second-chat")
            @test TK.wait_for(server, "reply", "$(pane_text).includes('echo: second-chat')"; timeout = 30) == true
            sid2 = wait_session(p2)
            tdir2 = transcript_dir(p2.worker_path)
            push!(seeded_dirs, tdir2)

            cwd3 = mktempdir()
            pid3 = TK.new_chat(server; cwd = cwd3, title = "keptchat")
            TK.send_message(server, "third-chat")
            @test TK.wait_for(server, "reply", "$(pane_text).includes('echo: third-chat')"; timeout = 30) == true

            @test home!(server) == true
            @test TK.wait_for(server, "both cards", "$(has_card(pid2)) && $(has_card(pid3))"; timeout = 30) == true
            @test TK.eval_js(server, click_card_delete(pid2)) == true
            submit_delete(server)
            @test TK.wait_for(server, "the card goes", "!($(has_card(pid2)))"; timeout = 30) == true
            @test TK.eval_js(server, on_home) == true   # the click didn't open the chat
            @test TK.eval_js(server, has_card(pid3)) == true
        end

        @testset "wipe project memory while keeping the agent session" begin
            cwd4 = mktempdir()
            pid4 = TK.new_chat(server; cwd = cwd4, title = "memorychat")
            p4 = state.projects[][pid4]
            TK.send_message(server, "memory-chat")
            @test TK.wait_for(server, "reply", "$(pane_text).includes('echo: memory-chat')"; timeout = 30)
            sid4 = wait_session(p4)
            tdir4 = transcript_dir(p4.worker_path)
            push!(seeded_dirs, tdir4)
            mkpath(joinpath(tdir4, "memory", "nested"))
            write(joinpath(tdir4, "memory", "nested", "notes.md"), "shared memory")
            @test TK.eval_js(server, open_menu)
            @test TK.eval_js(server, click_delete)
            wait_modal(server)
            @test TK.eval_js(server, "getComputedStyle(document.querySelector('$modal')).display === 'flex'")
            TK.set_window_size(server, 390, 844)
            @test TK.wait_for(server, "phone dialog fits", "(() => { const r = document.querySelector('$modal').getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth; })()"; timeout = 15)
            TK.screenshot(server, "/tmp/bonitoagents-delete-options-mobile.png")
            TK.set_window_size(server, 1280, 820)
            TK.real_click(server, "$modal .bt-delete-session")
            TK.real_click(server, "$modal .bt-delete-memory")
            @test !TK.eval_js(server, "document.querySelector('$modal .bt-delete-session').checked")
            @test TK.eval_js(server, "document.querySelector('$modal .bt-delete-memory').checked")
            TK.screenshot(server, "/tmp/bonitoagents-delete-options.png")
            submit_delete(server)
            @test TK.wait_for(server, "back home", on_home; timeout = 30)
            @test TK.wait_for(server, "gone", "!($(has_card(pid4)))"; timeout = 30)
            # Read back via the real Julia tool, and assert on its displayed
            # result rather than server internals.
            TK.new_chat(server; cwd = mktempdir(), title = "verify-memory")
            code = """
                isfile($(repr(joinpath(tdir4, sid4 * ".jsonl")))) || error("session was removed")
                !ispath($(repr(joinpath(tdir4, "memory")))) || error("memory was kept")
                println(join(["MEMORY", "WIPED", "SESSION", "KEPT"], " "))
                nothing
            """
            server.agent_fn[] = _ -> [TK.bt_eval(code; real_process = true,
                env_path = normpath(joinpath(@__DIR__, "..", "evalenv")),
                id = "verify-deleted-memory"), TK.end_turn()]
            TK.send_message(server, "Check the saved session and project memory")
            tool = "$VP.querySelector('.bt-tool-msg[data-msg-id*=verify-deleted-memory]')"
            @test TK.wait_for(server, "verification finished", "$tool?.querySelector('.bt-tool-status')?.textContent === 'completed'"; timeout = 180)
            TK.eval_js(server, "(() => { const h = $tool.querySelector('.bt-tool-header'); if (h.dataset.expanded !== 'true') h.click(); return true; })()")
            @test TK.wait_for(server, "memory wiped and session kept", "$tool.querySelector('.bt-tool-body')?.innerText.includes('MEMORY WIPED SESSION KEPT')"; timeout = 30)
            server.agent_fn[] = agent_script
        end

        @testset "an offline worker refuses, and nothing changes" begin
            worker_b_proc = TK.add_worker!(server; name = "worker-b")
            worker_b = wait_online(state, "worker-b")
            cwd_b = mktempdir()
            pid_b = TK.new_chat(server; cwd = cwd_b, worker = "worker-b", title = "offlinechat")
            p_b = state.projects[][pid_b]
            TK.send_message(server, "on-b")
            @test TK.wait_for(server, "reply", "$(pane_text).includes('echo: on-b')"; timeout = 30) == true
            sid_b = wait_session(p_b)
            tdir_b = transcript_dir(p_b.worker_path)
            push!(seeded_dirs, tdir_b)

            @test home!(server) == true
            @test TK.wait_for(server, "the card", has_card(pid_b); timeout = 30) == true
            TK.kill_worker!(worker_b_proc)
            t0 = time()
            while worker_b.online[] && time() - t0 < 60; sleep(0.2); end

            @test TK.eval_js(server, click_card_delete(pid_b)) == true
            submit_delete(server)
            @test TK.wait_for(server, "told why", "document.querySelector('.bt-prog-err')?.innerText.includes('offline')"; timeout = 30)
            message = TK.eval_js(server, "document.querySelector('.bt-prog-err').innerText")
            @test occursin("worker-b is offline", message)
            @test occursin("Nothing changed", message)
            @test TK.eval_js(server, has_card(pid_b)) == true
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
        for d in seeded_dirs
            rm(d; recursive = true, force = true)
        end
    end
end
