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
# A file OUTSIDE the project tree: its server path is a cache miss, so opening it
# routes through fetch_file_from_worker (the real worker transfer) instead of the
# shared-FS short-circuit — the path a remote worker always takes.
const OUTSIDE = mktempdir()
write(joinpath(OUTSIDE, "remote.jl"), "const REMOTE_FETCHED = 99\n")

# The browser command a `.bt-path-link` click fires (same EditFileCommand path).
open_file(path) = """(() => { document.querySelector('.bt-messages').__bt_chat.comm.notify(
    {type:'edit_file', path: $(TK.json(path))}); return true; })()"""
panel_sel(path)  = ".bw-ws-panel[data-panel-id=\"file:$(path)\"]"
# Count file tabs whose label matches one of our files.
file_tab_count  = "[...document.querySelectorAll('.bw-tab-label')].filter(l => /hello\\.jl|second\\.jl/.test(l.textContent)).length"
active_tab_label = "(document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent || '')"

# An agent turn that renders a `read` tool whose TITLE is a real file path → the
# title becomes a `.bt-path-link` we can actually click (the JS delegation path).
agent_script(prompt) = [TK.tool(kind = "read", title = joinpath(CWD, "hello.jl"),
                                 id = "read-real", tool_name = "Read",
                                 content = [TK.text_block("```julia\nprintln(\"hi from hello\")\n```")]),
                        TK.text("opened.")]

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
            @test TK.wait_for(server, "editor has real height",
                "(document.querySelector('$(panel_sel("hello.jl")) .bt-file-editor-body')?.offsetHeight || 0) > 200"; timeout = 30) == true
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

        @testset "a real .bt-path-link click opens the editor" begin
            TK.send_message(server, "read it")
            @test TK.wait_for(server, "path-link in the read tool title",
                "!!document.querySelector('.bt-tool-title.bt-path-link')"; timeout = 36) == true
            TK.eval_js(server, "document.querySelector('.bt-tool-title.bt-path-link').click()")
            @test TK.wait_for(server, "click opened the hello.jl editor",
                "!!document.querySelector('$(panel_sel(joinpath(CWD, "hello.jl")))') || !!document.querySelector('$(panel_sel("hello.jl"))')"; timeout = 36) == true
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
