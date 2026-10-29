@testitem "e2e:share_style" setup=[SharedServer] tags=[:e2e] failfast=true begin
    TK=SharedServer.TK
    s=SharedServer.server()
    cwd=mktempdir()
    image=joinpath(cwd,"render-preview.svg")
    write(image,"""<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320"><rect width="640" height="320" fill="#14263d"/><text x="32" y="170" fill="white" font-size="28">Render preview</text></svg>""")
    s.agent_fn[]=_ -> [TK.mcp_call("bt_show";real_process=true,id="share-style",path=image,title="Render preview"),TK.end_turn()]
    TK.new_chat(s;cwd,title="Share controls")
    TK.send_message(s,"show the render")
    card="document.querySelector('.bt-tool-msg[data-msg-id*=\"share-style\"]')"
    control="$card.querySelector('.bt-share-control')"
    toolbar="$card.querySelector('.bt-file-toolbar')"
    @test TK.wait_for(s,"shared toolbar is ready","$toolbar?.querySelector('.bt-share-result')?.disabled===false && $toolbar.querySelector('.bt-file-toolbar-title').textContent==='Render preview'";timeout=90)
    @test TK.eval_js(s,"getComputedStyle($card.querySelector('.bt-tool-header')).display==='none'")
    @test TK.eval_js(s,"$control.querySelector('.bt-share-link').hidden")
    TK.eval_js(s,"$control.__preview=$card.querySelector('img.bt-media'); $control.querySelector('.bt-share-result').click(); true")
    @test TK.wait_for(s,"sharing moves into its menu",
        "!$control.querySelector('.bt-share-options').hidden && $control.querySelector('.bt-share-result').hidden";timeout=30)
    url=TK.eval_js(s,"$control.querySelector('a').href")
    @test TK.eval_js(s,"$control.__preview===$card.querySelector('img.bt-media') && !$card.textContent.includes($(TK.json(url)))")
    @test TK.wait_for(s,"share actions use the common menu",
        "$control.querySelector('.bw-menu').classList.contains('bw-menu-open') && getComputedStyle($control.querySelector('.bt-share-copy')).display==='block'";timeout=10)
    TK.click(s,".bt-share-options .bw-menu-trigger")
    style="e => { const s=getComputedStyle(e); return [s.backgroundColor,s.color,s.fontSize,s.padding,s.borderBottomColor]; }"
    chat_style=TK.eval_js(s,"($style)($toolbar)")
    TK.emulate_phone(s) do
        @test TK.wait_for(s,"one heading with reachable mobile actions","""(() => {
            const t=$toolbar, share=t.querySelector('.bt-share-options .bw-menu-trigger').getBoundingClientRect(), more=t.querySelector('.bt-media-actions .bw-menu-trigger').getBoundingClientRect();
            return Math.abs(share.top-more.top)<2 && more.right<=innerWidth && t.scrollWidth<=t.clientWidth+1;
        })()""";timeout=10)
        TK.screenshot(s,joinpath(tempdir(),"bonitoagents-share-phone.png"))
    end
    TK.real_click(s,".bt-media-actions .bw-menu-trigger")
    TK.real_click(s,".bt-media-actions .bt-media-enlarge")
    @test TK.wait_for(s,"media action still enlarges the existing preview","!!document.querySelector('.bt-lightbox-overlay')";timeout=10)
    TK.click(s,".bt-lightbox-media")
    @test TK.wait_for(s,"viewer closes","!document.querySelector('.bt-lightbox-overlay')";timeout=10)
    TK.click(s,".bt-file-toolbar-title.bt-path-link")
    panel="document.querySelector('.bt-file-view')"
    @test TK.wait_for(s,"dashboard file view uses the same widget","!!$panel?.querySelector('.bt-file-toolbar .bt-share-result')";timeout=60)
    @test TK.eval_js(s,"($style)($panel.querySelector('.bt-file-toolbar'))")==chat_style
    TK.click(s,".bt-file-view .bt-share-result")
    @test TK.wait_for(s,"dashboard shares through the same control",
        "$panel.querySelector('.bt-share-link')?.getAttribute('href')?.includes('/s/')";timeout=30)
    TK.emulate_phone(s) do
        @test TK.wait_for(s,"dashboard toolbar fits on mobile",
            "$panel.querySelector('.bt-file-toolbar').scrollWidth<=$panel.querySelector('.bt-file-toolbar').clientWidth+1";timeout=10)
        TK.screenshot(s,joinpath(tempdir(),"bonitoagents-file-toolbar-dashboard-phone.png"))
    end
    TK.screenshot(s,joinpath(tempdir(),"bonitoagents-file-toolbar-dashboard.png"))
    # A recipient opens the share directly. Booting the dashboard first and
    # navigating away mid-startup can abort one of its pending fetches.
    viewer=TK.another_browser(s;route=url)
    try
        @test TK.wait_for(viewer,"public viewer uses the same widget","!!document.querySelector('.bt-share-page > .bt-file-toolbar-slot .bt-share-download') && document.querySelector('img.bt-media')?.naturalWidth===640";timeout=30)
        @test TK.eval_js(viewer,"($style)(document.querySelector('.bt-file-toolbar'))")==chat_style
        TK.real_click(viewer,".bt-share-bar .bw-menu-trigger")
        TK.real_click(viewer,".bt-share-bar .bt-media-enlarge")
        @test TK.wait_for(viewer,"public viewer action works","!!document.querySelector('.bt-lightbox-overlay')";timeout=10)
        TK.click(viewer,".bt-lightbox-media")
        TK.emulate_phone(viewer) do
            @test TK.eval_js(viewer,"document.querySelector('.bt-file-toolbar').getBoundingClientRect().right<=innerWidth")
            TK.screenshot(viewer,joinpath(tempdir(),"bonitoagents-share-public-phone.png"))
        end
        @test isempty(TK.js_errors(viewer))
    finally
        TK.close_browser!(viewer)
    end
    @test isempty(TK.js_errors(s))
end
