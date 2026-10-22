@testitem "e2e:plain_code" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    source = "raw\ttext & < >\ntwo  spaces"
    s.agent_fn[] = _ -> [TK.tool(kind = "other", title = "plain result", id = "plain-code",
        content = [TK.text_block("```\n" * source * "\n```")]), TK.end_turn()]
    TK.new_chat(s)
    try
        TK.send_message(s, "plain code")
        @test TK.wait_for(s, "plain tool received", "!document.querySelector('.bt-busy.bt-busy-active') && !!document.querySelector('.bt-tool-msg[data-msg-id*=plain-code]')"; timeout = 60)
        # Start a fresh page to check the dependency requests, independent of
        # editors a previous shared-server item opened in this window.
        TK.navigate(s, "/")
        @test TK.wait_for(s, "plain tool replayed", "!!document.querySelector('.bt-tool-msg[data-msg-id*=plain-code]')"; timeout = 30)
        TK.click(s, ".bt-tool-msg[data-msg-id*=plain-code] .bt-tool-header")
        code = "document.querySelector('.bt-tool-msg[data-msg-id*=plain-code] .bt-code')"
        @test TK.wait_for(s, "plain rows ready", "$code?.dataset.btHighlighted === 'true'"; timeout = 30)
        @test TK.eval_js(s, "[...$code.querySelectorAll('.bt-l')].map(r=>r.textContent).join('\\n')") == source
        @test TK.eval_js(s, "performance.getEntriesByType('resource').some(e=>e.name.includes('Monaco.bundled.js'))") == false
        @test TK.eval_js(s, """(() => {
            const r = document.createRange(); r.selectNodeContents($code.querySelector('.bt-code-lines'));
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(r);
            const text = selection.toString(); selection.removeAllRanges(); return text;
        })()""") == source
        @test isempty(TK.js_errors(s))
    finally
        s.agent_fn[] = S.default_agent
    end
end
