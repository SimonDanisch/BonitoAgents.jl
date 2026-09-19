# End-to-end file opening into the workspace editor, UI-only via TestKit.
#
# Clicking a `.bt-path-link` (tool title, diff header, search hit, linkified
# agent-message path) notifies `{type:'edit_file', path}`; the server resolves
# the file, fetches it to the mirror, and adds a Monaco `FileEditor` PANEL to the
# window's BonitoWidgets.Workspace. This exercises the bits a user hits when they
# "open a file" — the part that had NO CI coverage and felt racy:
#   * a single open shows exactly one editor panel with the right file
#   * RAPID repeated opens of one path make exactly ONE panel (no dup race)
#   * a second file is a second tab; reopening the first activates it (no dup)
#   * closing a file tab drops its panel
#   * a real `.bt-path-link` click opens the editor (the JS delegation path)
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# A project dir with real files to open (resolved relative to the chat's cwd).
const CWD = mktempdir()
write(joinpath(CWD, "hello.jl"),  "println(\"hi from hello\")\n")
write(joinpath(CWD, "second.jl"), "const SECOND = 42\n")
# Regression case from the VideoEditor chat: a real Markdown link to an
# absolute worker-side video path used to navigate to a dashboard HTTP route.
write(joinpath(CWD, "clip.mp4"), UInt8[0x00, 0x00, 0x00, 0x18,
                                      0x66, 0x74, 0x79, 0x70])
# A file OUTSIDE the project tree: its server path is a cache miss, so opening it
# routes through fetch_file_from_worker (the real worker transfer) instead of the
# shared-FS short-circuit — the path a remote worker always takes.
const OUTSIDE = mktempdir()
write(joinpath(OUTSIDE, "remote.jl"), "const REMOTE_FETCHED = 99\n")
# An image: NOT a refusal any more — the file viewer opens it in an image panel.
write(joinpath(CWD, "logo.png"),
      UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, fill(0x00, 64)...])
# A directory: still un-openable, so it must TOAST rather than silently do
# nothing (the #35 bug) — that's what's left of the open-guard's refusals.
mkpath(joinpath(CWD, "subdir"))

# The browser command a `.bt-path-link` click fires (same EditFileCommand path).
open_file(path) = """(() => { document.querySelector('.bt-messages').__bt_chat.comm.notify(
    {type:'edit_file', path: $(TK.json(path))}); return true; })()"""
# A file tab is identified by its ABSOLUTE worker path however it was opened
# (see `open_project_file!`), so a relative path resolves against the chat's cwd.
panel_sel(path)  = ".bw-ws-panel[data-panel-id=\"file:$(isabspath(path) ? path : joinpath(CWD, path))\"]"
# Count file tabs whose label matches one of our files.
file_tab_count  = "[...document.querySelectorAll('.bw-tab-label')].filter(l => /hello\\.jl|second\\.jl/.test(l.textContent)).length"
active_tab_label = "(document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent || '')"

