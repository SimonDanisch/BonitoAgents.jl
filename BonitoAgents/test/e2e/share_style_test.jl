@testitem "e2e:share_style" setup=[SharedServer] tags=[:e2e] failfast=true begin
    TK=SharedServer.TK
    s=SharedServer.server()
    cwd=mktempdir()
    image=joinpath(cwd,"render-preview.svg")
    write(image,"""<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320"><rect width="640" height="320" fill="#14263d"/><text x="32" y="170" fill="white" font-size="28">Render preview</text></svg>""")
    s.agent_fn[]=_ -> [TK.mcp_call("bt_show";real_process=true,id="share-style",path=image),TK.end_turn()]
    TK.new_chat(s;cwd,title="Share controls")
    TK.send_message(s,"show the render")
    card="document.querySelector('.bt-tool-msg[data-msg-id*=\"share-style\"]')"
    control="$card.querySelector('.bt-share-control')"
    @test TK.wait_for(s,"share control is ready","$card?.querySelector('.bt-share-result')?.disabled===false";timeout=90)
    @test TK.eval_js(s,"$control.querySelector('.bt-share-link').hidden")
    TK.eval_js(s,"$control.__preview=$card.querySelector('img.bt-media'); $control.querySelector('.bt-share-result').click(); true")
    @test TK.wait_for(s,"compact link actions replace the share button",
        "!$control.querySelector('.bt-share-copy').hidden && $control.querySelector('.bt-share-result').hidden && !$control.querySelector('.bt-share-link').hidden";timeout=30)
    @test TK.eval_js(s,"""(() => {
        const root=$control, link=root.querySelector('a'), copy=root.querySelector('.bt-share-copy');
        const style=getComputedStyle(copy);
        return link.textContent==='Open link ↗' && new URL(link.href).pathname.startsWith('/s/') &&
            link.title===link.href && !root.textContent.includes(link.href) &&
            style.appearance==='none' && style.fontSize==='12px' && style.borderRadius==='6px' &&
            getComputedStyle(link).textDecorationLine==='none' &&
            root.__preview===$card.querySelector('img.bt-media');
    })()""")
    TK.screenshot(s,joinpath(tempdir(),"bonitoagents-share-desktop.png"))
    TK.emulate_phone(s) do
        @test TK.wait_for(s,"share controls fit on one mobile row","""(() => {
            const root=$control, link=root.querySelector('a').getBoundingClientRect(), copy=root.querySelector('.bt-share-copy').getBoundingClientRect();
            return Math.abs(link.top-copy.top)<2 && copy.right<=innerWidth && root.scrollWidth<=root.clientWidth+1;
        })()""";timeout=10)
        TK.screenshot(s,joinpath(tempdir(),"bonitoagents-share-phone.png"))
    end
    @test isempty(TK.js_errors(s))
end
