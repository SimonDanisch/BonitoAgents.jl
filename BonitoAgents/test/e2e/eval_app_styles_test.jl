@testitem "e2e:eval_app_styles" setup = [SharedServer] tags = [:e2e] begin
    # Seen live: sidebar chat icons changed shape over time, a red stripe at the
    # left and the picture squeezed to one side. A live eval app in a chat is its
    # own Bonito session, rendered on the worker, and it numbered its generated
    # CSS classes from 1 exactly like the host page did. Its `.style_N` rules then
    # applied to whatever host element had the same name. Nothing an app defines
    # may restyle the host's elements.
    TK = SharedServer.TK
    s = SharedServer.server()
    APP_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))
    pid = TK.new_chat(s; title = "StyledApp")
    TK.open_chat(s, pid)
    icon = "document.querySelector('.bt-side-item[data-project-id=\"$pid\"] .bt-proj-icon')"
    look = "(() => { const cs = getComputedStyle($icon); return [cs.paddingLeft, cs.backgroundColor, cs.width, cs.height]; })()"
    before = TK.eval_js(s, look)
    # With per-session numbering the icon wears `style_K`; an app with at least
    # K styled elements then defines `.style_K` too. Content-named classes have
    # no number, and 300 elements are plenty either way.
    k = TK.eval_js(s, "(() => { const m = $icon.className.match(/style_(\\d+)/); return m ? Number(m[1]) : 0; })()")
    n = max(300, k + 1)
    appcode = """using Bonito
    App() do
        cells = [DOM.div("cell \$i"; style = Styles("background" => "rgb(255, 0, 0)",
                     "padding-left" => "9px", "--k" => string(i))) for i in 1:$n]
        DOM.div(cells...)
    end"""
    s.agent_fn[] = p -> occursin("styled app", p) ?
        [TK.bt_eval(appcode; env_path = APP_ENV, id = "styled-app"), TK.text("shown"), TK.end_turn()] :
        [TK.text("echo: $p"), TK.end_turn()]
    TK.send_message(s, "show the styled app")
    @test TK.wait_for(s, "app rendered",
        "[...document.querySelectorAll('.bt-chatpane')].some(p => (p.innerText||'').includes('cell $n'))";
        timeout = 240)
    @test TK.eval_js(s, look) == before
    # Every generated class the icon wears is defined by one rule only.
    redefined = TK.eval_js(s, """(() => {
        const mine = $icon.className.split(/\\s+/).filter(c => /^(bs-[0-9a-f]+|style_\\d+)\$/.test(c));
        const bodies = {};
        // A cross-origin sheet (web fonts) throws SecurityError on cssRules and
        // holds no generated classes. Anything else is a real failure.
        for (const sh of document.styleSheets) { let rs; try { rs = sh.cssRules } catch (e) { if (e.name !== 'SecurityError') throw e; continue }
            for (const r of rs) for (const c of mine) if (r.selectorText === '.' + c)
                (bodies[c] = bodies[c] || new Set()).add(r.style.cssText); }
        return mine.filter(c => (bodies[c] || new Set()).size !== 1); })()""")
    @test isempty(redefined)
end
