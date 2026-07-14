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
# real "+ New project" form. `new_chat` always targets the DEFAULT worker
# (`first(keys(state.workers))`), and offers no worker selector, so for the
# SECOND project we replicate the new-project flow inline and additionally drive
# the form's Worker `<select>` (rendered from `state.workers`, one <option> per
# worker, value = worker_id) to the OTHER worker before clicking Create. Same
# `name` + different worker_id ⇒ `same_name_siblings` returns the sibling and
# the ⇄ control appears. This is fully real: `create_project!` rsyncs the picked
# folder to the server mirror and pushes it onto each worker, so the live
# `inspect_project` the modal calls has real content to summarise on both sides.

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

        # Both workers must be online before we open the new-project form
        # (its Worker <select> is built from `state.workers` at form-build time).
        @test TK.wait_for(server, "main worker online",
            "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) >= 1; })()";
            timeout = 20) == true
        w2 = TK.add_worker!(server; name = OTHER_WORKER)
        @test TK.wait_for(server, "two workers online",
            "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) === 2; })()";
            timeout = 30) == true

        # --- helper: create a project named `PROJNAME` on `worker_id`, driving
        # the real "+ New project" form (path picker + Worker <select> + Create).
        # Mirrors TestKit.new_chat but adds explicit worker selection so the two
        # projects deterministically land on DIFFERENT workers. Returns the new
        # project id (read from the now-active sidebar entry).
        function create_on_worker(s, worker_id, src_dir)
            leaf = TK.json(basename(rstrip(src_dir, '/')))
            TK.to_dashboard(s)
            TK.click_text(s, "+ New project")
            TK.wait_for(s, "new-project form",
                "[...document.querySelectorAll('input')].some(e => e.offsetParent && (e.placeholder||'') === 'e.g. my-project')";
                timeout = 30)
            # Type the source folder into the breadcrumb address field.
            TK.click_until(s, ".bt-addr-icon-btn",
                "[...document.querySelectorAll('.bt-addr-input')].some(el => el && el.offsetParent !== null)";
                timeout = 30)
            ok = TK.eval_js(s, """(() => {
                const inp = [...document.querySelectorAll('.bt-addr-input')].filter(el => el && el.offsetParent !== null)[0];
                if (!inp) return false;
                inp.focus();
                const set = Object.getOwnPropertyDescriptor(inp.constructor.prototype, 'value').set;
                set.call(inp, $(TK.json(src_dir)));
                inp.dispatchEvent(new Event('input', {bubbles: true}));
                inp.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', keyCode: 13, bubbles: true}));
                return true; })()""")
            ok === true || error("create_on_worker: folder field not found")
            TK.wait_for(s, "path committed",
                "[...document.querySelectorAll('.bt-addr-bar')].some(b => b.offsetParent && (b.innerText||'').includes($leaf))";
                timeout = 30)
            TK.click_text(s, "Choose")
            # Name the project (same name on both ⇒ siblings).
            TK.set_input(s, "input", PROJNAME; placeholder = "e.g. my-project")
            # Drive the Worker <select> to the desired worker_id. The form's
            # select carries one <option value=worker_id>name</option> per worker;
            # set its value + fire change so `np_worker` updates before Create.
            picked = TK.eval_js(s, """(() => {
                const sel = document.querySelector('.bt-np-worker-select');
                if (!sel) return false;
                const opt = [...sel.options].find(o => o.value === $(TK.json(worker_id)));
                if (!opt) return false;
                sel.value = opt.value;
                sel.dispatchEvent(new Event('input', {bubbles: true}));
                sel.dispatchEvent(new Event('change', {bubbles: true}));
                return true; })()""")
            picked === true || error("create_on_worker: no Worker <option> for $worker_id")
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

        # Resolve worker_ids from the form's Worker <select> (option text =
        # worker name, value = worker_id). We need the ids to target the
        # <select> by value when creating each project on a specific worker.
        src1 = mktempdir(); write(joinpath(src1, "README.md"), "FROM main\n"); write(joinpath(src1, "one.txt"), "1\n")
        src2 = mktempdir(); write(joinpath(src2, "README.md"), "FROM w-2\n"); write(joinpath(src2, "two.txt"), "2\n")

        TK.to_dashboard(server)
        TK.click_text(server, "+ New project")
        # Target the form's worker select by ITS class — "first visible select
        # with ≥2 options" picked up the dashboard's session-config pills
        # (also native selects: mode/effort) and read their option labels as
        # worker names.
        TK.wait_for(server, "form for id lookup",
            "(() => { const s = document.querySelector('.bt-np-worker-select'); return !!s && s.offsetParent !== null && s.options.length >= 2; })()";
            timeout = 30)
        ids = TK.eval_js(server, """(() => {
            const sel = document.querySelector('.bt-np-worker-select');
            if (!sel) return null;
            const byName = {};
            for (const o of sel.options) byName[(o.textContent||'').trim()] = o.value;
            return byName; })()""")
        @test ids !== nothing
        main_id = String(ids[MAIN_WORKER])
        other_id = String(ids[OTHER_WORKER])
        @test main_id != other_id
        # Cancel this scouting form open; create_on_worker reopens cleanly.
        TK.click_text(server, "Cancel")

        @testset "BonitoAgents cross-worker sync UI" begin
            # Create the same-named project on each worker.
            pid_main = create_on_worker(server, main_id, src1)
            pid_other = create_on_worker(server, other_id, src2)
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
