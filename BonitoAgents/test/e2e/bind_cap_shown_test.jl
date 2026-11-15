# Two empty chats on screen in two tabs closed each other forever (2026-11-15).
# The server keeps at most BIND_CAP agents alive and, when it must close one,
# prefers a chat without messages. But a new chat binds as it opens, and a tab
# whose chat was closed opens it again: the empty chat came straight back and
# closed the other empty one, which its own tab opened again. Both tabs flipped
# between the chat and the loading card every 1.6 s. An empty chat on screen is
# no longer closed; the cap takes the oldest idle chat with messages.
#
# Its own server: it opens nine chats, which would sit in every later item's
# sidebar.
@testitem "e2e:bind_cap_shown" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    s = TK.dev_server(agent = p -> [TK.text("reply to: $(p)"), TK.end_turn()])
    PANE(pid) = "document.querySelector('.bt-chatpane[data-pane-pid=\"$(pid)\"]')"
    shown(pid) = "(p => !!p && p.getAttribute('aria-hidden') !== 'true' && p.dataset.btSettled === '1')($(PANE(pid)))"
    replied(t, text) = TK.wait_for(t, "the reply to $(text)",
        "($(PANE(TK.eval_js(t, "document.querySelector('.bt-main-views').dataset.activeView")))?.textContent || '').includes('reply to: $(text)')";
        timeout = 60)
    # From here on: what the tab shows, every 50 ms (its chat, the loading card).
    record = """(() => { window.__seen = []; const t0 = performance.now();
        window.__seenTimer = setInterval(() => {
            const view = document.querySelector('.bt-main-views').dataset.activeView || '';
            const p = document.querySelector('.bt-chatpane[data-pane-pid="' + view + '"]');
            const card = [...document.querySelectorAll('.bt-view-overlay .bt-loading-wrap')].some(c =>
                c.offsetParent !== null && getComputedStyle(c).visibility !== 'hidden' && c.style.display !== 'none');
            const kind = !view ? 'home' : card ? 'card' : (p && p.getAttribute('aria-hidden') !== 'true' && p.dataset.btSettled) ? 'pane' : 'blank';
            const last = window.__seen[window.__seen.length - 1];
            if (!last || last[1] !== kind) window.__seen.push([Math.round(performance.now() - t0), kind]);
        }, 50); return true; })()"""
    kinds(t) = [k for (_, k) in TK.eval_js(t, "window.__seen")]
    try
        TK.open_browser(s)
        a = TK.new_chat(s; title = "EmptyA")
        @test TK.wait_for(s, "empty A on screen", shown(a); timeout = 30) == true
        # A new tab restores A from localStorage; wait for that before new_chat
        # clicks Home, or the restore can undo the click.
        other = TK.another_tab(s)
        @test TK.wait_for(other, "the other tab restored A", shown(a); timeout = 60) == true
        # Chats with messages until the cap is full, A with them.
        fills = map(1:(TK.BT.BIND_CAP - 1)) do i
            pid = TK.new_chat(other; title = "Fill$(i)")
            TK.send_message(other, "fill $(i)")
            @test replied(other, "fill $(i)") == true
            pid
        end
        TK.eval_js(s, record)
        # B binds as it opens: one agent over the cap.
        b = TK.new_chat(other; title = "EmptyB")
        @test TK.wait_for(other, "empty B on screen", shown(b); timeout = 30) == true
        TK.eval_js(other, record)
        TK.send_message(other, "hello b")
        @test replied(other, "hello b") == true
        TK.send_message(s, "hello a")
        @test replied(s, "hello a") == true
        # Neither chat was closed under its tab.
        @test kinds(s) == ["pane"]
        @test kinds(other) == ["pane"]
        # The cap closed the oldest chat with messages: opening it shows the
        # loading card, then its rows.
        TK.eval_js(s, "window.__seen = []; true")
        fill1 = first(fills)
        TK.open_chat(s, fill1)
        @test TK.wait_for(s, "fill 1 back", "$(shown(fill1)) && $(PANE(fill1)).textContent.includes('reply to: fill 1')";
            timeout = 60) == true
        @test "card" in kinds(s)
        for t in (s, other)
            TK.eval_js(t, "clearInterval(window.__seenTimer); true")
        end
        @test isempty(TK.js_errors(s))
        @test isempty(TK.js_errors(other))
        TK.close_browser!(other)
    finally
        close(s)
    end
end
