# Black-box port of the legacy `test/electron/test_cross_worker_sync_ui.jl`.
#
# Drives the cross-worker SYNC MODAL entirely through the real DOM on a real
# `dev_server` with TWO real worker processes. We register the SAME-NAMED
# project on both workers (so `same_name_siblings` fires), which is the only
# condition under which the chat header surfaces the cross-worker "⇄ <worker>"
# control. Clicking it inspects both sides (`compare_projects`) and opens the
# comparison modal (`render_sync_modal`); we assert the modal renders with the
# two side panels + three direction buttons, names both workers, then exercise
# Cancel and a direction pick.
#
# ISOLATED (own dev_server + add_worker!, like cross_worker_test.jl): it needs a
# clean 2-worker setup whose two same-named sibling projects don't perturb a
# shared soak server.
#
# How the same-named-sibling setup is done BLACK-BOX (the legacy test poked
# `state.projects[]` directly; we can't): both projects are created through the
# real per-worker-card "+ Project" picker. There is no worker `<select>` anymore
# — each worker has its OWN card and its OWN picker — so we target a card by the
# worker NAME it displays (`.bt-card-name`). Same-name siblings require the two
# FOLDERS to share a basename (the picker names a project after its folder), so
# each worker gets a folder literally named `PROJNAME`. Same `name` on two
# different workers ⇒ `same_name_siblings` returns the sibling and the ⇄
# control appears. This is fully real: `create_project_from_worker!` registers
# the picked WORKER folder on each worker, so the live `inspect_project` the
# modal calls has real content to summarise on both sides.

