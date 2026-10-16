# A live app that grows while it is out of view, above the reader, does not
# move what the reader sees: its row stays in the page (alive, not hidden), and
# the transcript absorbs the growth in its scroll position. Scrolling back up
# to it then moves by the wheel alone. Asserted on the DOM: the row that was
# read keeps its place, and each wheel step scrolls to one place only.
@testitem "e2e:app_grow" setup = [SharedServer] tags = [:e2e] begin
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
        # Separate messages, so the app ends up screens above the bottom:
        # consecutive texts coalesce into one message, a tool row between
        # them does not.
        evs = Any[TK.text("the app:"), TK.bt_eval(app; env_path = env, id = "pg-app")]
        for i in 1:20
            push!(evs, TK.text("filler $(i): " * "lorem ipsum dolor sit amet "^10))
            push!(evs, TK.tool(kind = "read", title = "filler tool $(i)", id = "pg-fill-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    pid = TK.new_chat(s; title = "AppGrow")
    TK.send_message(s, "show the app")

    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    chat = "document.querySelector($(TK.json(P * ".bt-messages")))"
    card(id) = "$(chat).querySelector('.bt-tool-msg[data-msg-id*=\"$(id)\"]')"
    done(id) = "($(card(id))?.querySelector('.bt-tool-status')?.textContent || '') === 'completed'"
    ROWS = ".bt-user-msg, .bt-agent-msg, .bt-tool-msg"
    @test TK.wait_for(s, "the app mounted", "!!$(card("pg-app"))?.querySelector('.park-grow-app')"; timeout = 180) == true
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true

    # The reader leaves the bottom; the app is far above, out of view.
    top = TK.eval_js(s, """(() => { const c = $(chat), ch = c.__bt_chat;
        ch.setFollowMode(false); ch.cancelPendingScroll();
        c.scrollTop = c.scrollHeight - c.clientHeight - 300;
        c.dispatchEvent(new Event('scroll'));
        for (const e of c.querySelectorAll($(TK.json(ROWS)))) {
            if (e.offsetParent === null) continue;
            if (e.offsetTop >= c.scrollTop)
                return [(e.innerText || '').slice(0, 40), Math.round(e.offsetTop - c.scrollTop)];
        }
        return null; })()""")
    @test top !== nothing
    @test TK.eval_js(s, "(() => { const c = $(chat), n = $(card("pg-app")); return n.offsetParent !== null && n.offsetTop + n.offsetHeight < c.scrollTop; })()") == true

    # It grows there.
    TK.send_message(s, "grow it")
    @test TK.wait_for(s, "the grow eval done", done("pg-grow"); timeout = 120) == true
    @test TK.wait_for(s, "the app grown", "$(card("pg-app")).querySelector('.park-grow-app').style.height === '1500px'"; timeout = 30) == true
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true
    sleep(0.5)
    read_off = TK.eval_js(s, """(() => { const c = $(chat);
        const e = [...c.querySelectorAll($(TK.json(ROWS)))]
            .find(e => (e.innerText || '').slice(0, 40) === $(TK.json(top[1])));
        return e ? Math.round(e.offsetTop - c.scrollTop) : null; })()""")
    @test read_off !== nothing && abs(read_off - top[2]) <= 1
    @test TK.eval_js(s, "$(chat).__bt_chat.followMode") == false

    ctx = s.browser[]
    ECT.install_cursor(ctx)
    # The chat's own padding, left of every bubble.
    ECT.move_to(ctx, ECT.JS("(() => { const r = $(chat).getBoundingClientRect(); return [r.left + 3, r.top + r.height / 2]; })()"); duration = 0.05)
    TK.eval_js(s, """(() => { const c = $(chat);
        window.__pg = [];
        c.addEventListener('scroll', () => window.__pg.push(Math.round(c.scrollTop)));
        return true; })()""")
    # Up a wheel at a time until the app is in view.
    shown = false
    for _ in 1:80
        TK.eval_js(s, "window.__pg = []; true")
        ECT.wheel(ctx, -120; steps = 1)
        TK.wait_for(s, "the wheel step scrolled", "window.__pg.length > 0"; timeout = 5)
        sleep(0.1)
        # The step scrolled to one place only.
        @test length(unique(TK.eval_js(s, "window.__pg"))) == 1
        shown = TK.eval_js(s, "(() => { const c = $(chat), n = $(card("pg-app")); return n.offsetTop + n.offsetHeight > c.scrollTop; })()")
        shown && break
    end
    @test shown
    @test TK.eval_js(s, "$(card("pg-app")).querySelector('.park-grow-app').offsetHeight") == 1500

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
