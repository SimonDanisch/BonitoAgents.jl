# End-to-end: the per-chat file tree in the sidebar + the editor open-guard.
#
# Each open chat's sidebar entry carries a ▸ toggle that reveals a lazy,
# searchable file tree of that project (scanned on the worker over the
# `list_dir` / `list_project_files` RPCs). This exercises:
#   * the ▸ toggle reveals the tree and lazy-loads the project root (dirs first)
#   * expanding a directory lazy-loads its children
#   * the search box fuzzy-filters the project file index to a flat hit list
#   * clicking a file opens it as a Monaco panel (the guarded open path)
#   * the open-guard: a binary / oversize / folder file flashes a toast and
#     opens NO panel (instead of streaming bytes into an empty editor)
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# A project with a small known tree: nested dirs, a binary file (open-guard),
# and a .git/ that must NOT show up in the search index.
const CWD = mktempdir()
mkpath(joinpath(CWD, "src"))
mkpath(joinpath(CWD, "test"))
mkpath(joinpath(CWD, ".git"))
write(joinpath(CWD, "Project.toml"),         "name = \"X\"\n")
write(joinpath(CWD, "src", "main.jl"),        "println(\"hi from main\")\n")
write(joinpath(CWD, "test", "runtests.jl"),   "using Test\n")
write(joinpath(CWD, ".git", "config"),        "[core]\n")
write(joinpath(CWD, "blob.bin"),              repeat("x", 4096))  # binary ext → guard
# Ranking fixture: an EXACT basename match buried deep, plus a shallow file the
# query only matches as a scattered subsequence — the exact one must rank first.
mkpath(joinpath(CWD, "pkg"));        write(joinpath(CWD, "pkg", "zebra.jl"),          "module Zebra end\n")
mkpath(joinpath(CWD, "z", "e", "b")); write(joinpath(CWD, "z", "e", "b", "rare_animal.jl"), "# z-e-b-r-a subsequence noise\n")

labels(sel) = "[...document.querySelectorAll('$(sel)')].map(e => e.textContent)"
row_for(name) = "[...document.querySelectorAll('.bt-tree-row')].find(r => r.querySelector('.bt-tree-label')?.textContent === $(TK.json(name)))"

