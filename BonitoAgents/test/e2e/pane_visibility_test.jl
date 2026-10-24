@testitem "e2e:pane_visibility" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    s.agent_fn[] = prompt -> occursin("stream", prompt) ?
        [TK.text("starting"), TK.delay(5000), TK.text("finished while hidden"), TK.end_turn()] :
        [TK.text(join(("visible pane marker $i: " * "paragraph "^20 for i in 1:30), "\n\n")), TK.end_turn()]
    first = TK.new_chat(s)
    TK.send_message(s, "first")
    @test TK.wait_for(s, "first done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60)
    second = TK.new_chat(s)
    TK.send_message(s, "stream")
    @test TK.wait_for(s, "stream started", "document.querySelector('.bt-agent-msg')?.textContent.includes('starting')"; timeout = 60)
    TK.open_chat(s, first)
    @test TK.wait_for(s, "first visible",
        "document.querySelector('.bt-chatpane[aria-hidden=false]')?.dataset.panePid === $(TK.json(first))"; timeout = 20)
    @test TK.eval_js(s, "document.querySelectorAll('.bt-chatpane[aria-hidden=false]').length") == 1
    @test TK.eval_js(s, "document.querySelector('.bt-chatpane[data-pane-pid=\"$second\"]').inert")
    # Background DOM updates must not expose or focus the inactive chat.
    @test TK.wait_for(s, "hidden stream finished",
        "document.querySelector('.bt-chatpane[data-pane-pid=\"$second\"]')?.querySelector('.bt-agent-msg')?.textContent.includes('finished while hidden')"; timeout = 20)
    @test TK.eval_js(s, """(() => {
        const p = document.querySelector('.bt-chatpane[data-pane-pid="$second"]');
        const input = p.querySelector('.bt-text-input');
        input.focus();
        return document.activeElement !== input && p.getAttribute('aria-hidden') === 'true';
    })()""")
    @test TK.eval_js(s, """(() => {
        const p = document.querySelector('.bt-chatpane[data-pane-pid="$second"]');
        return !CSS.supports('content-visibility', 'hidden') ||
            (getComputedStyle(p).contentVisibility === 'hidden' && p.clientHeight > 100);
    })()""")
    TK.open_chat(s, second)
    @test TK.wait_for(s, "second visible",
        "document.querySelector('.bt-chatpane[aria-hidden=false]')?.dataset.panePid === $(TK.json(second))"; timeout = 20)
    @test TK.eval_js(s, "!document.querySelector('.bt-chatpane[data-pane-pid=\"$second\"]').inert")
    @test TK.eval_js(s, "document.querySelector('.bt-agent-msg').textContent.includes('finished while hidden')")
    @test TK.wait_for(s, "revealed chat follows its finished output", """(() => {
        const c = document.querySelector('.bt-messages');
        return c.scrollHeight - c.scrollTop - c.clientHeight < 2;
    })()"""; timeout = 20)

    # A gesture immediately after returning must cancel the delayed restore,
    # rather than jumping back to the old position 50/200 ms later.
    TK.open_chat(s, first)
    @test TK.wait_for(s, "long chat visible",
        "document.querySelector('.bt-chatpane[aria-hidden=false]')?.dataset.panePid === $(TK.json(first))"; timeout = 20)
    TK.ECT.install_cursor(s.browser[])
    gutter = TK.ECT.JS("""(() => {
        const r = document.querySelector('.bt-messages').getBoundingClientRect();
        return [r.left + 3, r.top + r.height / 2];
    })()""")
    TK.ECT.move_to(s.browser[], gutter; duration = 0.01)
    TK.ECT.wheel(s.browser[], -700; steps = 1, step_sleep = 0.01)
    @test TK.wait_for(s, "reading above the bottom", """(() => {
        const c = document.querySelector('.bt-messages');
        return c.scrollHeight - c.scrollTop - c.clientHeight > 300;
    })()"""; timeout = 20)
    top = TK.eval_js(s, "document.querySelector('.bt-messages').scrollTop")
    sleep(0.3)
    @test abs(TK.eval_js(s, "document.querySelector('.bt-messages').scrollTop") - top) < 2
    TK.open_chat(s, second)
    TK.open_chat(s, first)
    sleep(0.3)
    @test abs(TK.eval_js(s, "document.querySelector('.bt-messages').scrollTop") - top) < 2
    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
