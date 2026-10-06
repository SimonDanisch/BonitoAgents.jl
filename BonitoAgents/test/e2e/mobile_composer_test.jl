@testitem "e2e:mobile_composer" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    screenshot_dir = mktempdir(; prefix="bt-composer-ui-")
    s = SharedServer.server()
    s.agent_fn[] = prompt -> [TK.text("Received: " * prompt), TK.end_turn()]
    pid = TK.new_chat(s; title="Mobile composer")
    TK.open_chat(s, pid)
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    q(sel) = "document.querySelector(" * repr(P * sel) * ")"
    ta = q(".bt-text-input")
    wc = "electron.BrowserWindow.fromId($(s.browser[].window.id)).webContents"
    function enter()
        TK.run(s.browser[].app, """(async () => {
            const wc=$wc, attached=wc.debugger.isAttached();
            if (!attached) wc.debugger.attach('1.3');
            try {
                await wc.debugger.sendCommand('Input.dispatchKeyEvent',
                    {type:'keyDown', key:'Enter', code:'Enter', windowsVirtualKeyCode:13, text:'\\r'});
                await wc.debugger.sendCommand('Input.dispatchKeyEvent',
                    {type:'keyUp', key:'Enter', code:'Enter', windowsVirtualKeyCode:13});
            } finally { if (!attached) wc.debugger.detach(); }
        })()""")
    end

    TK.emulate_phone(s) do
        @test TK.eval_js(s, "matchMedia('(pointer: coarse)').matches")
        TK.set_input(s, P * ".bt-text-input", "first line")
        TK.eval_js(s, "$ta.focus(); $ta.setSelectionRange($ta.value.length,$ta.value.length)")
        enter()
        @test TK.wait_for(s, "mobile Enter inserts newline", "$ta.value === 'first line\\n'")
        @test TK.eval_js(s, "!$(q(".bt-user-msg"))")
        @test TK.eval_js(s, "(() => {const classes=['.bt-attach-btn','.bt-yolo-bar','.bt-send-mode-trigger','.bt-stop-btn','.bt-send-btn']; const r=classes.map(c=>document.querySelector($(repr(P))+c).getBoundingClientRect()); return r.every((v,i)=>!i || v.left>=r[i-1].right) && r.every(v=>Math.abs(v.bottom-r[0].bottom)<10);})()")

        @test TK.eval_js(s, "$(q(".bt-stop-btn")).nextElementSibling === $(q(".bt-send-btn")) && $(q(".bt-send-btn")).getBoundingClientRect().width === 36")

        TK.set_input(s, P * ".bt-text-input", join(fill("A line in a longer draft", 10), "\n"))
        @test TK.wait_for(s, "long draft grows beyond old cap", "$ta.getBoundingClientRect().height > 180")
        @test TK.eval_js(s, "$ta.getBoundingClientRect().height <= Math.min(320,innerHeight*.45)+1 && $(q(".bt-send-btn")).getBoundingClientRect().bottom <= innerHeight")
        # Selection and internal scrolling survive edits above the height cap.
        TK.set_input(s, P * ".bt-text-input", join(fill("A line in a very long draft", 60), "\n"))
        @test TK.wait_for(s, "draft reaches cap", "$ta.getBoundingClientRect().height >= 300")
        TK.eval_js(s, "$ta.focus(); $ta.setSelectionRange(5,25); $ta.scrollTop=0; window.__composerMutations=[]; window.__composerObserver=new MutationObserver(es=>window.__composerMutations.push(...es.map(e=>e.attributeName))); window.__composerObserver.observe($ta,{attributes:true,attributeFilter:['style']});")
        @test TK.eval_js(s, "(() => {const t=$ta; t.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertCompositionText',isComposing:true})); return t.selectionStart===5 && t.selectionEnd===25 && t.scrollTop===0;})()")
        @test TK.eval_js(s, "window.__composerMutations.length===0")
        TK.eval_js(s, "window.__composerObserver.disconnect()")
        TK.screenshot(s, joinpath(screenshot_dir, "mobile_long_draft.png"))
        TK.set_input(s, P * ".bt-text-input", "first line\nsecond line")
        TK.tap(s, P * ".bt-send-btn")
        @test TK.wait_for(s, "mobile send button delivers", "$(q(".bt-user-msg"))?.textContent.includes('first line\\nsecond line')")
        @test TK.wait_for(s, "composer shrinks after send", "$ta.value==='' && $ta.getBoundingClientRect().height <= 46")
    end

    # Desktop keeps Enter-to-send, but composition confirmation never sends.
    TK.set_input(s, P * ".bt-text-input", "composing draft")
    @test TK.eval_js(s, "(() => {const t=$ta; for(const init of [{isComposing:true},{keyCode:229}]) { const e=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true,...init}); t.dispatchEvent(e); if(e.defaultPrevented)return false; } return t.value==='composing draft';})()")
    TK.eval_js(s, "$ta.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}))")
    @test TK.eval_js(s, "(() => {const e=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}); $ta.dispatchEvent(e); return !e.defaultPrevented && $ta.value==='composing draft';})()")
    TK.eval_js(s, "$ta.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}))")
    TK.set_input(s, P * ".bt-text-input", "desktop enter")
    TK.eval_js(s, "$ta.focus()")
    enter()
    @test TK.wait_for(s, "desktop Enter sends", "$(q(".bt-messages")).textContent.includes('Received: desktop enter')")

    # Reload immediately after typing, before the debounce timer fires.
    TK.set_input(s, P * ".bt-text-input", "keep this immediate draft")
    TK.eval_js(s, "location.reload()")
    @test TK.wait_for(s, "pagehide flush preserves draft", "$ta?.value==='keep this immediate draft'"; timeout=30)
    TK.set_input(s, P * ".bt-text-input", "")
    @test TK.eval_js(s, "localStorage.getItem('bt-draft:$pid')===null")
    # Exercise the same UI without native field-sizing (older browsers).
    script = TK.run(s.browser[].app, """(async () => {
        const wc=$wc; if(!wc.debugger.isAttached()) wc.debugger.attach('1.3');
        await wc.debugger.sendCommand('Page.enable');
        return (await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', {
            source: "const supports=CSS.supports.bind(CSS); CSS.supports=(...args)=>args[0]==='field-sizing'?false:supports(...args);"
        })).identifier;
    })()""")
    try
        TK.eval_js(s, "location.reload()")
        @test TK.wait_for(s, "native sizing disabled", "!CSS.supports('field-sizing','content')")
        @test TK.wait_for(s, "fallback composer ready", "!!$(q("[data-bt-sizing-fallback]"))?.offsetParent"; timeout=30)
        TK.set_input(s, P * ".bt-text-input", join(fill("Fallback draft line", 8), "\n"))
        @test TK.wait_for(s, "fallback draft grows", "$ta.getBoundingClientRect().height > 160")
        TK.eval_js(s, "$ta.focus(); $ta.setSelectionRange(4,12)")
        @test TK.eval_js(s, "(() => { const t=$ta; t.dispatchEvent(new InputEvent('input',{bubbles:true})); return t.selectionStart===4 && t.selectionEnd===12; })()")
        TK.set_input(s, P * ".bt-text-input", "")
        @test TK.wait_for(s, "fallback draft shrinks", "$ta.getBoundingClientRect().height <= 46")
    finally
        TK.run(s.browser[].app, "(async () => { const wc=$wc; await wc.debugger.sendCommand('Page.removeScriptToEvaluateOnNewDocument',{identifier:$(TK.json(script))}); wc.debugger.detach(); })()")
        TK.eval_js(s, "location.reload()")
        TK.wait_for(s, "native composer restored", "!!$ta?.offsetParent && !$(q("[data-bt-sizing-fallback]"))"; timeout=30)
    end
    s.agent_fn[] = SharedServer.default_agent
end
