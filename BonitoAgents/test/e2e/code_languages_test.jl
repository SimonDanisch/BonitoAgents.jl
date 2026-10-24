@testitem "e2e:code_languages" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    examples = [
        ("julia", "jl", "#= comment\nstill a comment\n=#\nx = \"a  b\""),
        ("javascript", "js", "/* comment\nstill a comment */\nconst value = \"a  b\";\n\tconsole.log(value);"),
        ("json", "json", "{\n\t\"value\": \"a  b\",\n\t\"count\": 42\n}"),
        ("python", "py", "# comment\ndef f(x):\n\treturn \"a  b\""),
        ("shell", "sh", "#!/bin/sh\n# comment\necho \"a  b\""),
        ("html", "html", "<!-- comment -->\n<div class=\"example\">a  b &amp; c</div>\n<script>\nconst embedded = 42;\n</script>\n<style>.example { color: red; }</style>")]
    cwd = mktempdir()
    for (_, ext, source) in examples
        write(joinpath(cwd, "example.$ext"), source)
    end
    s.agent_fn[] = _ -> vcat(Any[TK.tool(kind = "read", title = joinpath(cwd, "example.$ext"),
        id = "language-$name", content = [TK.text_block(source)]) for (name, ext, source) in examples], [TK.end_turn()])
    pid = TK.new_chat(s; cwd)
    TK.navigate(s, "/")
    TK.open_chat(s, pid)
    TK.ECT.install_cursor(s.browser[])
    try
        TK.send_message(s, "show code examples")
        @test TK.wait_for(s, "all code tools received", "!document.querySelector('.bt-busy.bt-busy-active') && document.querySelectorAll('.bt-tool-msg').length === $(length(examples))"; timeout = 60)
        for (name, _, source) in examples
            card = "document.querySelector('.bt-tool-msg[data-msg-id*=\"language-$name\"]')"
            @test TK.wheel_into_view(s, "document.querySelector('.bt-messages')", card; step = 400)
            TK.click(s, ".bt-tool-msg[data-msg-id*=\"language-$name\"] .bt-tool-header")
            @test TK.wait_for(s, "$name highlighted", "new Set([...$card.querySelectorAll('.bt-code span[class^=mtk]')].map(s=>s.className)).size > 1"; timeout = 30)
            @test TK.eval_js(s, "[...$card.querySelectorAll('.bt-code .bt-l')].map(r=>r.textContent).join('\\n')") == source
        end
        @test TK.eval_js(s, "performance.getEntriesByType('resource').some(e=>e.name.includes('Monaco.bundled.js'))") == false
        @test TK.eval_js(s, """(() => {
            const keyword = name => [...document.querySelectorAll('.bt-tool-msg[data-msg-id*=language-'+name+'] .bt-code span[class^=mtk]')]
                .find(e => e.textContent === 'const')?.className;
            return !!keyword('html') && keyword('html') === keyword('javascript');
        })()""")
        json_card = "document.querySelector('.bt-tool-msg[data-msg-id*=language-json]')"
        @test TK.wheel_into_view(s, "document.querySelector('.bt-messages')", json_card; step = 400)
        TK.click(s, ".bt-tool-msg[data-msg-id*=language-json] .bt-path-link")
        @test TK.wait_for(s, "JSON file opens in a real editor",
            """[...document.querySelectorAll('.bt-file-editor')].some(e =>
                e.querySelector('.bt-file-editor-path')?.textContent === $(TK.json(joinpath(cwd, "example.json"))) &&
                e.querySelector('.view-lines')?.textContent.includes('count'))"""; timeout = 60)
        sleep(0.6) # deferred language services must not report stale model errors
        @test isempty(TK.js_errors(s))
    finally
        TK.eval_js(s, """(() => {
            const tab = [...document.querySelectorAll('.bw-tab')]
                .find(t => t.querySelector('.bw-tab-label')?.textContent === 'example.json');
            tab?.querySelector('.bw-tab-close')?.click();
            return true;
        })()""")
        s.agent_fn[] = S.default_agent
    end
end
