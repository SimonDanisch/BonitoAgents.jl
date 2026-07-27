@testitem "e2e:copy_project" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    const ECT = TK.ECT   # ElectronCall.Testing — real trusted mouse/keyboard events
    using Test

    agent_script(_p) = [TK.text("hi")]

    MAIN  = "copy-main"
    OTHER = "copy-other"

    # ── real-mouse helpers ────────────────────────────────────────────────────
    # Page-coordinate center of the first button whose trimmed text matches
    # `label` AND is fully within the current viewport.  Returns null if not
    # found or if the button is outside the visible area (so clicks land on it).
    btn_center_js(label) = """(() => {
        const b = [...document.querySelectorAll('button')]
            .find(b => b.offsetParent !== null && (b.innerText||'').trim() === $(TK.json(label)));
        if (!b) return null;
        const r = b.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) return null;
        if (r.top < 0 || r.bottom > window.innerHeight ||
            r.left < 0 || r.right > window.innerWidth) return null;
        return [r.x + r.width / 2, r.y + r.height / 2];
    })()"""

    # Center of the first element matched by CSS selector that is within
    # the current viewport.
    el_center_js(sel) = """(() => {
        const el = [...document.querySelectorAll($(TK.json(sel)))]
            .find(e => e.offsetParent !== null);
        if (!el) return null;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) return null;
        if (r.top < 0 || r.bottom > window.innerHeight ||
            r.left < 0 || r.right > window.innerWidth) return null;
        return [r.x + r.width / 2, r.y + r.height / 2];
    })()"""

    # Scroll `selector` into the centre of the viewport (instant) and wait
    # for the layout to settle.  Wrapped in an IIFE so `const el` does not
    # pollute the renderer's persistent global scope across eval_js calls.
    scroll_into_view!(server, selector; pause = 0.25) = begin
        TK.eval_js(server, """(() => {
            const el = document.querySelector($(TK.json(selector)));
            el?.scrollIntoView({block: 'center', behavior: 'instant'});
        })()""")
        sleep(pause)
    end

    # Real mouse click: move cursor to target, then fire a trusted mousedown+mouseup
    # via ECT.click (which uses window.__fc.press/release → real PointerEvents).
    real_click!(ctx, target; settle = 0.12) = ECT.click(ctx, target; settle = settle)

    server = TK.dev_server(agent = agent_script, name = MAIN)
    ctx = nothing   # set after open_browser
    try
        TK.open_browser(server)
        ctx = server.browser[]   # ElectronCall.Testing.TestContext
        ECT.install_cursor(ctx)  # required: initialises window.__fc so move_to/click work

        # ── Create a source project on the main worker ────────────────────────
        src_dir = mktempdir()
        write(joinpath(src_dir, "README.md"), "source project\n")
        pid = TK.new_chat(server; cwd = src_dir, title = "SourceProj")
        @test !isempty(pid)

        # ── Add second worker; assert dashboard shows 2/2 online ──────────────
        TK.to_dashboard(server)
        w2 = TK.add_worker!(server; name = OTHER)
        @test TK.wait_for(server, "two workers online",
            """(() => {
                const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/);
                return m && parseInt(m[1]) === 2;
            })()"""; timeout = 30) == true

        TK.screenshot(server, joinpath(tempdir(), "copy_project_before.png"))

        @testset "Copy project button opens form" begin
            # Scroll the button itself into the viewport (not just the h2 section
            # heading — the button may be below the fold on a small window).
            # IIFE: `const` in plain eval_js persists in the renderer global scope.
            TK.eval_js(server, """(() => {
                const btn = [...document.querySelectorAll('button')]
                    .find(b => b.offsetParent !== null &&
                               (b.innerText||'').trim() === '→ Copy project');
                btn?.scrollIntoView({block: 'center', behavior: 'instant'});
            })()""")
            sleep(0.25)

            # Wait until btn_center_js returns non-null, i.e. the button is
            # visible AND within the viewport so elementFromPoint can reach it.
            @test TK.wait_for(server, "→ Copy project button in viewport",
                "$(btn_center_js("→ Copy project")) !== null"; timeout = 10) == true

            # Trusted click via fake cursor: move_to → pointerdown/mousedown →
            # pointerup/mouseup/click — fires onclick on the button element.
            real_click!(ctx, ECT.JS(btn_center_js("→ Copy project")))

            @test TK.wait_for(server, "copy form visible",
                "document.querySelector('.bt-cp-src-worker') !== null"; timeout = 15) == true
        end

        @testset "Form fields are pre-populated" begin
            src_worker_val = TK.eval_js(server,
                "document.querySelector('.bt-cp-src-worker')?.value || ''")
            @test !isempty(String(src_worker_val))

            src_proj_name = TK.eval_js(server, """(() => {
                const s = document.querySelector('.bt-cp-src-project');
                if (!s) return '';
                return (s.options[s.selectedIndex]?.text || '').trim();
            })()""")
            @test occursin("SourceProj", String(src_proj_name))

            name_val = TK.eval_js(server,
                """document.querySelector('input[placeholder="e.g. my-project-copy"]')?.value || ''""")
            @test occursin("copy", String(name_val))

            has_hint = TK.eval_js(server,
                "document.body.innerText.includes('Letters, digits')")
            @test has_hint === true

            TK.screenshot(server, joinpath(tempdir(), "copy_project_form_initial.png"))
        end

        @testset "Target worker select via real select_option" begin
            TK.eval_js(server,
                "document.querySelector('.bt-cp-tgt-worker')?.scrollIntoView({block:'center',behavior:'instant'})")
            sleep(0.15)

            # Find which option index corresponds to the OTHER worker.
            other_idx = TK.eval_js(server, """(() => {
                const sel = document.querySelector('.bt-cp-tgt-worker');
                if (!sel) return -1;
                return [...sel.options]
                    .findIndex(o => (o.text||'').includes($(TK.json(OTHER))));
            })()""")
            @test Int(other_idx) >= 0

            # select_option fires real input+change events so Bonito's handler runs.
            ECT.select_option(ctx, ".bt-cp-tgt-worker", Int(other_idx))
            sleep(0.2)

            tgt_text = TK.eval_js(server, """(() => {
                const s = document.querySelector('.bt-cp-tgt-worker');
                return (s?.options[s.selectedIndex]?.text || '').trim();
            })()""")
            @test occursin(OTHER, String(tgt_text))
        end

        @testset "Name field cleared and re-typed via real keyboard" begin
            # Scroll name field into viewport, clear the pre-filled value, then
            # focus with a real click and type via type_text.
            scroll_into_view!(server, "input[placeholder='e.g. my-project-copy']")
            @test TK.wait_for(server, "name input in viewport",
                "$(el_center_js("input[placeholder='e.g. my-project-copy']")) !== null";
                timeout = 5) == true
            TK.set_input(server, "input[placeholder=\"e.g. my-project-copy\"]", "")
            sleep(0.1)
            real_click!(ctx, ECT.JS(
                el_center_js("input[placeholder='e.g. my-project-copy']")))
            sleep(0.1)
            ECT.type_text(ctx, "SourceProjCopy")
            sleep(0.3)  # allow WS push-backs to settle before checking value

            typed_val = TK.eval_js(server,
                """document.querySelector('input[placeholder="e.g. my-project-copy"]')?.value || ''""")
            @test String(typed_val) == "SourceProjCopy"

            TK.screenshot(server, joinpath(tempdir(), "copy_project_form_filled.png"))
        end

        @testset "Copy button starts transfer and busy card appears" begin
            # Use a CSS selector for the submit button (class-based, not text-search)
            # to scroll it into view — avoids needing querySelectorAll after rapid typing.
            scroll_into_view!(server, ".bt-form-actions .bt-btn:not(.bt-btn-secondary)")
            @test TK.wait_for(server, "Copy button in viewport",
                "$(btn_center_js("Copy")) !== null"; timeout = 10) == true
            real_click!(ctx, ECT.JS(btn_center_js("Copy")))

            # Busy card must become visible (transfer started).
            @test TK.wait_for(server, "busy card visible",
                """(() => {
                    const b = document.querySelector('.bt-busy-card');
                    return b !== null && !b.classList.contains('bt-busy-hidden');
                })()"""; timeout = 20) == true

            TK.screenshot(server, joinpath(tempdir(), "copy_project_busy.png"))

            # Wait for the busy card to clear (rsync + WS push complete).
            @test TK.wait_for(server, "transfer completes",
                """(() => {
                    const b = document.querySelector('.bt-busy-card');
                    return b === null || b.classList.contains('bt-busy-hidden');
                })()"""; timeout = 120) == true

            TK.screenshot(server, joinpath(tempdir(), "copy_project_done.png"))
        end

        @testset "Copied project appears in sidebar on target worker" begin
            # After copy, app navigates to the new project's chat.
            @test TK.wait_for(server, "new project chat open",
                """(() => {
                    const a = document.querySelector('.bt-side-item.bt-side-active');
                    return a !== null && a.getAttribute('data-project-id') !== $(TK.json(pid));
                })()"""; timeout = 15) == true

            new_pid = TK.current_chat_id(server)
            @test !isempty(new_pid)
            @test new_pid != pid

            # Both projects visible in the sidebar.
            @test TK.eval_js(server, """[...document.querySelectorAll('.bt-side-item')]
                .some(e => e.getAttribute('data-project-id') === $(TK.json(new_pid)))""") === true
            @test TK.eval_js(server, """[...document.querySelectorAll('.bt-side-item')]
                .some(e => e.getAttribute('data-project-id') === $(TK.json(pid)))""") === true

            # The copy form is gone.
            @test TK.eval_js(server,
                "document.querySelector('.bt-cp-src-worker') === null") === true

            # The new project belongs to the OTHER worker in server state.
            state = server.h.state
            new_p = get(state.projects[], new_pid, nothing)
            @test new_p !== nothing
            @test occursin(OTHER, state.workers[][new_p.worker_id].name)
        end

        @testset "No JS errors" begin
            @test isempty(TK.js_errors(server))
        end

        kill(w2)
    finally
        close(server)
    end
end