# An agent turn that renders a `read` tool whose TITLE is a real file path → the
# title becomes a `.bt-path-link` we can actually click (the JS delegation path).
agent_script(prompt) = [TK.tool(kind = "read", title = joinpath(CWD, "hello.jl"),
                                 id = "read-real", tool_name = "Read",
                                 content = [TK.text_block("```julia\nprintln(\"hi from hello\")\n```")]),
                        TK.text("Video: [absolute clip]($(joinpath(CWD, "clip.mp4"))) " *
                                "or [relative clip](clip.mp4). External: " *
                                "[Julia](https://julialang.org).")]

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "BonitoAgents file open (UI-only)" begin
        TK.new_chat(server; cwd = CWD, title = "Files")

        @testset "opening a file shows ONE editor panel with the right file" begin
            TK.eval_js(server, open_file("hello.jl"))
            @test TK.wait_for(server, "hello.jl editor panel",
                "!!document.querySelector('$(panel_sel("hello.jl"))')"; timeout = 36) == true
            @test TK.wait_for(server, "Monaco editor mounted",
                "!!document.querySelector('$(panel_sel("hello.jl")) .bt-file-editor .monaco-editor-div')"; timeout = 36) == true
            # The path span proves it's the RIGHT file (Monaco text is virtualized).
            @test TK.eval_js(server,
                "document.querySelector('$(panel_sel("hello.jl")) .bt-file-editor-path').textContent.endsWith('hello.jl')") == true
            # And the live editor really holds the file's content.
            @test TK.wait_for(server, "editor value loaded",
                "(document.querySelector('$(panel_sel("hello.jl")) .monaco-editor-div')?.__btEditor?.getValue() || '').includes('hi from hello')"; timeout = 36) == true
            @test TK.eval_js(server, "document.querySelectorAll('$(panel_sel("hello.jl"))').length") == 1
            # The editor must actually FILL the panel — regression guard for the
            # 1px-high collapse when the panel wrapper doesn't carry height down.
            #
            # Measure the MONACO DIV, not the body around it. The body stayed full
            # height while an unclassed wrapper inside it collapsed to 5px, so the
            # source view of every text file was one clipped line over empty space
            # and this assertion passed the whole time.
            @test TK.wait_for(server, "editor has real height",
                """(() => {
                    const p = document.querySelector('$(panel_sel("hello.jl"))');
                    const body = p?.querySelector('.bt-file-editor-body');
                    const ed = p?.querySelector('.monaco-editor-div');
                    if (!body || !ed) return false;
                    const bh = body.getBoundingClientRect().height;
                    const eh = ed.getBoundingClientRect().height;
                    // the editor fills the body, rather than merely sitting in it
                    return bh > 200 && eh > 200 && eh >= bh - 40;
                })()"""; timeout = 30) == true
        end

        @testset "rapid repeated opens of one path make exactly ONE panel" begin
            for _ in 1:6
                TK.eval_js(server, open_file("hello.jl"))
            end
            sleep(1.5)   # let every async open settle
            @test TK.eval_js(server, "document.querySelectorAll('$(panel_sel("hello.jl"))').length") == 1
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bw-tab-label')].filter(l => l.textContent.includes('hello.jl')).length") == 1
        end

        @testset "a second file is a second tab; reopening the first activates it" begin
            TK.eval_js(server, open_file("second.jl"))
            @test TK.wait_for(server, "second.jl panel",
                "!!document.querySelector('$(panel_sel("second.jl"))')"; timeout = 36) == true
            @test TK.wait_for(server, "two file tabs", "$(file_tab_count) === 2"; timeout = 15) == true
            # Reopen the first: must ACTIVATE the existing panel, not duplicate.
            TK.eval_js(server, open_file("hello.jl"))
            sleep(0.8)
            @test TK.eval_js(server, "document.querySelectorAll('$(panel_sel("hello.jl"))').length") == 1
            @test TK.eval_js(server, "$(file_tab_count)") == 2
            @test TK.wait_for(server, "hello.jl active",
                "$(active_tab_label).includes('hello.jl')"; timeout = 15) == true
        end

        @testset "closing a file tab drops its panel" begin
            TK.eval_js(server, """(() => {
                const t = [...document.querySelectorAll('.bw-tab')].find(
                    t => (t.querySelector('.bw-tab-label')?.textContent || '').includes('hello.jl'));
                t?.querySelector('.bw-tab-close')?.click(); return true; })()""")
            @test TK.wait_for(server, "hello.jl panel gone",
                "document.querySelector('$(panel_sel("hello.jl"))') === null"; timeout = 15) == true
            @test TK.eval_js(server, "$(file_tab_count)") == 1
        end

        @testset "a file outside the project fetches from the worker + dedupes" begin
            # Outside the project tree ⇒ the real worker transfer path. Rapid
            # clicks during the (slower) fetch must still yield exactly ONE panel.
            abs = joinpath(OUTSIDE, "remote.jl")
            for _ in 1:5
                TK.eval_js(server, open_file(abs))
            end
            @test TK.wait_for(server, "remote-fetched editor value",
                "(document.querySelector('$(panel_sel(abs)) .monaco-editor-div')?.__btEditor?.getValue() || '').includes('REMOTE_FETCHED')"; timeout = 60) == true
            sleep(1.0)
            @test TK.eval_js(server, "document.querySelectorAll('$(panel_sel(abs))').length") == 1
        end

        @testset "clicking an image path link opens the IMAGE viewer" begin
            # The file viewer opens every kind, so a .png link is no longer a
            # refusal (it used to toast "not a text file"): it opens a panel that
            # renders the image, with no Monaco and no Save button.
            TK.eval_js(server, open_file("logo.png"))
            @test TK.wait_for(server, "logo.png panel",
                "!!document.querySelector('$(panel_sel("logo.png"))')"; timeout = 36) == true
            @test TK.wait_for(server, "it renders as an image, not source",
                """(() => {
                    const p = document.querySelector('$(panel_sel("logo.png")) .bt-file-view');
                    if (!p) return false;
                    return p.dataset.kind === 'image'
                        && !!p.querySelector('.bt-fv-image-stage img.bt-media')
                        && p.querySelector('.monaco-editor-div') === null
                        && p.querySelector('.bt-file-editor-save') === null;
                })()"""; timeout = 30) == true
            # …and the header names the WORKER file, not the server mirror.
            @test TK.eval_js(server,
                "document.querySelector('$(panel_sel("logo.png")) .bt-file-editor-path').textContent.endsWith('logo.png')") == true
        end

        @testset "a folder still refuses and opens no panel" begin
            # The guard's remaining job: things that cannot be opened AT ALL.
            # The refusal lands in the window's ONE progress card as an error —
            # which, unlike the toast it replaced, does not expire on a timer.
            TK.eval_js(server, open_file("subdir"))
            @test TK.wait_for(server, "folder refusal shown in the progress card",
                "[...document.querySelectorAll('.bt-prog-err .bt-prog-title')].some(t => (t.textContent||'').includes('subdir'))";
                timeout = 15) == true
            @test TK.eval_js(server,
                "document.querySelectorAll('$(panel_sel("subdir"))').length") == 0

            # LAN http:// origins do not expose the async Clipboard API. Force
            # that browser condition and verify the textarea fallback copies the
            # complete error card instead of leaving this button inert.
            copied = TK.eval_js(server, """(() => {
                const ownClipboard = Object.getOwnPropertyDescriptor(navigator, 'clipboard');
                const originalExec = document.execCommand;
                let copied = '';
                try {
                    Object.defineProperty(navigator, 'clipboard', {
                        value: undefined, configurable: true
                    });
                    document.execCommand = command => {
                        if (command === 'copy') copied = document.activeElement?.value || '';
                        return command === 'copy';
                    };
                    document.querySelector('.bt-prog-err .bt-prog-copy').click();
                    return copied;
                } finally {
                    if (ownClipboard) {
                        Object.defineProperty(navigator, 'clipboard', ownClipboard);
                    } else {
                        delete navigator.clipboard;
                    }
                    document.execCommand = originalExec;
                }
            })()""")
            @test occursin("subdir", copied)
            @test TK.eval_js(server,
                "document.querySelector('.bt-prog-err .bt-prog-copy').textContent") == "Copied"
        end

        @testset "a real .bt-path-link click opens the editor" begin
            TK.send_message(server, "read it")
            @test TK.wait_for(server, "path-link in the read tool title",
                "!!document.querySelector('.bt-tool-title.bt-path-link')"; timeout = 36) == true
            TK.eval_js(server, "document.querySelector('.bt-tool-title.bt-path-link').click()")
            @test TK.wait_for(server, "click opened the hello.jl editor",
                "!!document.querySelector('$(panel_sel(joinpath(CWD, "hello.jl")))') || !!document.querySelector('$(panel_sel("hello.jl"))')"; timeout = 36) == true
        end

        @testset "Markdown file links open in the workspace" begin
            abs = joinpath(CWD, "clip.mp4")
            abs_js = TK.json(abs)
            @test TK.wait_for(server, "absolute Markdown link is a workspace path",
                "[...document.querySelectorAll('.bt-agent-msg a.bt-path-link')]" *
                ".some(a => a.dataset.path === $(abs_js))"; timeout = 15) == true
            @test TK.eval_js(server,
                "!document.querySelector('.bt-agent-msg a[href=\"https://julialang.org\"]')" *
                ".classList.contains('bt-path-link')") == true

            TK.eval_js(server,
                "[...document.querySelectorAll('.bt-agent-msg a.bt-path-link')]" *
                ".find(a => a.dataset.path === $(abs_js)).click()")
            @test TK.wait_for(server, "Markdown-linked video panel",
                "!!document.querySelector('$(panel_sel(abs)) .bt-file-view[data-kind=\"video\"]')";
                timeout = 36) == true
            @test TK.eval_js(server,
                "document.querySelector('.bt-agent-msg a[href=\"clip.mp4\"]').dataset.path") ==
                  "clip.mp4"
        end

        @testset "clicking Home activates + relabels the chat tab" begin
            # With a file tab open, the chat panel's tab reads "Chat"; clicking
            # Home must bring that panel to the front AND rename its tab "Home".
            TK.eval_js(server, open_file("second.jl"))   # ensure a 2nd tab exists
            TK.wait_for(server, "two tabs", "document.querySelectorAll('.bw-tab-label').length >= 2"; timeout = 24)
            TK.to_dashboard(server)
            @test TK.wait_for(server, "Home tab active",
                "(document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent || '') === 'Home'"; timeout = 18) == true
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
