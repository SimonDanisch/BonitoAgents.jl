# Media on a phone (touch, no hover): taps land on what the user can see,
# enlarging costs no second download, copy says whether it worked, and scrolling
# past media right after a page load does not flip it in and out of the list.
@testitem "e2e:mobile_media" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # An image the browser can decode, draw and copy; the video only has to exist.
    svg = "/tmp/bt_e2e_mobile_media_$(getpid()).svg"
    mp4 = "/tmp/bt_e2e_mobile_media_$(getpid()).mp4"
    write(svg, """<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="#3b82f6"/></svg>""")
    write(mp4, UInt8.((0:29999) .% 256))
    # Unique tool ids: a tool body is mounted into the slot with its id, and
    # another chat on this shared server may hold an older run's.
    tag = string(rand(UInt32); base = 16)
    s.agent_fn[] = prompt -> occursin("seed", prompt) ? vcat(
        [TK.text("code:\n\n```julia\nprintln(\"copy me\")\n```"),
         TK.tool(; kind = "other", tool_name = "bt_show", title = "pic.svg", id = "mm-img-$(tag)",
                   content = [TK.text_block("shown: $(svg) (image/svg+xml, $(filesize(svg))B)")]),
         TK.tool(; kind = "other", tool_name = "bt_show", title = "clip.mp4", id = "mm-vid-$(tag)",
                   content = [TK.text_block("shown: $(mp4) (video/mp4, 30000B)")])],
        # enough after the media to scroll it out of the render window
        reduce(vcat, [[TK.text("tail bubble number $(i), a short line of prose"),
                       TK.tool(kind = "read", title = "tail tool $(i)", id = "mm-tail-$(tag)-$(i)")] for i in 1:20]),
        [TK.end_turn()]) : [TK.text("echo"), TK.end_turn()]

    # every query looks inside the chat on screen: the shared server keeps other chats' panes
    PANE = "[...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent)"

    pid = TK.new_chat(s; title = "MobileMedia")
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "the whole turn", "($(PANE)?.innerText || '').includes('tail bubble number 20')";
        timeout = 60) == true
    # up to the media (a wheel first, so follow mode lets go)
    TK.eval_js(s, """(() => { const c = $(PANE);
        c.dispatchEvent(new WheelEvent('wheel', {bubbles: true})); c.scrollTop = 0; return true; })()""")
    @test TK.wait_for(s, "the picture and the video",
        "!!$(PANE).querySelector('.bt-media-wrap img.bt-media')?.complete && !!$(PANE).querySelector('.bt-media-wrap video.bt-media')";
        timeout = 30) == true

    TK.emulate_phone(s) do
        # the viewport change sends the list to its tail: swipe back up to the media
        on_screen = """(() => { const i = $(PANE).querySelector('.bt-media-wrap img.bt-media');
            if (!i) return false; const r = i.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })()"""
        for _ in 1:12
            TK.eval_js(s, on_screen) == true && break
            TK.swipe(s, 500)
            sleep(0.4)
        end
        @test TK.eval_js(s, on_screen) == true
        # Hover-only actions would be invisible and still take the taps.
        @test TK.eval_js(s, """(() => { const a = [...$(PANE).querySelectorAll('.bt-media-actions, .bt-code-actions')];
            return a.length >= 3 && a.every(e => getComputedStyle(e).opacity === '1'); })()""") == true

        # A tap anywhere closes the picture, the picture itself too: no Esc on a phone.
        TK.tap(s, ".bt-media-wrap img.bt-media")
        @test TK.wait_for(s, "the lightbox", "!!document.querySelector('.bt-lightbox-overlay')"; timeout = 10) == true
        TK.tap(s, ".bt-lightbox-media")
        @test TK.wait_for(s, "a tap on the picture closed it", "!document.querySelector('.bt-lightbox-overlay')"; timeout = 10) == true

        # The video goes fullscreen itself, rather than a copy downloading it again.
        TK.tap(s, ".bt-media-wrap video.bt-media ~ .bt-media-actions .bt-media-enlarge")
        @test TK.wait_for(s, "the video fullscreen",
            "document.fullscreenElement === $(PANE).querySelector('.bt-media-wrap video.bt-media')"; timeout = 10) == true
        @test TK.eval_js(s, "!document.querySelector('.bt-lightbox-overlay')") == true
        TK.eval_js(s, "document.exitFullscreen(); true")
        @test TK.wait_for(s, "out of fullscreen", "!document.fullscreenElement"; timeout = 10) == true

        # Copy says whether it worked.
        TK.tap(s, ".bt-media-wrap .bt-media-copy")
        @test TK.wait_for(s, "the picture copied",
            "$(PANE).querySelector('.bt-media-wrap .bt-media-copy').textContent === '✓'"; timeout = 10) == true
        TK.tap(s, ".bt-code-copy")
        @test TK.wait_for(s, "the code copied",
            "[...$(PANE).querySelectorAll('.bt-code-copy')].some(b => b.textContent === '✓')"; timeout = 10) == true

        # Asking again for an unchanged file is a 304, not the file again.
        TK.eval_js(s, """(async () => {
            window.__revalidated = null;
            const src = $(PANE).querySelector('.bt-media-wrap img.bt-media').getAttribute('src');
            const etag = (await fetch(src, {cache: 'no-store'})).headers.get('ETag');
            window.__revalidated = (await fetch(src, {cache: 'no-store', headers: {'If-None-Match': etag}})).status;
        })(); true""")
        @test TK.wait_for(s, "the revalidation", "window.__revalidated"; timeout = 15) == 304

        # After a load the media rows are unmeasured. Scrolling past them must
        # measure them on the way in: they used to shift the anchor, drop out on
        # the next frame and come back, over and over.
        TK.reload!(s)
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "the chat at its end", "($(PANE)?.innerText || '').includes('tail bubble number 20')"; timeout = 30) == true
        TK.eval_js(s, """(() => {
            window.__mediaRowMoves = 0;
            const media = n => n.nodeType === 1 && !!n.querySelector?.('.bt-media');
            new MutationObserver(recs => recs.forEach(r => {
                window.__mediaRowMoves += [...r.addedNodes, ...r.removedNodes].filter(media).length;
            })).observe($(PANE), {childList: true});
            return true; })()""")
        for _ in 1:8
            TK.swipe(s, 700)
            sleep(0.3)
        end
        @test TK.wait_for(s, "the media back in view", "!!$(PANE).querySelector('.bt-media-wrap img.bt-media')"; timeout = 15) == true
        # each of the two rows comes in once, and may leave once
        @test TK.eval_js(s, "window.__mediaRowMoves") <= 4
    end

    @test isempty(TK.js_errors(s))
    rm(svg; force = true); rm(mp4; force = true)
end
