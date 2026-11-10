# An app package loaded into the running server from a chat, the way an agent
# that just wrote one does it: `bt_load_app` through the chat's real BonitoMCP
# process. Nothing loads until the user says so on the card the chat shows:
# declined, the agent hears it and no tile appears; the card outlives leaving
# the chat; approved, the dashboard that was open before shows the new tile
# without a reload, the chat that loaded it can call the app's tool at once (its
# control channel connected before the app existed), and the tile opens the
# app's chat with the app's own pane. The package is fixtures/HelloApp, a
# dependency of the test environment, so the load doesn't change the environment.
#
# Its own server: the loaded app would otherwise sit in every later item's dashboard.
@testitem "e2e:app_load" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    fixture = abspath(joinpath(@__DIR__, "..", "fixtures", "HelloApp"))
    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    # A tool card in the visible pane, once it ran: its status and its text
    # (the body expanded once).
    card(id) = """(() => {
        const c = $VP?.querySelector('.bt-tool-msg[data-msg-id*="$id"]'); if (!c) return false;
        const st = c.querySelector('.bt-tool-status')?.textContent || '';
        if (!(st === 'completed' || st === 'failed')) return false;
        const h = c.querySelector('.bt-tool-header');
        if (h && !c.dataset.probeExpanded) {
            c.dataset.probeExpanded = '1';
            if (h.dataset.expanded !== 'true') h.click();
            return false;
        }
        const body = c.querySelector('.bt-tool-body')?.innerText || '';
        return body ? [st, body] : false; })()"""
    TILE = "document.querySelector('.bt-app-tile[data-app=\"hello\"]')"
    CARD = "$VP?.querySelector('.bt-prompt-card[data-prompt-kind=\"app_load\"]')"
    ASK = ".bt-chatpane[aria-hidden=false] .bt-prompt-card[data-prompt-kind=\"app_load\"]"
    # The card asks to load this package, and asks nothing else (no password).
    card_shown = "$CARD?.querySelector('.bt-permission-question')?.textContent === " *
                 "'Load this app into the BonitoAgents server?' && " *
                 "$CARD.querySelector('.bt-prompt-job').textContent === 'HelloApp' && " *
                 "!$CARD.querySelector('input') && " *
                 "$CARD.querySelector('.bt-perm-allow').textContent === 'Load'"

    agent(p) = occursin("try loading", p) ?
        [TK.mcp_call("bt_load_app"; real_process = true, id = "ask", path = fixture),
         TK.text("Asked."), TK.end_turn()] :
               occursin("load the app", p) ?
        [TK.mcp_call("bt_load_app"; real_process = true, id = "load", path = fixture),
         TK.mcp_call("hello_greet"; real_process = true, id = "greet", name = "Ada"),
         TK.text("Loaded."), TK.end_turn()] :
        [TK.text("ok"), TK.end_turn()]
    s = TK.dev_server(agent = agent)
    try
        TK.open_browser(s)
        TK.to_dashboard(s)
        @test TK.wait_for(s, "the built-in app's tile",
            "!!document.querySelector('.bt-app-tile[data-app=\"todo\"]')"; timeout = 30) == true
        @test TK.eval_js(s, "!$TILE") == true

        pid = TK.new_chat(s; title = "LoadApp")

        # Declined: the agent hears it, and nothing loads.
        TK.send_message(s, "try loading the app")
        @test TK.wait_for(s, "the approval card", card_shown; timeout = 60) == true
        TK.click(s, "$ASK .bt-perm-reject")
        @test TK.wait_for(s, "the card gone", "!$CARD"; timeout = 30) == true
        st, text = TK.wait_for(s, "the declined load's card", card("ask"); timeout = 60)
        @test st == "failed"
        @test occursin("declined", text)
        TK.to_dashboard(s)
        @test TK.eval_js(s, "!$TILE") == true

        # Asked again. The card waits while the user is elsewhere, and still
        # nothing has loaded; back in the chat they approve it.
        TK.open_chat(s, pid)
        TK.send_message(s, "load the app I wrote")
        @test TK.wait_for(s, "the approval card again", card_shown; timeout = 60) == true
        TK.to_dashboard(s)
        @test TK.eval_js(s, "!$TILE") == true
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "the card after coming back", card_shown; timeout = 30) == true
        TK.click(s, "$ASK .bt-perm-allow")
        st, text = TK.wait_for(s, "the load's card", card("load"); timeout = 600)
        @test st == "completed"
        @test occursin("Started the app \"Hello\" (hello)", text)
        @test occursin("hello_greet", text)
        # No marker in its Project.toml: the agent is told it won't come back.
        @test occursin("plugin = true", text)
        st, text = TK.wait_for(s, "the app's tool, from the same chat", card("greet"); timeout = 60)
        @test (st, occursin("Hello, Ada!", text)) == ("completed", true)

        # The dashboard page from before the load: the tile is there, no reload.
        TK.to_dashboard(s)
        @test TK.wait_for(s, "the new tile, live",
            "$TILE?.querySelector('.bt-app-title')?.textContent === 'Hello'"; timeout = 30) == true
        @test TK.eval_js(s, "$TILE.querySelector('.bt-app-status').textContent") == "Not set up"
        @test TK.eval_js(s, "!!document.querySelector('.bt-app-tile[data-app=\"todo\"]')") == true

        # Set up once, then its chat shows the app's own pane.
        TK.click(s, ".bt-app-tile[data-app=\"hello\"] .bt-app-launch")
        @test TK.wait_for(s, "the setup dialog",
            "!!document.querySelector('.bw-modal-overlay .bt-app-setup .bt-app-choice.bt-on')"; timeout = 15) == true
        TK.click(s, ".bt-app-setup .bt-app-start")
        @test TK.wait_for(s, "the app chat with its pane",
            "$VP?.querySelector('.hello-pane')?.textContent === \"The Hello app's own pane\" && " *
            "!!$VP?.querySelector('.bt-text-input')"; timeout = 60) == true
        @test TK.eval_js(s, "$VP.dataset.panePid") != pid
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
