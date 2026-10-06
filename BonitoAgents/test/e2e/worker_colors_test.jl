@testitem "e2e:worker_colors" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    s = TK.dev_server(agent = _ -> [TK.text("ready"), TK.end_turn()])
    screenshot_dir = mktempdir(; prefix="bt-worker-colors-")
    try
        TK.open_browser(s)
        a = TK.new_chat(s)
        TK.send_message(s, "first worker")
        TK.to_dashboard(s)
        # Pick two different hues deliberately: random worker ids can hash to
        # the same hue, which would make this rendering regression test flaky.
        first_id = TK.eval_js(s, "document.querySelector('.bt-worker-card').dataset.workerId")
        second_id = first("color-fixture-$i" for i in 1:360
            if BonitoAgents.worker_color("color-fixture-$i") != BonitoAgents.worker_color(first_id))
        TK.add_worker!(s; name="Second worker", worker_id=second_id)
        @test TK.wait_for(s, "second worker card ready",
            "[...document.querySelectorAll('.bt-worker-card')].some(c=>c.querySelector('.bt-card-name')?.value==='Second worker' && c.innerText.includes('+ Project'))"; timeout=60)
        b = TK.new_chat(s; worker="Second worker")
        TK.send_message(s, "second worker")
        @test TK.wait_for(s, "second worker replied", "document.querySelector('.bt-chatpane[data-pane-pid=\"$b\"] .bt-messages')?.textContent.includes('ready')"; timeout=30)
        TK.to_dashboard(s)
        @test TK.wait_for(s, "both overview icons ready",
            "!!document.querySelector('.bt-ov-card[data-project-id=\"$a\"] .bt-proj-tag') && !!document.querySelector('.bt-ov-card[data-project-id=\"$b\"] .bt-proj-tag')"; timeout=30)
        colors = TK.eval_js(s, """(() => {
            return [$(TK.json(a)),$(TK.json(b))].map(pid=>{
                const icon=document.querySelector('.bt-side-item[data-project-id="'+pid+'"] .bt-proj-icon');
                const tag=icon.querySelector('.bt-proj-tag');
                const workerName=icon.title.split(' · ')[0];
                const card=[...document.querySelectorAll('.bt-worker-card')].find(c=>c.querySelector('.bt-card-name').value===workerName);
                const overview=document.querySelector('.bt-ov-card[data-project-id="'+pid+'"] .bt-proj-icon');
                return {ring:getComputedStyle(icon).backgroundColor,
                    badge:getComputedStyle(tag).backgroundColor,
                    card:getComputedStyle(card).borderLeftColor,
                    cardWidth:parseFloat(getComputedStyle(card).borderLeftWidth),
                    cardBadge:getComputedStyle(card.querySelector('.bt-card-initials')).backgroundColor,
                    overview:getComputedStyle(overview).backgroundColor};
            });
        })()""")
        @test colors[1]["ring"] != colors[2]["ring"]
        for c in colors
            @test c["ring"] == c["badge"] == c["card"] == c["cardBadge"] == c["overview"]
            @test c["cardWidth"] >= 3  # device-pixel rounding of the 4px stripe
        end
        TK.screenshot(s, joinpath(screenshot_dir, "worker_cards.png"))
        @info "worker identity screenshot" path=joinpath(screenshot_dir, "worker_cards.png")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
