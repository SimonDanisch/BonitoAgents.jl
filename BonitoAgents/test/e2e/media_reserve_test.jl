# A picture and the tool body around it hold their size from the first frame of
# a reopened chat. Two pictures: a bt_show of a file (no bytes in the content)
# and a Read of a picture (its bytes in the content, the way claude ships it).
#
#   * Reopened at the width they were shown at: the browser measured both the
#     first time (the file's natural size, the body's height) and reported
#     them, so every render after that lays the row out at its final size.
#   * Reopened at a width they were never shown at: no height for it, so the
#     placeholder takes the picture's shape, from the measured size (bt_show)
#     or from the bytes (Read). It used to reserve the width of "loading…".
#
# Asserted on the DOM after each reopen: from the moment a row exists its
# height never changes, and the picture arrives already sized.
@testitem "e2e:media_reserve" setup = [SharedServer] tags = [:e2e] begin
    using Base64
    S = SharedServer
    s = S.server()
    TK = S.TK

    # Wider than the transcript at either width: the picture is shrunk to fit.
    png = "/tmp/bt_e2e_reserve_$(getpid()).png"
    write(png, base64decode(TK.eval_js(s, """(() => {
        const c = document.createElement('canvas'); c.width = 1200; c.height = 600;
        const g = c.getContext('2d'); g.fillStyle = '#3a7'; g.fillRect(0, 0, 1200, 600);
        return c.toDataURL('image/png').split(',')[1]; })()""")))
    s.agent_fn[] = p -> occursin("show", p) ?
        [TK.text("the picture:"),
         TK.tool(; kind = "other", tool_name = "bt_show", title = "pic.png",
                 content = [TK.text_block("shown: $(png) (image/png, 4KB)")], id = "pic-reserve-show"),
         TK.text("and read:"),
         TK.tool(; kind = "read", tool_name = "Read", title = "Read $(png)",
                 raw_input = Dict("file_path" => png),
                 content = [TK.image_block(read(png), "image/png")], id = "pic-reserve-read"),
         TK.text("after the pictures"), TK.end_turn()] :
        [TK.text("Echo: $(p)"), TK.end_turn()]

    pid = TK.new_chat(s; title = "MediaReserve")
    ROWS_SEL = ".bt-chatpane[data-pane-pid=\"$(pid)\"] .bt-tool-msg[data-msg-id*=\"pic-reserve-\"]"
    ids = ("pic-reserve-show", "pic-reserve-read")
    img(id) = "document.querySelector($(TK.json(ROWS_SEL)) + '[data-msg-id*=\"$(id)\"]')?.querySelector('img.bt-media')"
    loaded = "[$(join(("(i => !!i && i.complete && i.naturalWidth === 1200)($(img(id)))" for id in ids), ", "))].every(x => x)"
    TK.send_message(s, "show the pictures")
    @test TK.wait_for(s, "the pictures shown", loaded; timeout = 60) == true
    # Measured on their first showing: the bt_show element took the file's
    # size, and the bodies report their heights once the rows hold still (800 ms).
    @test TK.wait_for(s, "the picture sized", "$(img(ids[1])).getAttribute('width') === '1200'"; timeout = 10) == true
    sleep(2)

    # From each document's start: every height a row has, the shape its
    # placeholder reserved, and the picture's width attribute as it arrives.
    probe = """
        window.__rowH = {}; window.__ph = {}; window.__imgW = {};
        const sel = $(TK.json(ROWS_SEL));
        const seen = new WeakSet();
        const ro = new ResizeObserver(es => {
            for (const e of es) (window.__rowH[e.target.dataset.msgId] ||= []).push(Math.round(e.borderBoxSize[0].blockSize));
        });
        new MutationObserver(() => {
            for (const r of document.querySelectorAll(sel)) {
                const id = r.dataset.msgId;
                if (!seen.has(r)) { seen.add(r); ro.observe(r); }
                const ph = r.querySelector('.bt-collapsable-loading');
                if (ph && !(id in window.__ph)) window.__ph[id] = ph.style.aspectRatio || ph.style.height;
                const img = r.querySelector('img.bt-media');
                if (img && !(id in window.__imgW)) window.__imgW[id] = img.getAttribute('width');
            }
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
    function check_reopen(what)
        @test TK.wait_for(s, "the pictures back ($what)", loaded; timeout = 60) == true
        sleep(1.5)
        heights = TK.eval_js(s, "window.__rowH")
        imgw = TK.eval_js(s, "window.__imgW")
        for id in ids
            k = only(filter(k -> occursin(id, k), collect(keys(heights))))
            h = Int.(heights[k])
            @test !isempty(h)
            @test maximum(h) - minimum(h) <= 2      # it never grew
            maximum(h) - minimum(h) <= 2 || @info "a picture row changed height" what row = k heights = unique(h)
            @test imgw[k] == "1200"                 # sized before its bytes
        end
        return TK.eval_js(s, "window.__ph")
    end
    try
        TK.eval_js(s, "location.reload(); true")
        check_reopen("same width")

        # Away from the chat, narrower, back: never shown at this width.
        TK.eval_js(s, "location.href = 'about:blank'; true")
        TK.wait_for(s, "the chat gone", "location.href === 'about:blank'"; timeout = 20)
        w, h = s.browser_size
        TK.set_window_size(s, w - 240, h)
        TK.navigate(s, "/?pid=$(pid)")
        ph = check_reopen("new width")
        # The placeholders took the pictures' shape: nothing measured here.
        @test sort(collect(values(ph))) == ["1200 / 600", "1200 / 600"]
    finally
        TK.run(ctx.app, "(async()=>{const wc=$wc;await wc.debugger.sendCommand('Page.removeScriptToEvaluateOnNewDocument',{identifier:$(TK.json(script))});wc.debugger.detach();})()")
        rm(png; force = true)
        s.agent_fn[] = S.default_agent
    end
    @test isempty(TK.js_errors(s))
end
