# A freshly loaded chat full of shown files must not log a single console
# warning or error. Production logged dozens on one reload (2026-10-07): every
# share button's script and every image handler ran before its message was in
# the page, so the script threw on a missing element and Bonito skipped the
# handler, which left those buttons without a click handler.
@testitem "e2e:console_clean_reload" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    dir = mktempdir()
    n = 14
    for i in 1:n
        write(joinpath(dir, "image$i.svg"),
              """<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200" fill="hsl($(25i),70%,50%)"/></svg>""")
    end
    shown(i) = [TK.text("image $i"),
                TK.tool(; kind = "other", tool_name = "bt_show", title = "image $i", id = "console-show-$i",
                        content = [TK.text_block("shown: $(joinpath(dir, "image$i.svg")) (image/svg+xml, 120B)")])]
    s.agent_fn[] = _ -> [reduce(vcat, shown.(1:n)); TK.text("all images shown"); TK.end_turn()]
    body(i) = "document.querySelector('.bt-tool-body[data-tool-id=\"console-show-$i\"]')"
    try
        pid = TK.new_chat(s; title = "ConsoleClean")
        TK.send_message(s, "show the images")
        @test TK.wait_for(s, "last image shown", "!!$(body(n))?.querySelector('img.bt-media')"; timeout = 60)
        @test TK.wait_for(s, "turn finished", "document.body.innerText.includes('all images shown')"; timeout = 60)
        TK.navigate(s, "/?pid=$pid")
        # The reload opens the chat at its newest message, following. A scroll
        # in the page's first 400ms used to count as the user's own, which
        # turned following off and left a fast reload far above the bottom.
        @test TK.wait_for(s, "chat reloaded at the bottom", """(() => {
            const c = document.querySelector('.bt-messages');
            return !!c?.__bt_chat?.followMode && c.scrollHeight - c.scrollTop - c.clientHeight < 30 &&
                   c.innerText.includes('all images shown');
        })()"""; timeout = 60)
        # Scroll to the first message once the chat has settled, as a reader
        # does. (Following first off, as a user scrolling up does: a bare
        # scrollTop write while following reads as a layout shift.)
        @test TK.wait_for(s, "chat settled", "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')?.dataset.btSettled === '1'"; timeout = 30)
        TK.eval_js(s, "(() => { const c = document.querySelector('.bt-messages'); c.__bt_chat.setFollowMode(false); c.scrollTop = 0; return true; })()")
        @test TK.wait_for(s, "first image mounted after reload", "!!$(body(1))?.querySelector('img.bt-media')"; timeout = 30)
        # The first image's buttons must work after the reload: its share button
        # enabled by its script, its enlarge button opening the viewer.
        @test TK.wait_for(s, "share button armed", "$(body(1))?.querySelector('.bt-share-result')?.disabled === false"; timeout = 30)
        TK.eval_js(s, "$(body(1))?.querySelector('.bt-media-enlarge')?.click(); true")
        @test TK.wait_for(s, "image viewer opened", "!!document.querySelector('.bt-lightbox-overlay')"; timeout = 10)
        TK.eval_js(s, "document.querySelector('.bt-lightbox-media')?.click(); true")
        @test TK.wait_for(s, "image viewer closed", "!document.querySelector('.bt-lightbox-overlay')"; timeout = 10)
        @test isempty(TK.js_errors(s))
    finally
        rm(dir; recursive = true, force = true)
    end
end
