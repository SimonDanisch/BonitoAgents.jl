@testitem "e2e:large_code" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    # The comment crosses several layout groups and highlighting batches.
    source = "#=\n" * join(("comment $i" for i in 1:80), '\n') * "\n=#\n" *
        join(("value_$i = compute($i) # exact source" for i in 1:10000), '\n')
    s.agent_fn[] = prompt -> occursin("warmup", prompt) ?
        [TK.tool(kind = "read", title = "/p/warmup.jl", id = "warmup-code",
            content = [TK.text_block("warmup = 42")]), TK.end_turn()] :
        [TK.tool(kind = "read", title = "/p/large.jl", id = "large-code",
        content = [TK.text_block(source)]), TK.end_turn()]
    TK.new_chat(s)
    TK.send_message(s, "warmup")
    TK.wait_for(s, "warmup tool", "!!document.querySelector('.bt-tool-msg[data-msg-id*=warmup-code]')"; timeout = 60)
    TK.click(s, ".bt-tool-msg[data-msg-id*=warmup-code] .bt-tool-header")
    TK.wait_for(s, "tokenizer warm", "!!document.querySelector('.bt-tool-msg[data-msg-id*=warmup-code] span[class^=mtk]')"; timeout = 60)
    TK.eval_js(s, """(() => {
        window.__largeCodeTicks = 0;
        window.__largeCodeMountTicks = 0;
        window.__largeCodeTimer = setInterval(() => {
            const code = document.querySelector('.bt-tool-msg[data-msg-id*=large-code] .bt-code');
            if (code?.dataset.btHighlighted === 'false') window.__largeCodeTicks++;
            if (code && !code.querySelector('.bt-code-lines')) window.__largeCodeMountTicks++;
        }, 0);
        return true;
    })()""")
    try
        TK.send_message(s, "show large code")
        @test TK.wait_for(s, "large code tool", "!!document.querySelector('.bt-tool-msg[data-msg-id*=\"large-code\"]')"; timeout = 60)
        TK.click(s, ".bt-tool-msg[data-msg-id*=\"large-code\"] .bt-tool-header")
        @test TK.wait_for(s, "visible source highlighted", "!!document.querySelector('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code span[class^=mtk]')"; timeout = 60)
        @test TK.wait_for(s, "highlighting completed",
            "document.querySelector('.bt-tool-msg[data-msg-id*=large-code] .bt-code')?.dataset.btHighlighted === 'true'"; timeout = 30)
        @test TK.eval_js(s, "window.__largeCodeTicks") > 5
        @test TK.eval_js(s, "window.__largeCodeMountTicks") > 1
        @test TK.eval_js(s, "document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code span[class^=mtk]').length") < 3000
        @test TK.eval_js(s, "document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code-chunk').length") > 100
        @test TK.eval_js(s, "[...document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code .bt-l')].map(r=>r.textContent).join('\\n')") == source
        # Electron has no browser toolbar, but its native find engine is the
        # same one. Deliver the real find shortcut, then search through it.
        TK.ECT.send_input(s.browser[], "{type:'keyDown',keyCode:'F',modifiers:['control']}")
        TK.ECT.send_input(s.browser[], "{type:'keyUp',keyCode:'F',modifiers:['control']}")
        native_find(text) = TK.run(s.browser[].app,
            "electron.BrowserWindow.fromId($(s.browser[].window.id)).webContents.findInPage($(TK.json(text)))")
        native_find("comment 70")
        @test TK.wait_for(s, "multiline comment highlighted after scrolling", """(() => {
            const rows = [...document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code .bt-l')];
            const token = r => r.querySelector('span[class^=mtk]');
            const c = document.querySelector('.bt-messages').getBoundingClientRect();
            const r = rows[70].getBoundingClientRect();
            return token(rows[70]) && r.top >= c.top && r.bottom <= c.bottom;
        })()"""; timeout = 20)
        comment_class = TK.eval_js(s, "document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code .bt-l')[70].querySelector('span[class^=mtk]').className")
        native_find("comment 1")
        @test TK.wait_for(s, "start of multiline comment highlighted", """(() => {
            const row = document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code .bt-l')[1];
            return row.querySelector('span[class^=mtk]')?.className === $(TK.json(comment_class));
        })()"""; timeout = 20)
        native_find("value_9999 = compute(9999)")
        @test TK.wait_for(s, "last source group highlighted after native find", """(() => {
            const rows = [...document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code .bt-l')];
            return !!rows.at(-1)?.querySelector('span[class^=mtk]');
        })()"""; timeout = 20)
        TK.run(s.browser[].app, "electron.BrowserWindow.fromId($(s.browser[].window.id)).webContents.stopFindInPage('keepSelection');true")
        @test TK.eval_js(s, """(() => {
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=large-code] .bt-code-lines'));
            const selection = window.getSelection();
            selection.removeAllRanges(); selection.addRange(range);
            const text = selection.toString(); selection.removeAllRanges();
            return text;
        })()""") == source
        @test TK.eval_js(s, "document.querySelector('.bt-chatpane[aria-hidden=false] .monaco-editor') === null")
        @test isempty(TK.js_errors(s))
    finally
        TK.eval_js(s, "clearInterval(window.__largeCodeTimer);true")
        s.agent_fn[] = S.default_agent
    end
end
