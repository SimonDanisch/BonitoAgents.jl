# Black-box media e2e: a `bt_show` of an image and a video must render as
# clickable, range-streamable media (the bt_julia_eval+bt_show merge / media
# fast-path work). Drives only the DOM:
#   • image → <img class=bt-media> inside .bt-media-wrap, src = /assets/<key>
#   • video → <video class=bt-media><source src=/assets/<key>>
#   • clicking the image opens the .bt-lightbox-overlay
#   • the browser can Range-fetch the src and gets HTTP 206 (streaming)
# dev_server is local, so the worker reads the same /tmp we write here.
@testitem "e2e:media" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    png = "/tmp/bt_e2e_media_$(getpid()).png"
    mp4 = "/tmp/bt_e2e_media_$(getpid()).mp4"
    write(png, UInt8.((0:4999) .% 256))
    write(mp4, UInt8.((0:29999) .% 256))

    s.agent_fn[] = _ -> [
        TK.text("here's your media"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "image.png",
                  content = [TK.text_block("shown: $(png) (image/png, 5000B)")], id = "img1"),
        TK.tool(; kind = "other", tool_name = "bt_show", title = "clip.mp4",
                  content = [TK.text_block("shown: $(mp4) (video/mp4, 30000B)")], id = "vid1"),
        TK.end_turn(),
    ]

    pid = TK.new_chat(s)
    TK.send_message(s, "show me the media")

    @test TK.wait_for(s, "both bt_show tools completed",
        "[...document.querySelectorAll('.bt-tool-msg .bt-tool-status')].filter(e=>e.textContent==='completed').length >= 2";
        timeout = 60)

    # Expand any collapsed tool bodies so the ShowTool renders.
    TK.eval_js(s, "[...document.querySelectorAll('.bt-tool-msg .bt-tool-header')].forEach(h=>h.click()); true")

    @test TK.wait_for(s, "image renders as streamed asset",
        "(() => { const i = document.querySelector('.bt-media-wrap img.bt-media'); " *
        "return !!i && (i.getAttribute('src')||'').startsWith('/assets/'); })()"; timeout = 30)

    @test TK.wait_for(s, "video renders as streamed asset",
        "(() => { const v = document.querySelector('.bt-media-wrap video.bt-media source'); " *
        "return !!v && (v.getAttribute('src')||'').startsWith('/assets/'); })()"; timeout = 30)

    # Lightbox: clicking the image opens a fullscreen overlay.
    TK.eval_js(s, "document.querySelector('.bt-media-wrap img.bt-media').click(); true")
    @test TK.wait_for(s, "lightbox overlay opened",
        "!!document.querySelector('.bt-lightbox-overlay .bt-lightbox-media')"; timeout = 10)
    # Esc closes it.
    TK.eval_js(s, "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'})); true")
    @test TK.wait_for(s, "lightbox closed",
        "!document.querySelector('.bt-lightbox-overlay')"; timeout = 10)

    # Streaming: the browser Range-fetches the asset and gets 206 Partial Content.
    TK.eval_js(s, """(async () => {
        window.__rangeStatus = null;
        const src = document.querySelector('.bt-media-wrap img.bt-media').getAttribute('src');
        const r = await fetch(src, { headers: { Range: 'bytes=0-99' } });
        window.__rangeStatus = r.status;
    })(); true""")
    @test TK.wait_for(s, "range request returned 206",
        "window.__rangeStatus === 206"; timeout = 15)

    @test isempty(TK.js_errors(s))
    rm(png; force = true); rm(mp4; force = true)
end
