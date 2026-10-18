# A chat on screen can lose its model to something outside its tab: the server
# closing idle chats to keep at most a few agents alive, or a ✕ in another tab.
# The view used to go blank, with no loading card and no way back short of a
# second click: the pane went with the model, and the overlay still held the
# hidden card of a settled pane. Closed by the server, the tab now shows the
# loading card and the chat comes back; closed with ✕, it goes home, as the ✕
# does in its own tab.
#
# Its own server: it opens a dozen chats, which would sit in every later item's
# sidebar.
@testitem "e2e:chat_closed_under_tab" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    s = TK.dev_server(agent = p -> [TK.text("reply to: $(p)"), TK.end_turn()])
    PANE(pid) = "document.querySelector('.bt-chatpane[data-pane-pid=\"$(pid)\"]')"
    shown(pid) = "(p => !!p && p.style.display === 'flex' && p.dataset.btSettled === '1')($(PANE(pid)))"
    replied(t, text) = TK.wait_for(t, "the reply to $(text)",
        "($(PANE(TK.eval_js(t, "document.querySelector('.bt-main-views').dataset.activeView")))?.textContent || '').includes('reply to: $(text)')";
        timeout = 60)
    try
        TK.open_browser(s)
        x = TK.new_chat(s; title = "UnderX")
        TK.send_message(s, "hello x")
        @test replied(s, "hello x") == true
        @test TK.wait_for(s, "x on screen", shown(x); timeout = 30) == true
        # From here on: what the first tab shows, every 50 ms.
        TK.eval_js(s, """(() => { window.__seen = []; const t0 = performance.now();
            window.__seenTimer = setInterval(() => {
                const view = document.querySelector('.bt-main-views').dataset.activeView || '';
                const p = document.querySelector('.bt-chatpane[data-pane-pid="' + view + '"]');
                const card = [...document.querySelectorAll('.bt-view-overlay .bt-loading-wrap')].some(c =>
                    c.offsetParent !== null && getComputedStyle(c).visibility !== 'hidden' && c.style.display !== 'none');
                const kind = !view ? 'home' : card ? 'card' : (p && p.style.display === 'flex' && p.dataset.btSettled) ? 'pane' : 'blank';
                const last = window.__seen[window.__seen.length - 1];
                if (!last || last[1] !== kind) window.__seen.push([Math.round(performance.now() - t0), kind]);
            }, 50); return true; })()""")

        # ── closed by the server ────────────────────────────────────────────
        # Another tab opens chats until the cap on live agents closes the oldest
        # idle one, which is X (every chat has a message, so none is preferred).
        other = TK.another_tab(s)
        TK.wait_for(other, "the other tab's dashboard", "!!document.querySelector('.bt-dash')"; timeout = 60)
        for i in 1:TK.BT.BIND_CAP
            TK.new_chat(other; title = "Fill$(i)")
            TK.send_message(other, "fill $(i)")
            @test replied(other, "fill $(i)") == true
        end
        # The first tab showed X's loading card, and X came back, rows and all.
        @test TK.wait_for(s, "x back", "$(shown(x)) && $(PANE(x)).textContent.includes('reply to: hello x')"; timeout = 60) == true
        seen = TK.eval_js(s, "window.__seen")
        kinds = [k for (_, k) in seen]
        @test "card" in kinds                       # the cap did close X under the tab
        @test last(kinds) == "pane"
        blanks = [seen[i+1][1] - seen[i][1] for i in 1:(length(seen) - 1) if seen[i][2] == "blank"]
        @test all(<(500), blanks)                    # never blank for longer than a render

        # ── closed with ✕ in the other tab ──────────────────────────────────
        TK.eval_js(other, "document.querySelector('.bt-side-item[data-project-id=\"$(x)\"] .bt-side-close').click(); true")
        @test TK.wait_for(s, "home", """document.querySelector('.bt-main-views').dataset.activeView === '' &&
            document.querySelector('.bt-view-dash').style.display === 'flex'"""; timeout = 30) == true
        @test TK.wait_for(s, "x gone from the sidebar",
            "!document.querySelector('.bt-side-item[data-project-id=\"$(x)\"]')"; timeout = 30) == true
        TK.eval_js(s, "clearInterval(window.__seenTimer); true")
        @test isempty(TK.js_errors(s))
        @test isempty(TK.js_errors(other))
        TK.close_browser!(other)
    finally
        close(s)
    end
end
