# A live app that grows while parked (scrolled away, kept alive display:none)
# comes back without the chat moving. Unmeasured, its stale height made the
# next range park and un-park it within milliseconds, and the chat jumped.
# Asserted on the DOM: the row turns visible once, and the scroll position in
# that wheel step goes nowhere else.
@testitem "e2e:park_grow" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    env = abspath(joinpath(@__DIR__, "..", "evalenv"))
    app = """
        using Bonito
        PARK_GROW_H = Observable(120)
        App() do
            DOM.div("growing app"; class = "park-grow-app",
                    style = map(h -> "height: \$(h)px; background: #cde;", PARK_GROW_H))
        end"""
    s.agent_fn[] = function (prompt)
        if occursin("grow", prompt)
            return [TK.bt_eval("PARK_GROW_H[] = 1500; nothing"; env_path = env, id = "pg-grow"), TK.end_turn()]
        end
        # Separate messages, so the window moves past the app: consecutive
        # texts coalesce into one message, a tool row between them does not.
        evs = Any[TK.text("the app:"), TK.bt_eval(app; env_path = env, id = "pg-app")]
        for i in 1:20
            push!(evs, TK.text("filler $(i): " * "lorem ipsum dolor sit amet "^10))
            push!(evs, TK.tool(kind = "read", title = "filler tool $(i)", id = "pg-fill-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    TK.new_chat(s; title = "ParkGrow")
    TK.send_message(s, "show the app")

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    chat = "$VP.querySelector('.bt-messages')"
    card(id) = "$VP.querySelector('.bt-tool-msg[data-msg-id*=\"$(id)\"]')"
    done(id) = "($(card(id))?.querySelector('.bt-tool-status')?.textContent || '') === 'completed'"
    @test TK.wait_for(s, "the app mounted", "!!$(card("pg-app"))?.querySelector('.park-grow-app')"; timeout = 180) == true
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true
    # At the bottom, far below it: the app is parked.
    @test TK.wait_for(s, "the app parked", "$(card("pg-app")).style.display === 'none'"; timeout = 30) == true

    # It grows while parked.
    TK.send_message(s, "grow it")
    @test TK.wait_for(s, "the grow eval done", done("pg-grow"); timeout = 120) == true
    @test TK.wait_for(s, "the app grown", "$(card("pg-app")).querySelector('.park-grow-app').style.height === '1500px'"; timeout = 30) == true
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true
    @test TK.eval_js(s, "$(card("pg-app")).style.display") == "none"

    ctx = s.browser[]
    ECT.install_cursor(ctx)
    # The chat's own padding, left of every bubble.
    ECT.move_to(ctx, ECT.JS("(() => { const r = $(chat).getBoundingClientRect(); return [r.left + 3, r.top + r.height / 2]; })()"); duration = 0.05)
    TK.eval_js(s, """(() => {
        const c = $(chat), row = $(card("pg-app"));
        window.__pg = {display: [], scroll: []};
        let last = row.style.display;
        new MutationObserver(() => {
            if (row.style.display !== last) window.__pg.display.push(last = row.style.display);
        })
            .observe(row, {attributes: true, attributeFilter: ['style']});
        c.addEventListener('scroll', () => window.__pg.scroll.push(Math.round(c.scrollTop)));
        return true; })()""")
    # Up a wheel at a time until the app is back.
    shown = false
    for _ in 1:80
        TK.eval_js(s, "window.__pg.scroll = []; true")
        ECT.wheel(ctx, -120; steps = 1)
        # The chat's own scroll listener came first, so the range is updated.
        TK.wait_for(s, "the wheel step scrolled", "window.__pg.scroll.length > 0"; timeout = 5)
        shown = TK.eval_js(s, "$(card("pg-app")).style.display !== 'none'")
        shown && break
    end
    @test shown
    # Long enough for the re-park this guards against (it came within ms).
    sleep(0.5)
    # Visible once, never parked again in between.
    @test TK.eval_js(s, "window.__pg.display") == [""]
    # The step that brought it back scrolled to one place only.
    @test length(unique(TK.eval_js(s, "window.__pg.scroll"))) == 1

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
