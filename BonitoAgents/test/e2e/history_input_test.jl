@testitem "e2e:history_input" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    s.agent_fn[] = p -> vcat(collect(Iterators.flatten(
        (TK.text("History paragraph $i " * repeat("some text ", 12)),
         TK.tool(kind="read", title="history tool $i", id="history-$i")) for i in 1:150)),
        [TK.end_turn()])
    pid = TK.new_chat(s; title="History input")
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    TK.send_message(s, "seed history")
    @test TK.wait_for(s, "seed completed", "document.querySelector($(TK.json(P * ".bt-messages")))?.textContent.includes('History paragraph 150')"; timeout=60)
    @test TK.wait_for(s, "agent idle", "!document.querySelector($(TK.json(P * ".bt-busy-active")))")
    ctx = s.browser[]
    wc = "electron.BrowserWindow.fromId($(ctx.window.id)).webContents"
    # Begin editing as soon as the composer mounts, before background loading
    # starts. Observe the actual offscreen measurement DOM, not chat internals.
    probe_source = """
            window.__historyBatches=[];
            const ready=setInterval(()=>{
                const t=document.querySelector($(TK.json(P * ".bt-text-input")));
                const m=document.querySelector($(TK.json(P * ".bt-measure")));
                if(!t?.offsetParent || !m)return;
                clearInterval(ready);t.focus();
                window.__historyObserver=new MutationObserver(es=>{
                    const n=es.reduce((sum,e)=>sum+e.addedNodes.length,0);
                    if(n)window.__historyBatches.push(n);
                });
                window.__historyObserver.observe(m,{childList:true});
            },10);
    """
    script = TK.run(ctx.app, """(async () => {
        const wc=$wc; if(!wc.debugger.isAttached()) wc.debugger.attach('1.3');
        await wc.debugger.sendCommand('Page.enable');
        return (await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument',
            {source: $(TK.json(probe_source))})).identifier;
    })()""")
    try
        for selecting in (false, true)
            TK.eval_js(s, "location.reload();true")
            @test TK.wait_for(s, "composer focused after reload", "document.activeElement?.classList.contains('bt-text-input')"; timeout=30)
            @test TK.wait_for(s, "visible reply loaded", "document.querySelector($(TK.json(P * ".bt-agent-msg")))?.textContent.length > 0")
            if selecting
                TK.eval_js(s, """(() => {
                    document.activeElement.blur();
                    const n=document.querySelector($(TK.json(P * ".bt-agent-msg")));
                    const r=document.createRange();r.selectNodeContents(n);
                    const sel=getSelection();sel.removeAllRanges();sel.addRange(r);
                })()""")
            else
                TK.set_input(s, P * ".bt-text-input", "Keep this draft responsive")
            end
            sleep(1.2)
            # Visible-range measurements can still occur; 64-row background
            # batches must wait for editing/selection to finish.
            @test TK.eval_js(s, "window.__historyBatches.every(n=>n<50)")
            @test TK.eval_js(s, selecting ? "!getSelection().isCollapsed" :
                "document.activeElement.value==='Keep this draft responsive'")
            TK.eval_js(s, "document.activeElement.blur();getSelection().removeAllRanges();true")
            @test TK.wait_for(s, "background loading resumes", "window.__historyBatches.some(n=>n>=50)"; timeout=10)
            TK.eval_js(s, "window.__historyObserver.disconnect();true")
        end
    finally
        TK.run(ctx.app, "(async()=>{const wc=$wc;await wc.debugger.sendCommand('Page.removeScriptToEvaluateOnNewDocument',{identifier:$(TK.json(script))});wc.debugger.detach();})()")
        s.agent_fn[] = S.default_agent
    end
end
