@testitem "e2e:worker_colors" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    # Never give a test worker a real install's id: a worker reaps every agent
    # process stamped with its id at startup, so a copied production id kills
    # that machine's live chats. The real fleet's hue spread is checked on the
    # pure colour function in unit:worker_color instead.
    s = TK.dev_server(; name="Worker 1", agent = _ -> [TK.text("ready"), TK.end_turn()])
    screenshots = mktempdir(; prefix="bt-fleet-colors-")
    try
        TK.open_browser(s)
        fleet = ["Worker $i" for i in 1:6]
        for (i, name) in enumerate(fleet[2:end])
            TK.add_worker!(s; name, worker_id="e2e-colors-worker-$(i + 1)")
        end
        @test TK.wait_for(s, "six registered workers", "document.querySelectorAll('.bt-worker-card').length===6"; timeout=90)
        chats = String[]
        for name in fleet
            pid = TK.new_chat(s; worker=name)
            push!(chats, pid)
            TK.send_message(s, name)
            @test TK.wait_for(s, "worker replied", "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"] .bt-messages')?.textContent.includes('ready')"; timeout=40)
            TK.to_dashboard(s)
        end
        probe = """(() => $(TK.json(chats)).map(pid=>{
            const icon=document.querySelector('.bt-side-item[data-project-id="'+pid+'"] .bt-proj-icon');
            const name=icon.title.split(' · ')[0];
            const card=[...document.querySelectorAll('.bt-worker-card')].find(c=>c.querySelector('.bt-card-name').value===name);
            const overview=document.querySelector('.bt-ov-card[data-project-id="'+pid+'"] .bt-proj-icon');
            return {name, ring:getComputedStyle(icon).backgroundColor,
                badge:getComputedStyle(icon.querySelector('.bt-proj-tag')).backgroundColor,
                card:getComputedStyle(card).borderLeftColor,
                cardBadge:getComputedStyle(card.querySelector('.bt-card-initials')).backgroundColor,
                overview:getComputedStyle(overview).backgroundColor};
        }))()"""
        colors = TK.eval_js(s, probe)
        for c in colors
            @test c["ring"] == c["badge"] == c["card"] == c["cardBadge"] == c["overview"]
        end
        # Six workers, six different colours (each holds its own palette slot).
        @test length(Set(c["ring"] for c in colors)) == 6
        for (width,height,label) in [(1280,1100,"desktop"),(2400,1100,"wide"),(390,844,"phone")]
            TK.set_window_size(s, width, height)
            @test TK.wait_for(s, "dashboard next to sidebar", "(() => {const d=document.querySelector('.bt-main').getBoundingClientRect(), b=document.querySelector('.bt-sidebar').getBoundingClientRect();return d.left-b.right<12 && d.right<=innerWidth+1;})()")
            @test TK.eval_js(s, "(() => {const d=document.querySelector('.bt-dash');return d.scrollWidth<=d.clientWidth+1;})()")
            TK.screenshot(s, joinpath(screenshots, "$label.png"))
        end
        TK.set_window_size(s,1280,1100)
        TK.navigate(s, "/")
        @test TK.wait_for(s, "fleet reloaded", "document.querySelectorAll('.bt-worker-card').length===6"; timeout=30)
        @test TK.eval_js(s, probe) == colors
        @info "Six-worker dashboard screenshots" screenshots
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
