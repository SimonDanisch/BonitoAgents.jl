# Black-box e2e port of the legacy `test/electron/test_worker_move.jl`.
#
# Moves a real project/chat from worker A to worker B and asserts the move
# contract the legacy test pinned:
#   1. cross-worker move A → B,
#   2. files sync to B (server mirror == B's copy),
#   3. `p.worker_id` / `p.worker_path` flip ATOMICALLY to B,
#   4. the chat's storage follows the move (chats live under
#      `state_dir/chats/<pid>/`, not on the worker fs), so the chat keeps
#      working on the new worker — proven by re-sending a message that
#      round-trips through B's mock-agent and renders in the SAME chat pane.
#
# ISOLATED, like cross_worker_test.jl: it spawns a SECOND worker and mutates
# worker assignment, so it gets its own throwaway `dev_server` + browser rather
# than polluting the shared soak server's worker set.
#
# ── Honest note on "drive the move through the real UI" ──────────────────────
# The legacy move CONTROL — the `ProjectCard`'s `.bt-open-on-select` "Open chat
# on <worker>" dropdown (see src/project_widget.jl) — is currently DEAD CODE:
# `ProjectCard` is never instantiated and the standalone dashboard project-card
# list was deleted (see src/dashboard.jl ~L2513-2520: "move-to-worker … is being
# redesigned. `ProjectCard` … `open_request` remain defined for the future
# move-to-worker redesign."). There is therefore NO `.bt-open-on-select` (or any
# other move trigger) in the live DOM to click black-box.
#
# So we drive the EXACT production code path that the (unmounted) UI handler
# would invoke — `BonitoAgents.start!(state, p, target)` (dashboard.jl's
# `open_request` handler calls precisely this; `start!` = `transfer_project!`
# atomic file-move + re-bind, then `ensure_project_session!`). Everything else
# stays black-box: the chat is CREATED through the real UI, and the post-move
# state is asserted through the rendered DOM + a real re-sent message.
# When the move UI is remounted, swap the single `start!` call below for a
# `click`/`switch` on `.bt-open-on-select` — the assertions stay.
@testitem "e2e:worker_move" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

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

    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        state = server.h.state

        @testset "BonitoAgents worker move (A → B)" begin
            # ── 2-worker setup ───────────────────────────────────────────────
            # The main dev worker is worker A (already online). Spawn a SECOND
            # real worker process = worker B, just like cross_worker_test.jl.
            @test TK.wait_for(server, "worker A online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
                timeout = 20) == true
            worker_b_proc = TK.add_worker!(server; name = "worker-b")
            @test TK.wait_for(server, "two workers online",
                "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*\\d+\\s*workers online/); return m && parseInt(m[1]) >= 2; })()";
                timeout = 30) == true

            # ── Create a chat on worker A through the real UI ────────────────
            # Seed a couple of files into the cwd so the move has real content to
            # sync (the legacy test seeded README/src/nested files on A's fs).
            cwd = mktempdir()
            write(joinpath(cwd, "README.md"), "version 1: from A\n")
            write(joinpath(cwd, "src.jl"),    "const VERSION = \"a-initial\"\n")
            mkpath(joinpath(cwd, "deep"))
            write(joinpath(cwd, "deep", "nested.txt"), "hidden treasure\n")

            pid = TK.new_chat(server; cwd = cwd, title = "moveproj")
            @test !isempty(pid)
            @test haskey(state.projects[], pid)
            p = state.projects[][pid]

            # Identify source (A) and an online target (B) by worker id. The
            # project's `worker_id` is the dict key of the worker it was created
            # on; pick a DIFFERENT online worker as the move target.
            worker_a_id = p.worker_id
            online_ids  = [w.worker_id for w in values(state.workers[]) if w.online[]]
            target_id   = first(filter(!=(worker_a_id), online_ids))
            worker_b    = state.workers[][target_id]
            worker_a    = state.workers[][worker_a_id]
            @test worker_a_id != target_id

            # The chat works on A before the move (round-trips through A's agent).
            TK.send_message(server, "before-move")
            @test TK.wait_for(server, "A reply rendered",
                "(document.body.innerText || '').includes('echo: before-move')"; timeout = 60) == true

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

            # ── Out-of-band edit on A, then MOVE A → B ───────────────────────
            # Mirror the legacy test: the user edits files on A's fs in their own
            # editor (server doesn't know yet); the move must pre-pull these.
            proj_dir_a = p.worker_path
            @test startswith(proj_dir_a, worker_a.projects_root)
            write(joinpath(proj_dir_a, "README.md"),  "version 2: edited on A out of band\n")
            write(joinpath(proj_dir_a, "newfile.txt"), "added on A\n")

            # Drive the move via the SAME production entrypoint the dashboard's
            # `open_request` handler calls (`start!` → atomic transfer + rebind +
            # session boot on the target). See the dead-UI note at the top.
            BT.start!(state, p, target_id)

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
            # This prompt round-trips through B's freshly-booted mock-agent and
            # must render in the SAME pane as the pre-move reply.
            TK.send_message(server, "after-move")
            @test TK.wait_for(server, "B reply rendered",
                "(document.body.innerText || '').includes('echo: after-move')"; timeout = 60) == true
            # The pre-move message is STILL in the pane — history survived the move.
            @test TK.eval_js(server,
                "(document.body.innerText || '').includes('echo: before-move')") == true

            kill(worker_b_proc)
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
