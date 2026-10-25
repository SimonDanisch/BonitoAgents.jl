# "Export as Markdown" (the chat's ⋯ menu) end-to-end against a real dev_server +
# worker + mock agent, driven through the rendered DOM:
#
#   • One scripted turn carries every message shape the exporter renders —
#     reasoning, prose, a shell tool, an edit with its diff, a real Julia eval,
#     a todo list.
#   • The ⋯ menu lists the item as a download link to `/export/<pid>` with a
#     `.md` file name; picking it closes the menu like every other item (the
#     download itself is the browser's business and is NOT triggered here).
#   • The link's own URL, fetched over HTTP, answers the whole chat as Markdown
#     with an attachment disposition: both messages, the reasoning as a quote,
#     the command and the diff in fenced blocks, the todo as a checklist, the
#     edited file by path with the ⚠️ marker and the header disclaimer.
#   • The file is a BonitoBook notebook: the eval is a BonitoBook cell with its
#     output after it, and BonitoBook reads the download back with that cell.
#   • An unknown project id answers 404 (the route is keyed by chat, like
#     `/acp-log/<pid>` and `/download/<pid>`).
@testitem "e2e:export_markdown" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    BA = TK.BT
    HTTP = BA.HTTP

    # Visible-pane scoping (the shared server keeps other chats' panes mounted
    # but hidden; the header menu renders per pane).
    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    vpClick(sel) = "(() => { const p=$VP; const e=p && p.querySelector($(repr(sel))); if(!e) return false; e.click(); return true; })()"
    menu_open = "(() => { const p=$VP; const l=p && p.querySelector('.bt-header-menu .bt-menu-list'); " *
                "return !!l && getComputedStyle(l).display !== 'none'; })()"

    cwd  = mktempdir()
    file = joinpath(cwd, "hello.jl")
    write(file, "println(\"hi\")\n")
    env  = abspath(joinpath(@__DIR__, "..", "evalenv"))

    s.agent_fn[] = function (prompt)
        [TK.thought("Let me look at the file first."),
         TK.text("Reading and patching **hello.jl** now."),
         TK.bash("cat hello.jl", "println(\"hi\")\n"),
         TK.edit(file, "println(\"hi\")", "println(\"hello, world\")"),
         TK.bt_eval("println(\"from the eval\"); 20 + 22"; env_path = env, id = "export-eval"),
         TK.todo([(content = "Patch hello.jl", status = "completed"),
                  (content = "Run the tests",  status = "pending")]),
         TK.text("Done: the greeting is longer now."),
         TK.end_turn()]
    end

    pid = TK.new_chat(s; cwd = cwd)
    @test !isempty(pid)
    TK.clear_js_errors(s)

    TK.send_message(s, "please patch the greeting")
    @test TK.wait_for(s, "the scripted turn landed",
        "(() => { const p=$VP; const m=p && p.querySelector('.bt-messages'); " *
        "return !!m && (m.innerText||'').includes('greeting is longer now'); })()";
        timeout = 60) == true

    link = nothing
    @testset "the ⋯ menu offers the export link" begin
        @test TK.eval_js(s, vpClick(".bt-header-menu .bt-menu-trigger")) == true
        @test TK.wait_for(s, "menu opened", menu_open; timeout = 5) == true
        link = TK.eval_js(s, "(() => { const p=$VP; const a=p && p.querySelector('.bt-header-menu a.bt-header-export'); " *
            "return a ? {text: (a.textContent||'').trim(), href: a.getAttribute('href'), " *
            "download: a.getAttribute('download')} : null; })()")
        @test link !== nothing
        if link !== nothing
            @test link["text"] == "Export as Markdown"
            @test link["href"] == "/export/$(pid)"
            @test endswith(String(link["download"]), ".md")
        end
        # Picking the item closes the menu. The navigation is suppressed for
        # this one click so the test does not kick off a real browser download.
        @test TK.eval_js(s, "(() => { const p=$VP; const a=p && p.querySelector('.bt-header-menu a.bt-header-export'); " *
            "if(!a) return false; a.addEventListener('click', e => e.preventDefault(), {once: true}); " *
            "a.click(); return true; })()") == true
        @test TK.wait_for(s, "menu closed by the item", menu_open * " === false"; timeout = 5) == true
    end

    @testset "the link serves the whole chat as Markdown" begin
        href = link === nothing ? "/export/$(pid)" : String(link["href"])
        r = HTTP.get(s.h.url * href; status_exception = false)
        @test r.status == 200
        hdrs = Dict(lowercase(String(k)) => String(v) for (k, v) in r.headers)
        @test startswith(get(hdrs, "content-type", ""), "text/markdown")
        @test occursin("attachment", get(hdrs, "content-disposition", ""))
        @test occursin(".md", get(hdrs, "content-disposition", ""))

        md = String(r.body)
        # Header: title, session facts, the one-time ⚠️ disclaimer.
        @test startswith(md, "# ")
        @test occursin("- **Project:**", md)
        @test occursin("Files are linked by path, not captured as snapshots", md)
        # Both sides of the conversation, the reasoning as a quote.
        @test occursin("## 🧑 User", md)
        @test occursin("please patch the greeting", md)
        @test occursin("## 🤖 Assistant", md)
        @test occursin("Reading and patching **hello.jl** now.", md)
        @test occursin("Done: the greeting is longer now.", md)
        @test occursin("### 💭 Reasoning", md)
        @test occursin("> Let me look at the file first.", md)
        # Tool calls: the command and the edit's diff, each in a fenced block,
        # the edited file by path with its ⚠️ marker.
        @test occursin("### 🔧 ", md)
        @test occursin("cat hello.jl", md)
        @test occursin("```diff\n-println(\"hi\")\n+println(\"hello, world\")\n```", md)
        @test occursin("`$(file)` ⚠️", md)
        # The todo list as a checklist.
        @test occursin("### ✅ Todo", md)
        @test occursin("- [x] Patch hello.jl", md)
        @test occursin("- [ ] Run the tests", md)
    end

    @testset "the eval is a BonitoBook cell, and BonitoBook reads it back" begin
        r = HTTP.get(s.h.url * "/export/$(pid)"; status_exception = false)
        md = String(r.body)
        @test occursin("This file is a BonitoBook notebook", md)
        @test occursin("Ran in env `$(env)`", md)
        @test occursin("```julia (editor=true, logging=false, output=true, id=1)\n" *
                       "println(\"from the eval\"); 20 + 22\n```", md)
        @test occursin("from the eval", md)       # its output, after the cell
        @test occursin("42", md)
        @test !occursin("remote_ref", md)         # the live value's handle stays out
        BB = BA.BonitoBook
        cells = BB.markdown2book(BB.Markdown.parse(md))
        @test [c.source for c in cells if c.language == "julia"] == ["println(\"from the eval\"); 20 + 22"]
        @test allunique(c.id for c in cells)
    end

    @testset "an unknown chat answers 404" begin
        r = HTTP.get(s.h.url * "/export/nosuchproject"; status_exception = false)
        @test r.status == 404
    end

    @test isempty(TK.js_errors(s))
end
