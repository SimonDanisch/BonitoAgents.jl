@testitem "e2e:folder_transfer" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    using SHA, Random
    real_call(tool; kw...) = TK.mcp_call(tool; real_process = true, kw...)
    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    function shows(id, text)
        return """(() => {
            const c = $VP?.querySelector('.bt-tool-msg[data-msg-id*="$id"]');
            if (!c) return false;
            const status = c.querySelector('.bt-tool-status')?.textContent;
            if (status !== 'completed' && status !== 'failed') return false;
            const h = c.querySelector('.bt-tool-header');
            if (h && !c.dataset.probeExpanded) {
                c.dataset.probeExpanded = '1';
                if (h.dataset.expanded !== 'true') h.click();
                return false;
            }
            return (c.querySelector('.bt-tool-body')?.innerText || '').includes($(repr(text)));
        })()"""
    end
    server = TK.dev_server(agent = _ -> [TK.end_turn()])
    root = mktempdir()
    worker_proc = nothing
    try
        TK.open_browser(server)
        src = mkpath(joinpath(root, "source"))
        dst = mkpath(joinpath(root, "destination"))
        write(joinpath(dst, "keep.txt"), "destination only")
        write(joinpath(src, "large.bin"), rand(Xoshiro(42), UInt8, 20 * 1024 * 1024 + 17))
        for i in 1:256
            write(joinpath(src, "small-$i"), "file $i")
        end
        pid = TK.new_chat(server; cwd = src)
        job = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"] .bt-job-progress')"
        ring = "document.querySelector('.bt-side-item[data-project-id=\"$pid\"] .bt-job-icon')"
        worker_proc = TK.add_worker!(server; name = "transfer-target")
        TK.to_dashboard(server)
        @test TK.wait_for(server, "destination worker listed",
            "[...document.querySelectorAll('.bt-card-name')].some(e => (e.value || e.textContent) === 'transfer-target')";
            timeout = 30)
        TK.open_chat(server, pid)
        menu = "$VP?.querySelector('.bt-header-menu')"
        @test TK.eval_js(server, "$menu.querySelector('.bw-menu-trigger').click(); true")
        @test TK.wait_for(server, "remote menu open", "$menu.classList.contains('bw-menu-open')")
        @test TK.eval_js(server, "$menu.querySelector('.bt-header-remote').click(); true")
        @test TK.wait_for(server, "remote transfers enabled",
            "$menu.querySelector('.bt-header-remote').classList.contains('bt-cap-on')")

        for round in 1:3
            if round == 3
                # A size change forces an incremental patch on all platforms.
                open(io -> write(io, "changed"), joinpath(src, "large.bin"), "a")
            end
            digest = bytes2hex(open(sha256, joinpath(src, "large.bin")))
            id = "folder-sync-$round"
            server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id,
                src, dst, worker = "transfer-target"), TK.end_turn()]
            TK.send_message(server, "sync round $round")
            if round == 1
                @test TK.wait_for(server, "transfer progress in chat and sidebar",
                    "!$job.hidden && $job.dataset.status==='running' && !$ring.hidden && $ring.dataset.status==='running'";
                    timeout = 60)
            end
            @test TK.wait_for(server, "sync completed", shows(id, "synced"); timeout = 120)
            @test TK.wait_for(server, "confirmed transfer finishes progress",
                "$job.dataset.status==='completed' && $job.querySelector('.bt-job-percent').textContent==='100%' && $ring.dataset.status==='completed'")
            # Verification also travels through the real tool, then is read
            # from its rendered output. No server/worker internals as oracle.
            code = """
                using SHA
                d = $(repr(dst))
                ok = bytes2hex(open(sha256, joinpath(d, "large.bin"))) == $(repr(digest)) &&
                    all(i -> read(joinpath(d, "small-\$i"), String) == "file \$i", 1:256) &&
                    read(joinpath(d, "keep.txt"), String) == "destination only"
                ok ? "TRANSFER VERIFIED $round" : error("transfer content mismatch")
            """
            server.agent_fn[] = _ -> [TK.bt_eval(code; real_process = true,
                worker = "transfer-target", env_path = normpath(joinpath(@__DIR__, "..", "evalenv")),
                id = "verify-$round"), TK.end_turn()]
            TK.send_message(server, "verify round $round")
            @test TK.wait_for(server, "destination contents verified",
                shows("verify-$round", "TRANSFER VERIFIED $round"); timeout = 240)
        end

        # Retrieve results without a second chat or a tool running on B. The
        # source is populated by a real remote eval; verification runs locally.
        digest = bytes2hex(open(sha256, joinpath(src, "large.bin")))
        pulled = mkpath(joinpath(root, "pulled"))
        write(joinpath(pulled, "keep-local.txt"), "local only")
        for round in 1:3
            code = """
                d = $(repr(dst))
                mkpath(joinpath(d, "nested"))
                write(joinpath(d, "nested", "result.txt"), $(repr("remote result $round")))
                "REMOTE RESULT READY $round"
            """
            server.agent_fn[] = _ -> [TK.bt_eval(code; real_process = true,
                worker = "transfer-target", env_path = normpath(joinpath(@__DIR__, "..", "evalenv")),
                id = "prepare-pull-$round"), TK.end_turn()]
            TK.send_message(server, "prepare remote result $round")
            @test TK.wait_for(server, "remote result ready",
                shows("prepare-pull-$round", "REMOTE RESULT READY $round"); timeout = 120)
            id = "folder-pull-$round"
            server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id,
                src = dst, dst = pulled, worker = "transfer-target", direction = "pull"), TK.end_turn()]
            TK.send_message(server, "pull result $round")
            @test TK.wait_for(server, "pull completed with correct endpoints",
                shows(id, "from $dst on transfer-target to $pulled on this worker"); timeout = 30,
                describe = "$VP.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')?.textContent")
            code = """
                using SHA
                d = $(repr(pulled))
                ok = bytes2hex(open(sha256, joinpath(d, "large.bin"))) == $(repr(digest)) &&
                    read(joinpath(d, "nested", "result.txt"), String) == $(repr("remote result $round")) &&
                    read(joinpath(d, "keep-local.txt"), String) == "local only"
                ok ? "PULL VERIFIED $round" : error("pull content mismatch")
            """
            server.agent_fn[] = _ -> [TK.bt_eval(code; real_process = true,
                env_path = normpath(joinpath(@__DIR__, "..", "evalenv")),
                id = "verify-pull-$round"), TK.end_turn()]
            TK.send_message(server, "verify local result $round")
            @test TK.wait_for(server, "pulled contents verified locally",
                shows("verify-pull-$round", "PULL VERIFIED $round"); timeout = 240)
        end
        TK.screenshot(server, joinpath(tempdir(), "bonitoagents-folder-pull.png"))

        # A single batch includes individual files and recursive folders, in
        # either direction, without transferring siblings outside the selection.
        for direction in ("push", "pull")
            batch = joinpath(root, "batch-$direction")
            id = "batch-$direction"
            server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id,
                src = dst, dst = batch, worker = "transfer-target", direction,
                paths = ["small-1", "nested", "nested/result.txt"]), TK.end_turn()]
            TK.send_message(server, "batch $direction")
            @test TK.wait_for(server, "batch transfer completed", shows(id, "synced 2 files"); timeout = 120)
            code = """
                d = $(repr(batch))
                ok = read(joinpath(d, "small-1"), String) == "file 1" &&
                    read(joinpath(d, "nested", "result.txt"), String) == "remote result 3" &&
                    !isfile(joinpath(d, "large.bin")) && !isfile(joinpath(d, "small-2"))
                ok ? "BATCH VERIFIED $direction" : error("batch selection mismatch")
            """
            verification = direction == "push" ? (; worker = "transfer-target") : (;)
            server.agent_fn[] = _ -> [TK.bt_eval(code; real_process = true, verification...,
                env_path = normpath(joinpath(@__DIR__, "..", "evalenv")),
                id = "verify-batch-$direction"), TK.end_turn()]
            TK.send_message(server, "verify batch $direction")
            @test TK.wait_for(server, "only selected files arrived",
                shows("verify-batch-$direction", "BATCH VERIFIED $direction"); timeout = 120)
        end
        TK.reload!(server)
        @test TK.wait_for(server, "sync completion survives reload",
            "$job?.dataset.status==='completed' && $ring?.dataset.status==='completed'"; timeout = 30)

        # Pull failures use the same visible error path and permission switch.
        for (id, args, expected) in (
            ("pull-refused", (; src = dst, dst = joinpath(pulled, "keep-local.txt", "impossible")), "transfer failed"),
            ("pull-missing", (; src = joinpath(root, "missing"), dst = pulled), "transfer failed"),
        )
            server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id,
                args..., worker = "transfer-target", direction = "pull"), TK.end_turn()]
            TK.send_message(server, "attempt $id")
            @test TK.wait_for(server, "pull error visible", shows(id, expected); timeout = 60)
            @test TK.wait_for(server, "failed transfer progress retained",
                "$job.dataset.status==='failed' && $ring.dataset.status==='failed'")
        end
        # A receiver that cannot open its destination must never report success.
        bad_dst = joinpath(dst, "keep.txt", "impossible")
        server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id = "folder-refused",
            src, dst = bad_dst, worker = "transfer-target"), TK.end_turn()]
        TK.send_message(server, "attempt invalid destination")
        @test TK.wait_for(server, "destination error visible",
            shows("folder-refused", "transfer failed"); timeout = 60)

        @test TK.eval_js(server, "$menu.querySelector('.bw-menu-trigger').click(); true")
        @test TK.wait_for(server, "remote menu reopened", "$menu.classList.contains('bw-menu-open')")
        @test TK.eval_js(server, "$menu.querySelector('.bt-header-remote').click(); true")
        @test TK.wait_for(server, "remote transfers disabled",
            "!$menu.querySelector('.bt-header-remote').classList.contains('bt-cap-on')")
        server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id = "pull-off",
            src = dst, dst = pulled, worker = "transfer-target", direction = "pull"), TK.end_turn()]
        TK.send_message(server, "attempt pull while disabled")
        @test TK.wait_for(server, "pull permission error visible",
            shows("pull-off", "switched OFF"); timeout = 60)
    finally
        worker_proc === nothing || (process_running(worker_proc) && kill(worker_proc))
        close(server)
        rm(root; recursive = true, force = true)
    end
end