function run_suite(server)
    @testset "BonitoAgents file tree + open-guard (UI-only)" begin
        pid = TK.new_chat(server; cwd = CWD, title = "Tree")
        # The file rows carry WORKER-absolute paths — wait for the push, then read it.
        state = server.h.state
        worker_path = ""
        for _ in 1:60
            p = get(state.projects[], pid, nothing)
            if p !== nothing && !isempty(p.worker_path)
                worker_path = p.worker_path; break
            end
            sleep(0.5)
        end
        @test !isempty(worker_path)
        panel_sel(abs) = ".bw-ws-panel[data-panel-id=\"file:$(abs)\"]"

        @testset "the chat entry has a file-tree expand hint" begin
            @test TK.wait_for(server, "tree hint present",
                "document.querySelectorAll('.bt-side-tree-hint').length === 1"; timeout = 24) == true
            @test TK.eval_js(server, "document.querySelectorAll('.bt-side-tree-wrap').length") == 1
        end

        @testset "the hint reveals the tree and lazy-loads the root (dirs first)" begin
            TK.eval_js(server, "document.querySelector('.bt-side-tree-hint').click(); true")
            @test TK.wait_for(server, "tree open",
                "document.querySelector('.bt-side-chat.bt-tree-open') !== null"; timeout = 18) == true
            @test TK.wait_for(server, "root rows loaded",
                "document.querySelectorAll('.bt-side-tree-wrap .bt-tree-row').length >= 4"; timeout = 36) == true
            # Dirs first (alpha), then files (alpha): pkg/src/test/z, then blob.bin/Project.toml.
            @test TK.eval_js(server, labels(".bt-side-tree-wrap .bt-tree-row .bt-tree-label")) ==
                  ["pkg", "src", "test", "z", "blob.bin", "Project.toml"]
        end

        @testset "expanding a directory lazy-loads its children" begin
            TK.eval_js(server, "$(row_for("src"))?.click(); true")
            @test TK.wait_for(server, "src expanded shows main.jl",
                "[...document.querySelectorAll('.bt-tree-label')].some(e => e.textContent === 'main.jl')"; timeout = 24) == true
        end

        @testset "search fuzzy-filters the project file index" begin
            TK.eval_js(server, """(() => { const s = document.querySelector('.bt-tree-search');
                s.value = 'runtst'; s.dispatchEvent(new Event('input', {bubbles:true})); return true; })()""")
            @test TK.wait_for(server, "search finds runtests.jl",
                "[...document.querySelectorAll('.bt-tree-label')].some(e => e.textContent === 'runtests.jl')"; timeout = 24) == true
            # .git/config must NOT be in the index.
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-tree-label')].every(e => e.textContent !== 'config')") == true
            # Ranking: an exact basename match (deep `pkg/zebra.jl`) must rank
            # ABOVE a file the query only hits as a scattered subsequence
            # (`z/e/b/rare_animal.jl`) — the bug that buried exact matches.
            TK.eval_js(server, """(() => { const s = document.querySelector('.bt-tree-search');
                s.value = 'zebra.jl'; s.dispatchEvent(new Event('input', {bubbles:true})); return true; })()""")
            @test TK.wait_for(server, "exact match ranks first",
                "(document.querySelector('.bt-tree-row .bt-tree-label')?.textContent || '') === 'zebra.jl'"; timeout = 24) == true
            # Clear search → back to the tree.
            TK.eval_js(server, """(() => { const s = document.querySelector('.bt-tree-search');
                s.value = ''; s.dispatchEvent(new Event('input', {bubbles:true})); return true; })()""")
            @test TK.wait_for(server, "tree restored",
                "[...document.querySelectorAll('.bt-tree-label')].some(e => e.textContent === 'Project.toml')"; timeout = 18) == true
        end

        @testset "clicking a file opens it as an editor panel" begin
            abs = joinpath(worker_path, "src", "main.jl")
            TK.eval_js(server, "$(row_for("main.jl"))?.click(); true")
            @test TK.wait_for(server, "main.jl editor panel",
                "!!document.querySelector('$(panel_sel(abs))')"; timeout = 45) == true
            @test TK.wait_for(server, "main.jl content loaded",
                "(document.querySelector('$(panel_sel(abs)) .monaco-editor-div')?.__btEditor?.getValue() || '').includes('hi from main')"; timeout = 36) == true
        end

        @testset "the open-guard toasts on a binary file and opens NO panel" begin
            before = TK.eval_js(server, "document.querySelectorAll('.bw-ws-panel').length")
            TK.eval_js(server, "$(row_for("blob.bin"))?.click(); true")
            @test TK.wait_for(server, "guard toast shown",
                "document.querySelector('.bt-toast')?.dataset.shown === 'true'"; timeout = 30) == true
            toast_text = TK.eval_js(server, "document.querySelector('.bt-toast .bt-toast-text').textContent")
            @test occursin("blob.bin", toast_text) && occursin("Can't open", toast_text)
            sleep(1.0)
            @test TK.eval_js(server, "document.querySelectorAll('.bw-ws-panel').length") == before
        end

        @testset "the hint collapses the tree again" begin
            # The chip reads "▴ hide files" while open; clicking it must close the
            # tree (drop `.bt-tree-open`) and hide the rows.
            @test TK.eval_js(server, "document.querySelector('.bt-side-tree-hint').textContent.includes('hide')") == true
            TK.eval_js(server, "document.querySelector('.bt-side-tree-hint').click(); true")
            @test TK.wait_for(server, "tree collapsed",
                "document.querySelector('.bt-side-chat.bt-tree-open') === null"; timeout = 18) == true
            @test TK.eval_js(server,
                "[...document.querySelectorAll('.bt-side-tree-wrap .bt-tree-row')].filter(r => r.offsetParent !== null).length") == 0
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = (_msg -> TK.end_turn()))
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
