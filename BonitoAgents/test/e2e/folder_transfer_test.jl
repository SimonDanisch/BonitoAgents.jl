@testitem "e2e:folder_transfer" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    using SHA, Random
    real_call(tool; kw...) = TK.mcp_call(tool; real_process = true, kw...)
    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
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
        worker_proc = TK.add_worker!(server; name = "transfer-target")
        TK.to_dashboard(server)
        @test TK.wait_for(server, "destination worker listed",
            "[...document.querySelectorAll('.bt-card-name')].some(e => (e.value || e.textContent) === 'transfer-target')";
            timeout = 30)
        TK.open_chat(server, pid)
        menu = "$VP?.querySelector('.bt-header-menu')"
        @test TK.eval_js(server, "$menu.querySelector('.bt-menu-trigger').click(); true")
        @test TK.wait_for(server, "remote menu open", "$menu.classList.contains('bt-menu-open')")
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
            @test TK.wait_for(server, "sync completed", shows(id, "synced"); timeout = 120)
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
        # A receiver that cannot open its destination must never report success.
        bad_dst = joinpath(dst, "keep.txt", "impossible")
        server.agent_fn[] = _ -> [real_call("bt_sync_folder"; id = "folder-refused",
            src, dst = bad_dst, worker = "transfer-target"), TK.end_turn()]
        TK.send_message(server, "attempt invalid destination")
        @test TK.wait_for(server, "destination error visible",
            shows("folder-refused", "transfer failed"); timeout = 60)
    finally
        worker_proc === nothing || (process_running(worker_proc) && kill(worker_proc))
        close(server)
        rm(root; recursive = true, force = true)
    end
end
