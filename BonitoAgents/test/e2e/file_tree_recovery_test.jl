# The sidebar's file tree after a listing failed. It used to cache the failure as
# an empty folder: a chat whose tree was opened while its worker was gone said
# "empty" for good, even after the worker was back (11-24, a laptop). Now the
# tree says why, offers a Retry, and lists the folder again by itself when the
# worker reconnects. Own dev server: its worker gets killed.
@testitem "e2e:file_tree_recovery" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TK
    import BonitoAgents as BT
    const BW = BT.BonitoWorker

    z = TK.dev_server()
    try
        TK.open_browser(z)
        state = z.h.state
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        wid = only(keys(state.workers[]))

        chat_js(pid) = "[...document.querySelectorAll('.bt-side-chat')].find(c => " *
                       "c.querySelector('.bt-side-item[data-project-id=\"$(pid)\"]'))"
        open_tree!(pid) = TK.eval_js(z, "(() => { const c = $(chat_js(pid)); const h = c?.querySelector('.bt-side-tree-hint'); " *
                                         "if (!h) return false; if (!c.classList.contains('bt-tree-open')) h.click(); return true; })()")
        labels_js(pid) = "[...(($(chat_js(pid)))?.querySelectorAll('.bt-tree-label') ?? [])].map(e => e.textContent)"
        failed_js(pid) = "[...(($(chat_js(pid)))?.querySelectorAll('.bt-tree-failed-why') ?? [])].map(e => e.textContent)"
        click_js(pid, sel) = "(() => { const r = ($(chat_js(pid)))?.querySelector($(TK.json(sel))); if (!r) return false; r.click(); return true; })()"
        hint_js(pid) = "!!(($(chat_js(pid)))?.querySelector('.bt-side-tree-hint'))"

        @testset "a tree opened while the worker is gone fills in when it is back" begin
            cwd = mktempdir()
            write(joinpath(cwd, "hello_from_tree.txt"), "hi\n")
            pid = TK.new_chat(z; cwd)
            @test TK.wait_for(z, "the chat's tree toggle", hint_js(pid); timeout = 30) == true

            proc = z.h.worker_proc
            TK.kill_worker!(z)
            @test timedwait(() -> !process_running(proc), 30) === :ok
            @test timedwait(() -> !BT.worker_connected(state, wid), 30) === :ok

            @test open_tree!(pid) == true
            # A request first waits `RECONNECT_WAIT_S` (20 s) for the link to come
            # back, then fails; the tree names the worker the way the sidebar does.
            name = state.workers[][wid].name
            @test TK.wait_for(z, "the tree says why it is not listed",
                              "$(failed_js(pid)).some(t => t === $(TK.json("Couldn't list this folder: $name is not connected")))";
                              timeout = 45) == true
            @test !TK.eval_js(z, "$(labels_js(pid)).includes('hello_from_tree.txt')")

            proc, _ = BW.spawn_worker()
            @test proc !== nothing
            z.h.worker_proc = proc
            @test timedwait(() -> BT.worker_connected(state, wid), 180) === :ok
            # No Retry: the reconnect lists it.
            @test TK.wait_for(z, "the folder listed once the worker is back",
                              "$(labels_js(pid)).includes('hello_from_tree.txt')"; timeout = 30) == true
            @test TK.eval_js(z, "$(failed_js(pid)).length") == 0
        end

        # A folder the worker cannot read: as root (or on Windows) every folder is
        # readable, so there is nothing to fail.
        if Sys.isunix() && ccall(:getuid, Cuint, ()) != 0
            @testset "a folder that cannot be listed says why, and Retry lists it" begin
                cwd = mktempdir()
                locked = mkpath(joinpath(cwd, "locked_dir"))
                write(joinpath(locked, "inside_locked.txt"), "x\n")
                chmod(locked, 0o000)
                try
                    pid = TK.new_chat(z; cwd)
                    @test TK.wait_for(z, "the chat's tree toggle", hint_js(pid); timeout = 30) == true
                    @test open_tree!(pid) == true
                    @test TK.wait_for(z, "root listed", "$(labels_js(pid)).includes('locked_dir')"; timeout = 20) == true
                    @test TK.eval_js(z, click_js(pid, ".bt-tree-dir[data-path\$=\"/locked_dir\"]")) == true
                    @test TK.wait_for(z, "the failure is shown, not an empty folder",
                                      "$(failed_js(pid)).some(t => t.startsWith(\"Couldn't list this folder\"))"; timeout = 15) == true
                    chmod(locked, 0o755)
                    @test TK.eval_js(z, click_js(pid, ".bt-tree-failed")) == true
                    @test TK.wait_for(z, "Retry lists it", "$(labels_js(pid)).includes('inside_locked.txt')"; timeout = 15) == true
                    @test TK.eval_js(z, "$(failed_js(pid)).length") == 0
                finally
                    chmod(locked, 0o755)
                end
            end
        end
    finally
        close(z)
    end
end
