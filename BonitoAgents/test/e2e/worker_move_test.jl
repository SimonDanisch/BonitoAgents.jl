# "Continue this chat on another worker", end to end through the real UI.
#
# A chat on worker A is moved to worker B from its header's ⋯ menu, and the
# move contract is asserted:
#   1. the item lists the OTHER online worker and moves the chat A → B,
#   2. files sync to B (server mirror == B's copy), including edits made on A
#      out of band,
#   3. `p.worker_id` / `p.worker_path` flip ATOMICALLY to B and the header shows
#      B's path,
#   4. the chat's storage follows the move (chats live under
#      `state_dir/chats/<pid>/`, not on the worker fs), so the same pane keeps
#      working — proven by re-sending a message that round-trips through B's
#      mock-agent and renders in the SAME chat pane,
#   5. the AGENT'S memory follows too: the mock keeps a Claude-shaped transcript
#      (`~/.mockacp/projects/<encoded cwd>/<sid>.jsonl`, plus a subagent folder
#      and a `memory/` dir seeded here) and, under `strict_load`, refuses
#      `session/load` unless the transcript sits under the cwd it is loaded in.
#      After the move the transcript sits under B's cwd with the recorded cwd
#      rewritten, the memory is merged, `resume_session_id` is KEPT, and nothing
#      is left in either worker's staging folder,
#   6. a chat whose record can't be carried (its transcript is gone) still
#      moves and continues with a fresh session: `resume_session_id` cleared,
#      the pane still live.
#
# ISOLATED, like cross_worker_test.jl: it spawns a SECOND worker and mutates
# worker assignment, so it gets its own throwaway `dev_server` + browser rather
# than polluting the shared soak server's worker set.
@testitem "e2e:worker_move" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT
    import AgentProviders

    # Echo agent: every prompt comes back as "echo: <prompt>" so a post-move
    # send proves the session is live on the new worker.
    agent_script(prompt) = [TK.text("echo: $(prompt)"), TK.end_turn()]

    # Collect every file under `dir` (relative path => contents) so we can assert
    # the server mirror and the worker copy are byte-identical, exactly like the
    # legacy `project_files` helper (skipping the legacy `.bonitoAgents` dir).
    project_files(dir) = begin
        out = Dict{String,String}()
        isdir(dir) || return out
        for (root, _, files) in walkdir(dir), f in files
            full = joinpath(root, f)
            rel  = relpath(full, dir)
            startswith(rel, ".bonitoAgents") && continue
            out[rel] = read(full, String)
        end
        out
    end

    # The mock's transcript layout — the same shape as Claude Code's, which is
    # what the worker's session transport moves (`AgentProviders.transcript_dir`).
    mock_fmt = AgentProviders.session_state_format(AgentProviders.MockAgent())
    transcript_dir(cwd) = AgentProviders.transcript_dir(mock_fmt, homedir(), cwd)
    seeded_dirs = String[]   # transcript dirs this test creates; removed at the end

    # Visible-pane helpers: several panes stay mounted, so scope to the live one.
    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    header_env = "(() => { const p=$VP; const e=p && p.querySelector('.bt-header-env'); return e ? (e.textContent||'').trim() : ''; })()"
    open_menu = "(() => { const p=$VP; const t=p && p.querySelector('.bt-header-menu .bt-menu-trigger'); if(!t) return false; t.click(); return true; })()"
    continue_items = "(() => { const p=$VP; return [...(p ? p.querySelectorAll('.bt-header-menu .bt-menu-continue') : [])].map(b => (b.textContent||'').trim()); })()"
    click_continue(name) = "(() => { const p=$VP; const b=[...p.querySelectorAll('.bt-header-menu .bt-menu-continue')]" *
        ".find(x => (x.textContent||'').trim() === $(repr(name))); if(!b) return false; b.click(); return true; })()"

    server = TK.dev_server(agent = agent_script, strict_load = true)
    try
        TK.open_browser(server)
        state = server.h.state

        @testset "Continue on worker B (A → B), memory carried" begin
            # ── Create a chat on worker A through the real UI ────────────────
            # The main dev worker is worker A, and the ONLY worker while the chat
            # is created: `new_chat` presses "+ Project" on a worker card, and
            # with two cards on the dashboard which one it lands on follows the
            # worker list's order. Worker B is spawned afterwards.
            # Seed a couple of files into the cwd so the move has real content to
            # sync (the legacy test seeded README/src/nested files on A's fs).
            @test TK.wait_for(server, "worker A online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
                timeout = 20) == true
            cwd = mktempdir()
            write(joinpath(cwd, "README.md"), "version 1: from A\n")
            write(joinpath(cwd, "src.jl"),    "const VERSION = \"a-initial\"\n")
            mkpath(joinpath(cwd, "deep"))
            write(joinpath(cwd, "deep", "nested.txt"), "hidden treasure\n")

            pid = TK.new_chat(server; cwd = cwd, title = "moveproj")
            @test !isempty(pid)
            @test haskey(state.projects[], pid)
            p = state.projects[][pid]
            worker_a_id = p.worker_id
            worker_a    = state.workers[][worker_a_id]

            # ── Spawn worker B: a SECOND real worker process, just like
            # cross_worker_test.jl — the move target. It shows up in the chat's
            # menu the moment it connects (the item list follows the worker list).
            worker_b_proc = TK.add_worker!(server; name = "worker-b")
            t0 = time()
            while time() - t0 < 30 &&
                  !any(w -> w.name == "worker-b" && w.online[], values(state.workers[]))
                sleep(0.1)
            end
            worker_b  = only(w for w in values(state.workers[]) if w.name == "worker-b")
            target_id = worker_b.worker_id
            @test worker_b.online[]
            @test worker_a_id != target_id

            # The chat works on A before the move (round-trips through A's agent).
            TK.send_message(server, "before-move")
            @test TK.wait_for(server, "A reply rendered",
                "(document.body.innerText || '').includes('echo: before-move')"; timeout = 60) == true

            # The agent bound a session the server can resume, and the mock wrote
            # its transcript under A's cwd — the record the move has to carry.
            t0 = time()
            while p.resume_session_id === nothing && time() - t0 < 30; sleep(0.1); end
            sid = p.resume_session_id
            @test sid !== nothing
            tdir_a = transcript_dir(cwd)
            push!(seeded_dirs, tdir_a)
            @test isfile(joinpath(tdir_a, sid * ".jsonl"))
            @test occursin("\"cwd\":" * BT.JSON.json(cwd), read(joinpath(tdir_a, sid * ".jsonl"), String))
            # Subagent transcripts and project memory travel with the session.
            mkpath(joinpath(tdir_a, sid))
            write(joinpath(tdir_a, sid, "sub.jsonl"), "{\"type\":\"user\",\"cwd\":" * BT.JSON.json(cwd) * "}\n")
            mkpath(joinpath(tdir_a, "memory"))
            write(joinpath(tdir_a, "memory", "MEMORY.md"), "- remember the treasure\n")

            # Capture the chat-storage dir: it lives under the SERVER's state_dir,
            # NOT on any worker, which is WHY the chat survives the move without
            # file sync. Assert it exists before AND after. (Persistence lags the
            # rendered reply slightly, so poll briefly for the dir to appear.)
            chat_dir = joinpath(server.h.state_dir, "chats", pid)
            dir_appears(d) = begin
                t0 = time(); while !isdir(d) && time() - t0 < 15; sleep(0.1); end; isdir(d)
            end
            @test dir_appears(chat_dir)

            # Snapshot the pre-move pane identity so we can prove the SAME chat
            # (same project id) is still the one open after the move.
            @test TK.current_chat_id(server) == pid

            # ── Out-of-band edit on A, then MOVE A → B through the menu ───────
            # Mirror the legacy test: the user edits files on A's fs in their own
            # editor (server doesn't know yet); the move must pre-pull these.
            proj_dir_a = p.worker_path
            @test rstrip(proj_dir_a, '/') == rstrip(cwd, '/')
            write(joinpath(proj_dir_a, "README.md"),  "version 2: edited on A out of band\n")
            write(joinpath(proj_dir_a, "newfile.txt"), "added on A\n")

            @test TK.eval_js(server, open_menu) == true
            @test TK.wait_for(server, "the menu offers worker-b under Continue on",
                "$(continue_items).includes('worker-b')"; timeout = 30) == true
            # Only OTHER workers are offered — never the one the chat is on.
            @test TK.eval_js(server, continue_items) == ["worker-b"]
            @test TK.eval_js(server, click_continue("worker-b")) == true

            # The header shows B's path once the chat is re-bound and rebuilt.
            proj_dir_b_expected = BT.worker_join(worker_b.projects_root, p.name)
            @test TK.wait_for(server, "header shows the chat on B",
                "$(header_env) === $(TK.json(replace(proj_dir_b_expected, homedir() => "~")))";
                timeout = 120) == true

            # ── Atomic flip of worker_id / worker_path ───────────────────────
            @test p.worker_id == target_id
            @test startswith(p.worker_path, worker_b.projects_root)
            proj_dir_b = p.worker_path
            @test proj_dir_b != proj_dir_a

            # ── Files synced to B (incl. the out-of-band edits) ──────────────
            @test isfile(joinpath(proj_dir_b, "README.md"))
            @test read(joinpath(proj_dir_b, "README.md"), String) ==
                  "version 2: edited on A out of band\n"
            @test read(joinpath(proj_dir_b, "newfile.txt"), String) == "added on A\n"
            @test read(joinpath(proj_dir_b, "deep", "nested.txt"), String) ==
                  "hidden treasure\n"
            # Server mirror is byte-identical to B's copy (full directory match).
            @test project_files(p.server_path) == project_files(proj_dir_b)

            # ── The agent's memory followed ──────────────────────────────────
            # The transcript now sits under B's cwd, naming B's cwd; the
            # subagent folder and the memory came along; the session id is kept
            # so B's agent LOADS it (strict_load makes a missing transcript a
            # failed load, which would have cleared the id).
            @test p.resume_session_id == sid
            tdir_b = transcript_dir(proj_dir_b)
            push!(seeded_dirs, tdir_b)
            @test isfile(joinpath(tdir_b, sid * ".jsonl"))
            moved = read(joinpath(tdir_b, sid * ".jsonl"), String)
            @test occursin("\"cwd\":" * BT.JSON.json(proj_dir_b), moved)
            @test !occursin(BT.JSON.json(cwd), moved)
            @test read(joinpath(tdir_b, sid, "sub.jsonl"), String) ==
                  "{\"type\":\"user\",\"cwd\":" * BT.JSON.json(proj_dir_b) * "}\n"
            @test read(joinpath(tdir_b, "memory", "MEMORY.md"), String) == "- remember the treasure\n"
            # Nothing left behind: no transfer folder on either worker, no
            # server copy.
            @test !ispath(joinpath(worker_a.projects_root, AgentProviders.TRANSFER_DIRNAME))
            @test !ispath(joinpath(worker_b.projects_root, AgentProviders.TRANSFER_DIRNAME))
            @test !ispath(joinpath(server.h.state_dir, "transfers", pid))

            # ── Chat storage followed the move ───────────────────────────────
            # The chat dir is the SAME server-side dir as before the move (it was
            # never on a worker), so history is intact across the relocation.
            @test isdir(chat_dir)

            # ── DOM: the same chat is still open and live on the new worker ───
            @test TK.current_chat_id(server) == pid
            @test TK.wait_for(server, "chat pane live after move",
                "!!document.querySelector('.bt-chatpane') && !!document.querySelector('.bt-text-input')";
                timeout = 30) == true

            # ── Re-send on the new worker proves storage + session followed ──
            # This prompt round-trips through B's mock-agent — which LOADED the
            # moved transcript — and must render in the SAME pane as the
            # pre-move reply.
            TK.send_message(server, "after-move")
            @test TK.wait_for(server, "B reply rendered",
                "(document.body.innerText || '').includes('echo: after-move')"; timeout = 60) == true
            # The pre-move message is STILL in the pane — history survived the move.
            @test TK.eval_js(server,
                "(document.body.innerText || '').includes('echo: before-move')") == true
            # …and the session was loaded, not replaced: the id did not rotate.
            @test p.resume_session_id == sid

            # ── A chat whose record can't be carried still moves ─────────────
            # Its transcript is gone (pruned, another agent's): the move goes on,
            # the agent starts fresh on the other worker, the pane keeps working.
            # With two workers up, which card `new_chat` lands on follows the
            # worker list's order — so the target is "whichever worker the chat
            # is NOT on", found after the fact.
            cwd2 = mktempdir()
            write(joinpath(cwd2, "note.txt"), "second chat\n")
            pid2 = TK.new_chat(server; cwd = cwd2, title = "movefresh")
            p2 = state.projects[][pid2]
            other = only(w for w in values(state.workers[]) if w.online[] && w.worker_id != p2.worker_id)
            TK.send_message(server, "second-before")
            @test TK.wait_for(server, "second chat replied",
                "(document.body.innerText || '').includes('echo: second-before')"; timeout = 60) == true
            t0 = time()
            while p2.resume_session_id === nothing && time() - t0 < 30; sleep(0.1); end
            sid2 = p2.resume_session_id
            @test sid2 !== nothing
            tdir2 = transcript_dir(p2.worker_path)
            push!(seeded_dirs, tdir2)
            rm(joinpath(tdir2, sid2 * ".jsonl"); force = true)

            @test TK.eval_js(server, open_menu) == true
            @test TK.wait_for(server, "the menu offers the other worker",
                "$(continue_items).includes($(repr(other.name)))"; timeout = 30) == true
            @test TK.eval_js(server, click_continue(other.name)) == true
            proj_dir_b2 = BT.worker_join(other.projects_root, p2.name)
            @test TK.wait_for(server, "second chat shows the other worker's path",
                "$(header_env) === $(TK.json(replace(proj_dir_b2, homedir() => "~")))";
                timeout = 120) == true
            @test p2.worker_id == other.worker_id
            @test read(joinpath(p2.worker_path, "note.txt"), String) == "second chat\n"
            push!(seeded_dirs, transcript_dir(p2.worker_path))
            TK.send_message(server, "second-after")
            @test TK.wait_for(server, "second chat replied on B",
                "(document.body.innerText || '').includes('echo: second-after')"; timeout = 60) == true
            # Fresh session on B: the id the mock hands out for a NEW session is
            # what is recorded now — not the one whose transcript was gone.
            @test p2.resume_session_id !== nothing

            kill(worker_b_proc)
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
        for d in seeded_dirs
            rm(d; recursive = true, force = true)
        end
    end
end
