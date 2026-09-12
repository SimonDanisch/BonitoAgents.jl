@testitem "e2e:show_reopen" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    dir = mktempdir()
    path = joinpath(dir, "late # preview.svg")
    write(path, """<svg xmlns="http://www.w3.org/2000/svg" width="73" height="41"><rect width="73" height="41" fill="red"/></svg>""")
    s.agent_fn[] = _ -> [
        TK.text("preparing your preview"),
        TK.delay(3000),
        TK.tool(; kind="other", tool_name="bt_show", title="late preview",
            content=[TK.text_block("shown: $path (image/svg+xml, 120B)")], id="late-show"),
        TK.text("preview ready"),
        TK.end_turn(),
    ]
    try
        pid = TK.new_chat(s; title="Delayed file preview")
        TK.send_message(s, "prepare a preview")
        TK.to_dashboard(s)
        sleep(4)  # output arrives while the chat has no visible tool body
        TK.open_chat(s, pid)
        loaded = """(() => {
            const img = document.querySelector('.bt-tool-body[data-tool-id="late-show"] img.bt-media');
            return !!img && img.complete && img.naturalWidth === 73 && img.naturalHeight === 41;
        })()"""
        @test TK.wait_for(s, "unseen preview loads on first view", loaded; timeout=60)
        src = TK.eval_js(s, "document.querySelector('.bt-tool-body[data-tool-id=\"late-show\"] img').getAttribute('src')")
        @test startswith(src, "/worker-file/")

        TK.to_dashboard(s)
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "preview loads after reopening chat", loaded; timeout=30)
        TK.navigate(s, "/?pid=$pid")
        @test TK.wait_for(s, "preview loads after page reload", loaded; timeout=60)
        @test TK.eval_js(s, "document.querySelector('.bt-tool-body[data-tool-id=\"late-show\"] img').getAttribute('src')") == src

        # Force an uncached browser load of the ORIGINAL address after all the
        # session teardown above. naturalWidth catches a 404/broken image; merely
        # checking for <img> would let the original failure pass.
        TK.eval_js(s, """(() => {
            const img = document.createElement('img');
            img.id = 'original-file-address'; img.src = $(TK.json(src * "&probe=1"));
            document.body.appendChild(img); return true;
        })()""")
        @test TK.wait_for(s, "original file URL still loads",
            "document.getElementById('original-file-address')?.naturalWidth === 73"; timeout=30)
        TK.eval_js(s, "document.getElementById('original-file-address').remove(); true")
        @test isempty(TK.js_errors(s))
    finally
        rm(dir; recursive=true, force=true)
    end
end
