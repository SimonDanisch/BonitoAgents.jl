# A picture and the tool body around it hold their size from the first frame of
# a reopened chat. The first time it is shown, the browser measures both (the
# file's natural size, the body's height) and reports them; every render after
# that lays the row out at its final size before the body or the bytes arrive,
# so nothing below it moves when they land. Asserted on the DOM after a reload:
# from the moment the row exists its height never changes, and the picture
# arrives already sized.
@testitem "e2e:media_reserve" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    svg = "/tmp/bt_e2e_reserve_$(getpid()).svg"
    write(svg, """<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300">""" *
               """<rect width="400" height="300" fill="#3a7"/></svg>""")
    s.agent_fn[] = p -> occursin("show", p) ?
        [TK.text("the picture:"),
         TK.tool(; kind = "other", tool_name = "bt_show", title = "pic.svg",
                 content = [TK.text_block("shown: $(svg) (image/svg+xml, 120B)")], id = "pic-reserve"),
         TK.text("after the picture"), TK.end_turn()] :
        [TK.text("Echo: $(p)"), TK.end_turn()]

    pid = TK.new_chat(s; title = "MediaReserve")
    ROW_SEL = ".bt-chatpane[data-pane-pid=\"$(pid)\"] .bt-tool-msg[data-msg-id*=\"pic-reserve\"]"
    ROW = "document.querySelector($(TK.json(ROW_SEL)))"
    IMG = "$ROW?.querySelector('img.bt-media')"
    TK.send_message(s, "show the picture")
    @test TK.wait_for(s, "the picture shown",
        "(() => { const i = $IMG; return !!i && i.complete && i.naturalWidth === 400; })()"; timeout = 60) == true
    # Measured on its first showing: the element took the file's size, and the
    # body reports its height once the row holds still (800 ms).
    @test TK.wait_for(s, "the picture sized", "$IMG.getAttribute('width') === '400'"; timeout = 10) == true
    sleep(2)

    # From the document's start: every height the row has, and the picture's
    # width attribute as it arrives.
    probe = """
        window.__rowH = []; window.__imgW = null;
        const sel = $(TK.json(ROW_SEL));
        let row = null;
        const ro = new ResizeObserver(es => {
            for (const e of es) window.__rowH.push(Math.round(e.borderBoxSize[0].blockSize));
        });
        new MutationObserver(() => {
            const r = document.querySelector(sel);
            if (r && r !== row) { row = r; ro.observe(r); }
            const img = row && row.querySelector('img.bt-media');
            if (img && window.__imgW === null) window.__imgW = img.getAttribute('width');
        }).observe(document, {childList: true, subtree: true});
    """
    ctx = s.browser[]
    wc = "electron.BrowserWindow.fromId($(ctx.window.id)).webContents"
    script = TK.run(ctx.app, """(async () => {
        const wc=$wc; if(!wc.debugger.isAttached()) wc.debugger.attach('1.3');
        await wc.debugger.sendCommand('Page.enable');
        return (await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument',
            {source: $(TK.json(probe))})).identifier;
    })()""")
    try
        TK.eval_js(s, "location.reload(); true")
        @test TK.wait_for(s, "the picture back",
            "(() => { const i = $IMG; return !!i && i.complete && i.naturalWidth === 400; })()"; timeout = 60) == true
        sleep(1.5)
        heights = Int.(TK.eval_js(s, "window.__rowH"))
        @test !isempty(heights)
        @test maximum(heights) - minimum(heights) <= 2      # it never grew
        @test TK.eval_js(s, "window.__imgW") == "400"      # sized before its bytes
    finally
        TK.run(ctx.app, "(async()=>{const wc=$wc;await wc.debugger.sendCommand('Page.removeScriptToEvaluateOnNewDocument',{identifier:$(TK.json(script))});wc.debugger.detach();})()")
        rm(svg; force = true)
        s.agent_fn[] = S.default_agent
    end
    @test isempty(TK.js_errors(s))
end
