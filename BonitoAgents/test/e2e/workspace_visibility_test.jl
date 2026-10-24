@testitem "e2e:workspace_visibility" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    cwd = mktempdir()
    path = joinpath(cwd, "visibility.jl")
    write(path, "const VISIBLE = 1\n")
    s.agent_fn[] = prompt -> occursin("stream", prompt) ?
        [TK.text("starting"), TK.delay(5000), TK.text("finished behind file tab"), TK.end_turn()] :
        [TK.tool(kind = "read", title = path, id = "visible-file",
            content = [TK.text_block("const VISIBLE = 1")]), TK.end_turn()]
    pid = TK.new_chat(s; cwd)
    pane = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
    tab(label) = TK.eval_js(s, """(() => {
        const t = [...document.querySelectorAll('.bw-tab')]
            .find(t => t.querySelector('.bw-tab-label')?.textContent === $(TK.json(label)));
        t.click(); return true;
    })()""")
    try
        TK.send_message(s, "file")
        @test TK.wait_for(s, "file link", "!!document.querySelector('.bt-tool-msg[data-msg-id*=visible-file] .bt-path-link')"; timeout = 60)
        TK.click(s, ".bt-tool-msg[data-msg-id*=visible-file] .bt-path-link")
        @test TK.wait_for(s, "file ready", "[...document.querySelectorAll('.bt-file-editor .view-lines')].some(e=>e.textContent.includes('VISIBLE'))"; timeout = 60)
        tab("Chat")
        TK.send_message(s, "stream")
        @test TK.wait_for(s, "stream started", "$pane.textContent.includes('starting')"; timeout = 60)
        tab("visibility.jl")
        @test TK.eval_js(s, "$pane.closest('.bw-ws-panel').dataset.bwVisible") == "false"
        @test TK.eval_js(s, """(() => {
            const p = $pane.closest('.bw-ws-panel');
            return !CSS.supports('content-visibility', 'hidden') ||
                getComputedStyle(p).contentVisibility === 'hidden';
        })()""")
        @test TK.eval_js(s, """(() => {
            const input = $pane.querySelector('.bt-text-input');
            input.focus(); return document.activeElement !== input;
        })()""")
        @test TK.wait_for(s, "hidden chat keeps receiving output", "$pane.textContent.includes('finished behind file tab')"; timeout = 20)
        tab("Chat")
        @test TK.wait_for(s, "shown chat follows the completed output", """(() => {
            const c = $pane.querySelector('.bt-messages');
            return $pane.closest('.bw-ws-panel').dataset.bwVisible === 'true' &&
                c.scrollHeight - c.scrollTop - c.clientHeight < 2;
        })()"""; timeout = 20)
        @test isempty(TK.js_errors(s))
    finally
        TK.eval_js(s, """(() => {
            const t = [...document.querySelectorAll('.bw-tab')]
                .find(t => t.querySelector('.bw-tab-label')?.textContent === 'visibility.jl');
            t?.querySelector('.bw-tab-close')?.click(); return true;
        })()""")
        s.agent_fn[] = S.default_agent
    end
end
