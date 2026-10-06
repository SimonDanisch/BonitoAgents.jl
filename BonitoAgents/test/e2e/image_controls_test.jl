@testitem "e2e:image_controls" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    using Base64
    cwd = mktempdir()
    svg = joinpath(cwd, "picture.svg")
    write(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"800\"><rect width=\"1200\" height=\"800\" fill=\"blue\"/></svg>")
    inline_src = "data:image/svg+xml;base64," * base64encode(read(svg))
    s.agent_fn[] = p -> occursin("hold", p) ? [TK.delay(5000), TK.text("held turn finished"), TK.end_turn()] :
        !occursin("seed pictures", p) ? [TK.text("ready"), TK.end_turn()] :
        [TK.tool(kind="other",tool_name="bt_show",title="picture.svg",content=[TK.text_block("shown: $svg (image/svg+xml, $(filesize(svg))B)")]),
         TK.text("![Inline picture]($inline_src)"), TK.end_turn()]
    pid = TK.new_chat(s; cwd)
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    q(css) = "document.querySelector($(TK.json(P * css)))"
    overlay = "document.querySelector('.bt-lightbox-overlay')"
    big = "document.querySelector('.bt-lightbox-media')"
    decoded = "$big?.complete && $big.naturalWidth === 1200"
    try
        TK.send_message(s, "seed pictures")
        @test TK.wait_for(s, "tool picture decoded", "$(q("img.bt-media"))?.naturalWidth === 1200"; timeout=45)
        @test TK.wait_for(s, "Markdown picture decoded", "$(q(".bt-agent-msg img"))?.naturalWidth === 1200"; timeout=30)
        for selector in (".bt-media-enlarge", ".bt-agent-msg img")
            TK.real_click(s, P * selector)
            @test TK.wait_for(s, "enlarged image decoded", decoded)
            @test TK.eval_js(s, "(() => {const r=$big.getBoundingClientRect();return r.width>600 && r.height>400 && r.left>=0 && r.top>=0 && r.right<=innerWidth && r.bottom<=innerHeight;})()")
            @test TK.eval_js(s, "getComputedStyle($overlay).position==='fixed' && $big.className==='bt-lightbox-media'")
            @test TK.eval_js(s, "$big.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}))")
            TK.real_click(s, ".bt-lightbox-media")
            @test TK.wait_for(s, "image closes", "!$overlay")
        end
        @test TK.eval_js(s, "$(q("img.bt-media")).dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}))")
        @test TK.eval_js(s, "!document.querySelector('.bt-chat-icon-menu')")
        @test TK.eval_js(s, "$(q(".bt-media-chat-icon")).title==='Set as chat icon'")

        # Real input path for a large pasted image, not a direct chat handler.
        TK.eval_js(s, """(() => {
            const cv=document.createElement('canvas');cv.width=1200;cv.height=800;
            cv.getContext('2d').fillRect(0,0,1200,800);
            cv.toBlob(blob=>{
                const dt=new DataTransfer();dt.items.add(new File([blob],'pasted.png',{type:'image/png'}));
                $(q(".bt-text-input")).dispatchEvent(new ClipboardEvent('paste',{bubbles:true,clipboardData:dt}));
            });
        })()""")
        @test TK.wait_for(s, "paste queued", "!!$(q(".bt-attachment-thumb"))")
        TK.send_message(s, "pasted image")
        # Inspecting the earlier pictures leaves the transcript in reading mode.
        # Use the UI's jump-to-latest control to reveal the new attachment.
        @test TK.wait_for(s, "new message indicator", "!!$(q(".bt-new-msg-pill-visible"))")
        TK.click(s, P * ".bt-new-msg-pill-visible")
        @test TK.wait_for(s, "attachment decoded", "$(q(".bt-user-att-img"))?.naturalWidth===1200")
        small = TK.eval_js(s, "$(q(".bt-user-att-img")).getBoundingClientRect().width")
        TK.real_click(s, P * ".bt-user-attachments .bt-media-enlarge")
        @test TK.wait_for(s, "attachment enlarged", decoded)
        @test TK.eval_js(s, "$big.getBoundingClientRect().width > $(small * 2)")
        TK.eval_js(s, "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));true")
        @test TK.wait_for(s, "Escape closes enlarged attachment", "!$overlay")

        TK.send_message(s, "hold")
        @test TK.wait_for(s, "agent is active", "!!$(q(".bt-busy-active"))")
        TK.click(s, P * ".bt-user-attachments .bt-media-enlarge")
        @test TK.wait_for(s, "viewer opens during running turn", decoded)
        TK.eval_js(s, "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));true")
        @test TK.wait_for(s, "viewer dismissed", "!$overlay")
        sleep(0.3)
        @test TK.eval_js(s, "!!$(q(".bt-busy-active"))")
        @test TK.wait_for(s, "agent finishes normally", "$(q(".bt-messages")).textContent.includes('held turn finished')"; timeout=15)
        @test isempty(TK.js_errors(s))
    finally
        s.agent_fn[] = S.default_agent
    end
end
