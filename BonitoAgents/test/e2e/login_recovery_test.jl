# The tabs of one browser share one login behind Authelia: it ends for all of
# them at once (Authelia restarted, a logout) and is back for all of them with
# one login in any tab. Every login hands out a new session and drops the one
# the other tabs are using, so a tab that sends the browser to a login it
# already has throws the other tabs out mid-request. After an Authelia restart
# that went on for hours: each stale tab's login threw out the next.
#
# Own dev server (NOT SharedServer's): the tunnel has to be in front.

@testitem "e2e:login_recovery" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; tunnel = true, agent = p -> [TK.text("reply to: " * p), TK.end_turn()])
    tabs = TK.TestServer[]
    logout!(s) = TK.eval_js(s, """fetch('/authelia/api/logout', {method: 'POST',
        headers: {'Content-Type': 'application/json'}, body: '{}'}).then(r => r.status)""")
    card = "document.querySelector('.bt-login-ended.bt-conn-open')"
    led = "document.querySelector('.bt-conn-led')"
    # The login page, as a tab whose login ended lands on it.
    login_page(s) = TK.wait_for(s, "the login page",
        "location.pathname.startsWith('/authelia') && !!document.querySelector('#username-textfield')"; timeout = 30)
    function new_tab(route = "/")
        tab = TK.another_tab(z; route)
        push!(tabs, tab)
        return tab
    end
    try
        TK.open_browser(z)
        TK.login!(z)
        first_chat = TK.new_chat(z; title = "FirstChat")
        TK.send_message(z, "first chat")
        TK.wait_for(z, "the first reply", "document.body.textContent.includes('reply to: first chat')"; timeout = 60)
        second_chat = TK.new_chat(z; title = "SecondChat")
        TK.send_message(z, "second chat")
        TK.wait_for(z, "the second reply", "document.body.textContent.includes('reply to: second chat')"; timeout = 60)
        TK.click(z, ".bt-side-item[data-project-id=\"$first_chat\"]")
        TK.navigate(z, "/")                       # a page that has shown neither chat
        second_pane = """document.querySelector('.bt-chatpane[data-pane-pid="$second_chat"] .bt-messages')"""
        @test TK.eval_js(z, "!$second_pane") == true

        @testset "a chat opened after the login ended comes up after the login" begin
            @test logout!(z) == 200
            TK.click(z, ".bt-side-item[data-project-id=\"$second_chat\"]")
            # Its messages were turned away: the tab says why instead of
            # showing an empty chat.
            @test TK.wait_for(z, "the login card", "!!$card"; timeout = 15) == true
            @test TK.eval_js(z, "!document.body.textContent.includes('reply to: second chat')") == true
            # The user logs in in a new tab ("Log in (new tab)").
            tab = new_tab()
            login_page(tab)
            TK.login!(tab)
            @test TK.wait_for(z, "the chat comes up",
                "!!$second_pane?.textContent.includes('reply to: second chat')"; timeout = 30) == true
            @test TK.eval_js(z, "!$card") == true
            TK.close_browser!(tab)
        end

        @testset "a connection that drops after the login ended says so" begin
            # Seen 2026-10-17: an update restarted Authelia, which keeps logins in
            # memory; the open tab worked on over its websocket, and when that
            # dropped the gate turned every reconnect away. The card said
            # "Reconnecting to the server" forever: a hung server, to the user.
            @test logout!(z) == 200
            TK.eval_js(z, "window.WEBSOCKET.close(); true")
            @test TK.wait_for(z, "the login card, not reconnecting", "!!$card"; timeout = 30) == true
            # The user logs in in a new tab; this one reconnects by itself.
            tab = new_tab()
            login_page(tab)
            TK.login!(tab)
            @test TK.wait_for(z, "connected again, no card", """$(led)?.dataset.status === 'connected' &&
                !$card && !document.querySelector('.bt-conn-modal.bt-conn-open')"""; timeout = 60,
                describe = """JSON.stringify({led: $(led)?.dataset.status, card: !!$card,
                    open: [...document.querySelectorAll('.bt-conn-modal.bt-conn-open')].map(m => m.dataset.status),
                    ws: !!window.WEBSOCKET && window.WEBSOCKET.isopen(), path: location.pathname})""") == true
            TK.close_browser!(tab)
            # The turned-away reconnects are in the console (the browser's own
            # words for a refused websocket); that is this test's doing.
            errs = TK.js_errors(z)
            @test all(e -> occursin("WebSocket", e["message"]), errs)
            TK.clear_js_errors(z)
        end

        @testset "a page the server no longer has waits for the login, then reloads" begin
            # The server restarted with Authelia: the page's session and its
            # login are gone. Reloaded at once, it would land on the login page.
            @test logout!(z) == 200
            path = TK.eval_js(z, "location.pathname")
            TK.eval_js(z, "window.__before_reload = true; true")
            TK.eval_js(z, "Bonito.on_connection_expired(); true")
            @test TK.wait_for(z, "the login card", "!!$card"; timeout = 15) == true
            sleep(2)
            @test TK.eval_js(z, "window.__before_reload === true && location.pathname") == path
            tab = new_tab()
            login_page(tab)
            TK.login!(tab)
            @test TK.wait_for(z, "the reload after the login",
                "window.__before_reload === undefined && $(led)?.dataset.status === 'connected'"; timeout = 60) == true
            @test TK.eval_js(z, "location.pathname") == path
            TK.close_browser!(tab)
        end

        @testset "no login page while the browser is logged in" begin
            # Two stale tabs on the login page; the user logs in in one of them.
            @test logout!(z) == 200
            stale = new_tab()
            login_page(stale)
            tab = new_tab()
            login_page(tab)
            TK.login!(tab)
            # The other one leaves for the dashboard instead of offering a
            # second login, which would throw this one out.
            @test TK.wait_for(stale, "the stale login page leaving",
                "location.pathname === '/' && !!document.querySelector('.bt-dash')"; timeout = 30) == true
            # Authelia's own pages, opened while logged in, stay.
            TK.eval_js(stale, "location.href = '/authelia/settings'; true")
            @test TK.wait_for(stale, "Authelia's settings page",
                "location.pathname === '/authelia/settings' && document.readyState === 'complete'"; timeout = 30) == true
            TK.navigate(tab, "/")                 # another tab announces the login
            TK.eval_js(stale, "window.dispatchEvent(new Event('focus')); document.dispatchEvent(new Event('visibilitychange')); true")
            sleep(2)
            @test TK.eval_js(stale, "location.pathname") == "/authelia/settings"
        end
        @test isempty(TK.js_errors(z))
    finally
        foreach(TK.close_browser!, tabs)
        close(z)
    end
end
