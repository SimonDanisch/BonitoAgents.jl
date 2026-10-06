@testitem "e2e:scroll_rubberband" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    TK.set_window_size(s, 1280, 800)
    s.agent_fn[] = p -> [TK.text("```\n" * join(["line $i" for i in 1:100], "\n") * "\n```"), TK.end_turn()]
    pid = TK.new_chat(s; title="Rubberband")
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    C = "document.querySelector($(TK.json(P * ".bt-messages")))"
    TK.send_message(s, "seed scroll history")
    @test TK.wait_for(s, "history fills the viewport", "$C?.textContent.includes('line 100') && $C.scrollHeight > $C.clientHeight + 500")
    @test TK.wait_for(s, "reply finished", "!document.querySelector($(TK.json(P * ".bt-busy-active")))")
    sleep(0.5)

    # Real mouse drag in the empty right margin, past the bottom edge.
    # Viewport notifications overlap spring-back, as keyboard/window changes
    # or streaming resize notifications can do. Probe rendered geometry only.
    x, y = TK.eval_js(s, "(() => {const r=$C.getBoundingClientRect();return [Math.round(r.right-40),Math.round(r.bottom-30)];})()")
    ctx = s.browser[]
    try
        for event in ("{type:'mouseMove',x:$x,y:$y}",
                      "{type:'mouseDown',x:$x,y:$y,button:'left',clickCount:1}",
                      "{type:'mouseMove',x:$x,y:$(y-15),button:'left'}",
                      "{type:'mouseMove',x:$x,y:$(y-250),button:'left'}")
            TK.ECT.send_input(ctx, event)
            sleep(0.06)
        end
        @test TK.eval_js(s, "$C.classList.contains('bt-overscrolling')")
        TK.ECT.send_input(ctx, "{type:'mouseUp',x:$x,y:$(y-250),button:'left',clickCount:1}")
        TK.eval_js(s, """(() => {
            window.__rubberbandProbe = [];
            const start = performance.now(), c=$C;
            const sample = () => {
                visualViewport.dispatchEvent(new Event('resize'));
                window.__rubberbandProbe.push({gap:c.scrollHeight-c.scrollTop-c.clientHeight,
                    elapsed:performance.now()-start});
                if (performance.now()-start < 700) requestAnimationFrame(sample);
            };
            requestAnimationFrame(sample);
        })()""")
        @test TK.wait_for(s, "spring-back finishes", "window.__rubberbandProbe.at(-1)?.elapsed >= 700 && !$C.classList.contains('bt-overscrolling')")
        gaps = TK.eval_js(s, "window.__rubberbandProbe.filter(x=>x.elapsed>120).map(x=>x.gap)")
        @test length(gaps) >= 5
        @test maximum(abs, gaps) <= 2
        @test maximum(gaps) - minimum(gaps) <= 2
    finally
        TK.ECT.send_input(ctx, "{type:'mouseUp',x:$x,y:$y,button:'left',clickCount:1}")
        s.agent_fn[] = S.default_agent
    end
end