@testitem "e2e:cross_worker_sync_ui" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    using Test

    # Two real workers with KNOWN names so we can assert the ⇄ label.
    MAIN_WORKER = "worker-main"
    OTHER_WORKER = "worker-2"
    # Same display name on both workers ⇒ they are same-name siblings.
    PROJNAME = "SyncProj"

    agent_script(_p) = [TK.text("hi")]

    server = TK.dev_server(agent = agent_script, name = MAIN_WORKER)
    try
        TK.open_browser(server)

        # Both workers must be online before we open their card pickers (each
        # card and its "+ Project" form is built from `state.workers`).
        @test TK.wait_for(server, "main worker online",
            "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
            timeout = 20) == true
        w2 = TK.add_worker!(server; name = OTHER_WORKER)
        @test TK.wait_for(server, "two workers online",
            "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) === 2; })()";
            timeout = 30) == true

        # --- helper: open the "+ Project" picker on the card showing worker
        # `worker_name` (each worker has its own card; `picker_state` toggles,
        # so click once, check, retry).
        function open_card_picker_for!(s, worker_name)
            card_scope = """[...document.querySelectorAll('.bt-worker-cell')]
                .find(c => { const n = c.querySelector('.bt-card-name');
                             return n && (n.value || '').trim() === $(TK.json(worker_name)); })"""
            open_js = "(() => { const c = $card_scope; if (!c) return false; " *
                "return [...c.querySelectorAll('.bt-picker-path')].some(e => e && e.offsetParent); })()"
            click_js = """(() => { const c = $card_scope; if (!c) return false;
                const b = [...c.querySelectorAll('button')]
                    .find(b => b.offsetParent && (b.innerText || '').trim() === '+ Project');
                if (!b) return false; b.click(); return true; })()"""
            for _ in 1:5
                TK.eval_js(s, open_js) === true && return true
                TK.eval_js(s, click_js) === true || return false
                for _ in 1:30                     # ~6s for the notify round-trip
                    TK.eval_js(s, open_js) === true && return true
                    sleep(0.2)
                end
            end
            return false
        end

        # --- helper: create a project named `PROJNAME` (folder basename) on the
        # worker whose card shows `worker_name`. Drives the real "+ Project"
        # picker (path field + Create), targeting that specific worker's card.
        # Returns the new project id (read from the now-active sidebar entry).
        function create_on_worker(s, worker_name, src_dir)
            TK.to_dashboard(s)
            TK.wait_for(s, "worker card for $worker_name on screen",
                """(() => [...document.querySelectorAll('.bt-card-name')]
                    .some(n => n && (n.value || '').trim() === $(TK.json(worker_name))))()""";
                timeout = 30)
            open_card_picker_for!(s, worker_name) ||
                error("create_on_worker: could not open picker on $worker_name")
            # The path field IS the selection. `src_dir` already exists (both
            # sides were populated above); Create resolves it and registers the
            # project. The basename (`PROJNAME`) is the shared sibling name.
            TK.set_input(s, ".bt-picker-path", src_dir)
            TK.click_text(s, "Create")
            # Chat view renders after the ACP session binds (mock-agent cold
            # start can take a while) and the new chat becomes the active row.
            TK.wait_for(s, "chat view opened",
                "!!document.querySelector('.bt-text-input') && !!document.querySelector('.bt-chatpane')";
                timeout = 90)
            TK.wait_for(s, "new chat selected",
                "(() => { const a=document.querySelector('.bt-side-item.bt-side-active'); return !!a && !!(a.getAttribute('data-project-id')); })()";
                timeout = 90)
            sleep(0.5)
            return TK.current_chat_id(s)
        end

        # Same-named sibling FOLDERS on both sides: the picker names a project
        # after its folder's basename, so `same_name_siblings` only fires when
        # the basenames match. Distinct content (the modal summarizes reality).
        src1 = joinpath(mktempdir(), PROJNAME); mkpath(src1)
        write(joinpath(src1, "README.md"), "FROM main\n"); write(joinpath(src1, "one.txt"), "1\n")
        src2 = joinpath(mktempdir(), PROJNAME); mkpath(src2)
        write(joinpath(src2, "README.md"), "FROM w-2\n"); write(joinpath(src2, "two.txt"), "2\n")

        @testset "BonitoAgents cross-worker sync UI" begin
            # Create the same-named project on each worker (by card name).
            pid_main = create_on_worker(server, MAIN_WORKER, src1)
            pid_other = create_on_worker(server, OTHER_WORKER, src2)
            @test pid_main != pid_other

            # The ⇄ sibling-sync control is computed ONCE at chat-mount
            # (`same_name_siblings` is read when the header builds — chat.jl:3953,
            # "re-navigating refreshes it"), so it appears on the project whose
            # header was built AFTER its sibling already existed — here `pid_other`
            # (created second). Drive the ⇄ from that side; it names the sibling's
            # worker (MAIN_WORKER). (`pid_main`, built first with no sibling, keeps
            # a cached header without the ⇄ — that's the documented behavior.)
            TK.open_chat(server, pid_other)
            TK.wait_for(server, "chat input live", "!!document.querySelector('.bt-text-input')"; timeout = 15)

            @testset "⇄ control present because a sibling exists" begin
                # The sibling-bearing chat shows a cross-worker ⇄ button (alongside
                # the plain per-project Sync). `.bt-header-sync` is NOT pane-scoped
                # by the test shim and every open pane renders its own header, so
                # assert on the ⇄ specifically, not a global button count.
                @test TK.wait_for(server, "⇄ sibling-sync button present",
                    "[...document.querySelectorAll('.bt-header-sync')].some(b => (b.innerText||'').includes('⇄'))";
                    timeout = 15) == true
                # The ⇄ names the SIBLING's worker (the other side of the sync).
                names_sibling = TK.eval_js(server,
                    "[...document.querySelectorAll('.bt-header-sync')].some(b => { const t=(b.innerText||''); return t.includes('⇄') && t.includes($(TK.json(MAIN_WORKER))); })")
                @test names_sibling === true
            end

            @testset "clicking ⇄ opens the comparison modal" begin
                TK.eval_js(server, """(() => { const b = [...document.querySelectorAll('.bt-header-sync')]
                    .find(x => (x.innerText||'').includes('⇄')); if (b) b.click(); })()""")
                @test TK.wait_for(server, "modal overlay appears",
                    "document.querySelector('.bt-collision-overlay') !== null"; timeout = 20) == true
                @test TK.wait_for(server, "two side panels",
                    "document.querySelectorAll('.bt-collision-side').length === 2"; timeout = 10) == true
                @test TK.eval_js(server,
                    "document.querySelectorAll('.bt-collision-actions button').length") == 3
                title = TK.eval_js(server,
                    "(() => { const h = document.querySelector('.bt-collision-card h3'); return h ? (h.innerText||'') : ''; })()")
                @test occursin(PROJNAME, String(title))
                card = TK.eval_js(server,
                    "(() => { const c = document.querySelector('.bt-collision-card'); return c ? (c.innerText||'') : ''; })()")
                @test occursin(MAIN_WORKER, String(card)) && occursin(OTHER_WORKER, String(card))
            end

            @testset "Cancel closes the modal" begin
                TK.click(server, ".bt-collision-actions .bt-btn-ghost")
                @test TK.wait_for(server, "overlay gone after Cancel",
                    "document.querySelector('.bt-collision-overlay') === null"; timeout = 15) == true
            end

            @testset "a direction button dismisses the modal" begin
                # Re-open, then click the primary (push) direction. With both
                # workers ONLINE the apply runs for real in a Task and closes the
                # modal; the click itself must not throw in the renderer.
                TK.eval_js(server, """(() => { const b = [...document.querySelectorAll('.bt-header-sync')]
                    .find(x => (x.innerText||'').includes('⇄')); if (b) b.click(); })()""")
                @test TK.wait_for(server, "modal reopened",
                    "document.querySelector('.bt-collision-overlay') !== null"; timeout = 20) == true
                TK.click(server, ".bt-collision-actions .bt-btn-primary")
                @test TK.wait_for(server, "overlay closes after a direction pick",
                    "document.querySelector('.bt-collision-overlay') === null"; timeout = 20) == true
            end
        end

        TK.screenshot(server, joinpath(tempdir(), "cross_worker_sync_ui.png"))

        @testset "No JS errors" begin
            @test isempty(TK.js_errors(server))
        end

        kill(w2)
    finally
        close(server)
    end
end
