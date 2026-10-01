# "Continue on <worker>", end to end through the real UI.
#
# A chat on worker A is continued on worker B from its header's ⋯ menu. That
# makes a NEW chat on B and leaves the original alone. It used to move the chat:
# its session stopped, it was re-bound to B and restarted there. A move that
# took a while left the user chatting in a chat that was about to change
# machines, and afterwards it ran on B while tools it had started on A ran on.
#
# The contract:
#   1. the item lists the OTHER online worker; picking it opens a new chat on B,
#      with the same title, and the window moves to it,
#   2. the original chat is untouched: still on A, its session alive, and it
#      keeps working,
#   3. B gets the project's files, including edits made on A out of band, and
#      keeps whatever was there already (the push adds),
#   4. the AGENT'S memory comes along: the mock keeps a Claude-shaped transcript
#      (`~/.mockacp/projects/<encoded cwd>/<sid>.jsonl`, plus a subagent folder
#      and a `memory/` dir seeded here) and, under `strict_load`, refuses
#      `session/load` unless the transcript sits under the cwd it is loaded in.
#      The new chat resumes that session on B and shows the conversation,
#   5. a chat whose record can't be carried (its transcript is gone) still
#      continues, with a fresh session,
#   6. with the source worker offline, only a mirror that was synced is pushed,
#      and one never synced is refused before anything happens.
#
# ISOLATED, like cross_worker_test.jl: it spawns more workers and kills them, so
# it gets its own throwaway `dev_server` + browser.
@testitem "e2e:worker_move" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT
    const AgentProviders = BT.AgentProviders

    # Echo agent: every prompt comes back as "echo: <prompt>".
    agent_script(prompt) = [TK.text("echo: $(prompt)"), TK.end_turn()]

    # Every file under `dir` (relative path => contents).
    project_files(dir) = begin
        out = Dict{String,String}()
        isdir(dir) || return out
        for (root, _, files) in walkdir(dir), f in files
            full = joinpath(root, f)
            out[relpath(full, dir)] = read(full, String)
        end
        out
    end

    # The mock's transcript layout: the same shape as Claude Code's, which is what
    # the worker's session transport moves (`AgentProviders.transcript_dir`).
    mock_fmt = AgentProviders.session_state_format(AgentProviders.MockAgent())
    transcript_dir(cwd) = AgentProviders.transcript_dir(mock_fmt, homedir(), cwd)
    seeded_dirs = String[]   # transcript dirs this test creates; removed at the end

    # Several panes stay mounted: scope to the visible one.
    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    header_env = "(() => { const p=$VP; const e=p && p.querySelector('.bt-header-env'); return e ? (e.textContent||'').trim() : ''; })()"
    pane_text = "(() => { const p=$VP; return p ? (p.innerText || '') : ''; })()"
    open_menu = "(() => { const p=$VP; const t=p && p.querySelector('.bt-header-menu .bt-menu-trigger'); if(!t) return false; t.click(); return true; })()"
    continue_items = "(() => { const p=$VP; return [...(p ? p.querySelectorAll('.bt-header-menu .bt-menu-continue') : [])].map(b => (b.textContent||'').trim()); })()"
    click_continue(name) = "(() => { const p=$VP; const b=[...p.querySelectorAll('.bt-header-menu .bt-menu-continue')]" *
        ".find(x => (x.textContent||'').trim() === $(repr(name))); if(!b) return false; b.click(); return true; })()"
    card_done(text) = """(() => { const c = document.querySelector('.bt-prog.bt-prog-ok');
        return !!c && (c.querySelector('.bt-prog-title')?.textContent || '').includes($(repr(text))); })()"""
    wait_online(state, name) = begin
        t0 = time()
        while time() - t0 < 30 && !any(w -> w.name == name && w.online[], values(state.workers[]))
            sleep(0.1)
        end
        only(w for w in values(state.workers[]) if w.name == name)
    end
    # The chats on `wid` other than `known`: what a continue made.
    new_chats(state, wid, known) = [q for q in values(state.projects[]) if q.worker_id == wid && !(q.id in known)]

    server = TK.dev_server(agent = agent_script, strict_load = true)
    try
        TK.open_browser(server)
        state = server.h.state

        @testset "Continue on worker B: a new chat there, the original stays on A" begin
            # ── A chat on worker A, created through the real UI ──────────────
            # A is the only worker while it is created: `new_chat` presses
            # "+ Project" on a card, and with two cards which one follows the
            # worker list's order.
            @test TK.wait_for(server, "worker A online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
                timeout = 20) == true
            cwd = mktempdir()
            write(joinpath(cwd, "README.md"), "version 1: from A\n")
            write(joinpath(cwd, "src.jl"),    "const VERSION = \"a-initial\"\n")
            mkpath(joinpath(cwd, "deep"))
            write(joinpath(cwd, "deep", "nested.txt"), "hidden treasure\n")

            pid = TK.new_chat(server; cwd = cwd, title = "moveproj")
            @test haskey(state.projects[], pid)
            p = state.projects[][pid]
            worker_a_id = p.worker_id
            worker_a    = state.workers[][worker_a_id]

            worker_b_proc = TK.add_worker!(server; name = "worker-b")
            worker_b  = wait_online(state, "worker-b")
            target_id = worker_b.worker_id
            @test worker_b.online[]
            # Something already lives where the new chat will land. The push adds
            # the project's files there; it must never delete what it did not
            # bring (a move once emptied a live folder this way, 2026-09-15).
            proj_dir_b = BT.worker_join(worker_b.projects_root, p.name)
            mkpath(proj_dir_b)
            stray_on_b = joinpath(proj_dir_b, "already-here.txt")
            write(stray_on_b, "B had this before\n")

            TK.send_message(server, "before-move")
            @test TK.wait_for(server, "A reply rendered", "$(pane_text).includes('echo: before-move')"; timeout = 60) == true

            # The agent bound a session the server can resume, and the mock wrote
            # its transcript under A's cwd: the record the new chat needs.
            t0 = time()
            while p.resume_session_id === nothing && time() - t0 < 30; sleep(0.1); end
            sid = p.resume_session_id
            @test sid !== nothing
            tdir_a = transcript_dir(cwd)
            push!(seeded_dirs, tdir_a)
            @test isfile(joinpath(tdir_a, sid * ".jsonl"))
            mkpath(joinpath(tdir_a, sid))
            write(joinpath(tdir_a, sid, "sub.jsonl"), "{\"type\":\"user\",\"cwd\":" * BT.JSON.json(cwd) * "}\n")
            mkpath(joinpath(tdir_a, "memory"))
            write(joinpath(tdir_a, "memory", "MEMORY.md"), "- remember the treasure\n")
            # What B's agent re-streams when it LOADS the carried session: the
            # conversation, as a real agent's `session/load` does.
            TK.REPLAY_FN[] = s -> s == sid ? Any[TK.user("before-move"), TK.text("echo: before-move")] : Any[]

            # Edits on A the server does not know about yet: they must arrive.
            write(joinpath(cwd, "README.md"),  "version 2: edited on A out of band\n")
            write(joinpath(cwd, "newfile.txt"), "added on A\n")

            known = Set(keys(state.projects[]))
            @test TK.eval_js(server, open_menu) == true
            @test TK.wait_for(server, "the menu offers worker-b under Continue on",
                "$(continue_items).includes('worker-b')"; timeout = 30) == true
            @test TK.eval_js(server, continue_items) == ["worker-b"]   # never the chat's own worker
            @test TK.eval_js(server, click_continue("worker-b")) == true

            # ONE progress card for the whole of it, ending in DONE (a failure
            # parks it in `.bt-prog-err`, so "gone" would pass either way).
            @test TK.eval_js(server, "document.querySelectorAll('.bt-prog').length") == 1
            @test TK.wait_for(server, "the progress card reports the new chat",
                card_done("New chat on worker-b"); timeout = 120) == true
            # The card's width is fixed: sized to its content, it jumped with every
            # file path a copy showed. A very long path must not move it.
            @test TK.eval_js(server, """(() => {
                const c = document.querySelector('.bt-prog'), m = c.querySelector('.bt-prog-msg');
                const w = c.offsetWidth, t = m.textContent;
                m.textContent = '/a/very/long/path/that/goes/on'.repeat(30);
                const same = c.offsetWidth === w;
                m.textContent = t;
                return same; })()""") == true

            # ── A new chat on B, and the window on it ────────────────────────
            made = new_chats(state, target_id, known)
            @test length(made) == 1
            q = only(made)
            @test q.id != pid
            @test q.worker_path == proj_dir_b
            @test q.title[] == p.title[]
            @test TK.wait_for(server, "the window shows the new chat",
                "(document.querySelector('.bt-side-item.bt-side-active') || {}).dataset?.projectId === $(TK.json(q.id))";
                timeout = 60) == true
            @test TK.wait_for(server, "its header shows B's path",
                "$(header_env) === $(TK.json(replace(proj_dir_b, homedir() => "~")))"; timeout = 120) == true

            # ── The original is untouched ────────────────────────────────────
            @test p.worker_id == worker_a_id
            @test p.worker_path == cwd
            @test p.resume_session_id == sid
            @test haskey(state.chat_models, pid)                    # its session was never stopped

            # ── Files on B, incl. the out-of-band edits; B's own file kept ───
            @test read(joinpath(proj_dir_b, "README.md"), String) == "version 2: edited on A out of band\n"
            @test read(joinpath(proj_dir_b, "newfile.txt"), String) == "added on A\n"
            @test read(joinpath(proj_dir_b, "deep", "nested.txt"), String) == "hidden treasure\n"
            files_b = project_files(proj_dir_b)
            @test all(get(files_b, rel, nothing) == bytes for (rel, bytes) in project_files(p.server_path))
            @test read(stray_on_b, String) == "B had this before\n"

            # ── The agent's memory came along ────────────────────────────────
            @test q.resume_session_id == sid
            tdir_b = transcript_dir(proj_dir_b)
            push!(seeded_dirs, tdir_b)
            carried = read(joinpath(tdir_b, sid * ".jsonl"), String)
            @test occursin("\"cwd\":" * BT.JSON.json(proj_dir_b), carried)
            @test !occursin(BT.JSON.json(cwd), carried)
            @test read(joinpath(tdir_b, sid, "sub.jsonl"), String) ==
                  "{\"type\":\"user\",\"cwd\":" * BT.JSON.json(proj_dir_b) * "}\n"
            @test read(joinpath(tdir_b, "memory", "MEMORY.md"), String) == "- remember the treasure\n"
            # A's record is still where A's chat needs it.
            @test isfile(joinpath(tdir_a, sid * ".jsonl"))
            # Nothing left behind in either worker's staging folder, or on the server.
            @test !ispath(joinpath(worker_a.projects_root, AgentProviders.TRANSFER_DIRNAME))
            @test !ispath(joinpath(worker_b.projects_root, AgentProviders.TRANSFER_DIRNAME))
            @test !ispath(joinpath(server.h.state_dir, "transfers", pid))

            # ── The new chat resumed the conversation and goes on ────────────
            @test TK.wait_for(server, "the new chat shows the carried conversation",
                "$(pane_text).includes('echo: before-move')"; timeout = 60) == true
            TK.send_message(server, "after-move")
            @test TK.wait_for(server, "B reply rendered", "$(pane_text).includes('echo: after-move')"; timeout = 60) == true
            @test q.resume_session_id == sid                        # loaded, not replaced

            # ── …and so does the original, on A ──────────────────────────────
            TK.open_chat(server, pid)
            TK.send_message(server, "still-on-a")
            @test TK.wait_for(server, "A still answers", "$(pane_text).includes('echo: still-on-a')"; timeout = 60) == true
            @test p.worker_id == worker_a_id
            @test !occursin("echo: after-move", TK.eval_js(server, pane_text))

            # ── A chat whose record can't be carried still continues ─────────
            # Its transcript is gone: the new chat starts a fresh session.
            cwd2 = mktempdir()
            write(joinpath(cwd2, "note.txt"), "second chat\n")
            pid2 = TK.new_chat(server; cwd = cwd2, title = "movefresh")
            p2 = state.projects[][pid2]
            other = only(w for w in values(state.workers[]) if w.online[] && w.worker_id != p2.worker_id)
            TK.send_message(server, "second-before")
            @test TK.wait_for(server, "second chat replied", "$(pane_text).includes('echo: second-before')"; timeout = 60) == true
            t0 = time()
            while p2.resume_session_id === nothing && time() - t0 < 30; sleep(0.1); end
            sid2 = p2.resume_session_id
            @test sid2 !== nothing
            tdir2 = transcript_dir(p2.worker_path)
            push!(seeded_dirs, tdir2)
            rm(joinpath(tdir2, sid2 * ".jsonl"); force = true)

            known = Set(keys(state.projects[]))
            @test TK.eval_js(server, open_menu) == true
            @test TK.wait_for(server, "the menu offers the other worker",
                "$(continue_items).includes($(repr(other.name)))"; timeout = 30) == true
            @test TK.eval_js(server, click_continue(other.name)) == true
            @test TK.wait_for(server, "a fresh new chat", card_done("New chat on $(other.name)"); timeout = 120) == true
            q2 = only(new_chats(state, other.worker_id, known))
            @test q2.resume_session_id === nothing
            @test read(joinpath(q2.worker_path, "note.txt"), String) == "second chat\n"
            push!(seeded_dirs, transcript_dir(q2.worker_path))
            @test TK.wait_for(server, "the window shows the fresh chat",
                "$(header_env) === $(TK.json(replace(q2.worker_path, homedir() => "~")))"; timeout = 120) == true
            TK.send_message(server, "second-after")
            @test TK.wait_for(server, "the fresh chat answers", "$(pane_text).includes('echo: second-after')"; timeout = 60) == true
            @test q2.resume_session_id !== nothing
            @test p2.worker_id != other.worker_id && p2.resume_session_id == sid2   # the original as it was

        # With the source worker gone only the server's mirror can be pushed:
        # one that was never synced is refused before anything happens, one that
        # was synced (the continue above pulled A's files into it) is pushed.
        @testset "source worker offline, never synced: refused, nothing happens" begin
            TK.kill_worker!(worker_b_proc)            # B, where the new chat `q` lives
            t0 = time()
            while worker_b.online[] && time() - t0 < 30; sleep(0.1); end
            @test !worker_b.online[]
            @test q.last_sync_at === nothing          # a continued chat's mirror starts empty
            target_on_a = BT.worker_join(worker_a.projects_root, q.name)
            mkpath(target_on_a)
            before = readdir(target_on_a)
            known = Set(keys(state.projects[]))

            TK.open_chat(server, q.id)
            @test TK.eval_js(server, open_menu) == true
            @test TK.wait_for(server, "the menu offers worker A",
                "$(continue_items).includes($(repr(worker_a.name)))"; timeout = 30) == true
            @test TK.eval_js(server, click_continue(worker_a.name)) == true
            @test TK.wait_for(server, "refused, and says why",
                """(() => { const c = document.querySelector('.bt-prog.bt-prog-err');
                    return !!c && (c.innerText || '').includes('never synced'); })()"""; timeout = 120) == true
            @test Set(keys(state.projects[])) == known
            @test readdir(target_on_a) == before
            @test q.worker_id == target_id
        end

        @testset "source worker offline, synced mirror: a new chat from the mirror" begin
            worker_c_proc = TK.add_worker!(server; name = "worker-c")
            try
                worker_c = wait_online(state, "worker-c")
                @test p.last_sync_at !== nothing       # the first continue pulled A into it
                target_on_c = BT.worker_join(worker_c.projects_root, p.name)
                mkpath(target_on_c)
                stray_on_c = joinpath(target_on_c, "c-had-this.txt")
                write(stray_on_c, "C's own file\n")
                known = Set(keys(state.projects[]))

                TK.open_chat(server, pid)
                TK.kill_worker!(server)                # A, the original's worker, dies
                t0 = time()
                while worker_a.online[] && time() - t0 < 30; sleep(0.1); end
                @test !worker_a.online[]

                @test TK.eval_js(server, open_menu) == true
                @test TK.wait_for(server, "the menu offers worker C",
                    "$(continue_items).includes(\"worker-c\")"; timeout = 30) == true
                @test TK.eval_js(server, click_continue("worker-c")) == true
                @test TK.wait_for(server, "a new chat from the mirror", card_done("New chat on worker-c"); timeout = 120) == true
                q3 = only(new_chats(state, worker_c.worker_id, known))
                @test q3.worker_path == target_on_c
                @test read(joinpath(target_on_c, "README.md"), String) == "version 2: edited on A out of band\n"
                @test read(joinpath(target_on_c, "deep", "nested.txt"), String) == "hidden treasure\n"
                @test read(stray_on_c, String) == "C's own file\n"   # added, not mirrored
                @test p.worker_id == worker_a_id                      # the original still names A
            finally
                TK.kill_worker!(worker_c_proc)
            end
        end
        end   # the first testset, and its offline-source follow-ups

        @test isempty(TK.js_errors(server))
    finally
        TK.REPLAY_FN[] = sid -> Any[]
        close(server)
        for d in seeded_dirs
            rm(d; recursive = true, force = true)
        end
    end
end
