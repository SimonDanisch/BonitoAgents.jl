@testitem "e2e:copy_project" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    using Test

    agent_script(_p) = [TK.text("hi")]

    MAIN  = "copy-main"
    OTHER = "copy-other"

    server = TK.dev_server(agent = agent_script, name = MAIN)
    try
        TK.open_browser(server)

        # ── Create a source project on the main worker ───────────────────────
        src_dir = mktempdir()
        write(joinpath(src_dir, "README.md"), "source project\n")
        pid = TK.new_chat(server; cwd = src_dir, title = "SourceProj")
        @test !isempty(pid)

        # ── Add a second worker and wait for it on the dashboard ─────────────
        TK.to_dashboard(server)
        w2 = TK.add_worker!(server; name = OTHER)
        @test TK.wait_for(server, "two workers online",
            "(() => { const m = document.body.innerText.match(/(\\d+)\\s*\\/\\s*(\\d+)\\s*workers online/); return m && parseInt(m[1]) === 2; })()";
            timeout = 30) == true

        TK.screenshot(server, joinpath(tempdir(), "copy_project_before.png"))

        @testset "Copy project form" begin
            # The "→ Copy project" button must be in the "New project" section.
            @test TK.wait_for(server, "copy button visible",
                "[...document.querySelectorAll('button')].some(b => (b.innerText||'').trim() === $(TK.json("→ Copy project")) && b.offsetParent !== null)";
                timeout = 10) == true

            # Open the copy form (use click_text_until for cold-mount race).
            TK.click_text_until(server, "→ Copy project",
                "document.querySelector('.bt-cp-src-worker') !== null";
                timeout = 20)
            @test TK.eval_js(server, "document.querySelector('.bt-cp-src-worker') !== null") === true

            # Verify form has all three selects and a name input.
            @test TK.eval_js(server, "document.querySelector('.bt-cp-src-worker') !== null") === true
            @test TK.eval_js(server, "document.querySelector('.bt-cp-tgt-worker') !== null") === true
            @test TK.eval_js(server, "document.querySelector('.bt-cp-src-project') !== null") === true
            @test TK.eval_js(server,
                "document.querySelector('input[placeholder=\"e.g. my-project-copy\"]') !== null") === true

            # Source project should be auto-selected (SourceProj).
            src_name = TK.eval_js(server, """(() => {
                const s = document.querySelector('.bt-cp-src-project');
                if (!s) return '';
                const opt = s.options[s.selectedIndex];
                return opt ? (opt.text || '') : '';
            })()""")
            @test occursin("SourceProj", String(src_name))

            # The "→ Copy project" form name input should be pre-filled.
            name_val = TK.eval_js(server,
                "(() => { const i = document.querySelector('input[placeholder=\"e.g. my-project-copy\"]'); return i ? i.value : ''; })()")
            @test occursin("copy", String(name_val))

            # Switch target worker to "copy-other".
            switched = TK.eval_js(server, """(() => {
                const sel = document.querySelector('.bt-cp-tgt-worker');
                if (!sel) return false;
                const opt = [...sel.options].find(o => (o.text||'').includes($(TK.json(OTHER))));
                if (!opt) return false;
                sel.value = opt.value;
                sel.dispatchEvent(new Event('input', {bubbles: true}));
                sel.dispatchEvent(new Event('change', {bubbles: true}));
                return true;
            })()""")
            @test switched === true

            # Set a valid copy name (alphanumeric, no spaces — copy_to! validates this).
            TK.set_input(server, "input", "SourceProjCopy";
                         placeholder = "e.g. my-project-copy")

            TK.screenshot(server, joinpath(tempdir(), "copy_project_form.png"))
        end

        @testset "Copy executes and shows progress" begin
            TK.click_text(server, "Copy")

            # Busy card should appear quickly.
            @test TK.wait_for(server, "busy card visible during copy",
                "(() => { const b = document.querySelector('.bt-busy-card'); return b && !b.classList.contains('bt-busy-hidden'); })()";
                timeout = 20) == true

            # Wait for the busy card to clear (copy finished — involves rsync + WS push).
            @test TK.wait_for(server, "copy completes (busy clears)",
                "(() => { const b = document.querySelector('.bt-busy-card'); return !b || b.classList.contains('bt-busy-hidden'); })()";
                timeout = 120) == true

            TK.screenshot(server, joinpath(tempdir(), "copy_project_done.png"))
        end

        @testset "Copied project appears in sidebar" begin
            # After a successful copy, dashboard navigates to the new project's chat.
            new_pid = TK.current_chat_id(server)
            @test !isempty(new_pid)
            @test new_pid != pid   # different project from source

            # Sidebar must have an entry for the new project.
            in_sidebar = TK.eval_js(server, """[...document.querySelectorAll('.bt-side-item')]
                .some(e => e.getAttribute('data-project-id') === $(TK.json(new_pid)))""")
            @test in_sidebar === true

            # Copy form is closed.
            @test TK.eval_js(server, "document.querySelector('.bt-cp-src-worker') === null") === true

            # Source project still exists too.
            src_still = TK.eval_js(server, """[...document.querySelectorAll('.bt-side-item')]
                .some(e => e.getAttribute('data-project-id') === $(TK.json(pid)))""")
            @test src_still === true
        end

        @testset "No JS errors" begin
            @test isempty(TK.js_errors(server))
        end

        kill(w2)
    finally
        close(server)
    end
end
