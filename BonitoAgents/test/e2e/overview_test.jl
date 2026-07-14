# Black-box e2e for the recent-chats overview in the dashboard header
# (overview.jl): cards appear for chats, carry the persistent title + message
# count + prompt snippets + last displayed image, update LIVE across turn
# boundaries (the busy hook → ROOT chat_signal fan-out — the root_state fix),
# and click-through opens the chat.
@testitem "e2e:overview" setup = [SharedServer] tags = [:e2e] begin
    S  = SharedServer
    s  = S.server()
    TK = S.TK
    using Test

    s.agent_fn[] = _prompt -> [TK.text("overview echo"), TK.end_turn()]
    TK.clear_js_errors(s)

    # A fresh chat with one turn — the card must materialise on the dashboard.
    pid = TK.new_chat(s)
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    TK.send_message(s, "overview probe prompt")
    @test TK.wait_for(s, "turn done",
        "[...document.querySelectorAll('.bt-agent-msg')].some(e => (e.innerText||'').includes('overview echo'))";
        timeout = 30) == true

    card_sel = ".bt-ov-card[data-project-id=\"$(pid)\"]"
    TK.to_dashboard(s)
    @test TK.wait_for(s, "overview section on the dashboard",
        "!!document.querySelector('.bt-overview')"; timeout = 10) == true
    @test TK.wait_for(s, "card for the fresh chat",
        "!!document.querySelector('$(card_sel)')"; timeout = 10) == true

    @testset "card carries title, count and the cleaned prompt snippet" begin
        card = TK.eval_js(s, """(() => {
            const c = document.querySelector('$(card_sel)');
            return { title: c.querySelector('.bt-ov-title')?.textContent,
                     meta:  c.querySelector('.bt-ov-meta')?.textContent,
                     snips: [...c.querySelectorAll('.bt-ov-snippet')].map(x => x.textContent) };
        })()""")
        # The first meaningful prompt backfills the persistent title.
        @test card["title"] == "overview probe prompt"
        @test occursin("2 messages", String(card["meta"]))     # user + agent reply
        @test any(t -> occursin("overview probe prompt", String(t)), card["snips"])
    end

    @testset "card updates LIVE on the next turn (root chat_signal fan-out)" begin
        # Send from the chat, then read the card on Home — the count must have
        # bumped with NO reload/manual poke. Regression for the busy hook
        # notifying only the creating session's chat_signal child.
        TK.open_chat(s, pid)
        TK.send_message(s, "second overview prompt")
        @test TK.wait_for(s, "second turn done",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e => (e.innerText||'').includes('overview echo')).length >= 2";
            timeout = 30) == true
        TK.to_dashboard(s)
        @test TK.wait_for(s, "card count bumped to 4",
            "(document.querySelector('$(card_sel) .bt-ov-meta')?.textContent || '').includes('4 messages')";
            timeout = 10) == true
        @test TK.eval_js(s,
            "[...document.querySelectorAll('$(card_sel) .bt-ov-snippet')].some(x => x.textContent.includes('second overview prompt'))") == true
    end

    @testset "attached image becomes the card thumbnail" begin
        TK.open_chat(s, pid)
        # Queue a VALID 1×1 PNG through the composer's blob path and send.
        TK.eval_js(s, """(() => {
            const b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
            const bin = atob(b64); const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const file = new File([bytes], 'ov-thumb.png', {type: 'image/png'});
            document.querySelector('$(P).bt-messages').__bt_chat
                ._attachAddBlob(file, file.type, file.name);
            return true;
        })()""")
        @test TK.wait_for(s, "thumb queued",
            "document.querySelectorAll('$(P).bt-attachment-thumb').length === 1"; timeout = 5) == true
        TK.send_message(s, "message with an image")
        @test TK.wait_for(s, "image turn done",
            "[...document.querySelectorAll('.bt-agent-msg')].filter(e => (e.innerText||'').includes('overview echo')).length >= 3";
            timeout = 30) == true
        TK.to_dashboard(s)
        @test TK.wait_for(s, "card thumb is the attachment",
            "(document.querySelector('$(card_sel) img.bt-ov-img')?.getAttribute('src') || '').startsWith('/attachment/$(pid)')";
            timeout = 10) == true
        # And it decodes (route serves real bytes + mime).
        @test TK.wait_for(s, "card thumb decodes",
            "(() => { const i = document.querySelector('$(card_sel) img.bt-ov-img'); return !!(i && i.complete && i.naturalWidth > 0); })()";
            timeout = 10) == true
    end

    @testset "clicking the card opens the chat" begin
        TK.eval_js(s, "document.querySelector('$(card_sel)').click(); true")
        @test TK.wait_for(s, "chat opened from card",
            "(() => { const a = document.querySelector('.bt-side-item.bt-side-active'); return !!a && a.getAttribute('data-project-id') === $(repr(pid)); })()";
            timeout = 10) == true
    end

    # Restore the default echo agent for the next soak suite.
    s.agent_fn[] = S.default_agent
    @test isempty(TK.js_errors(s))
end
