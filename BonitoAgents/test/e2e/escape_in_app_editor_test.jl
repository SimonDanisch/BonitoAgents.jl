# ESC anywhere stops the agent's turn, but not in a field the user types in
# other than the composer: Monaco, and since 2026-11-16 any contentEditable in
# an app's pane (a draft's text in Community) and any other input, such as the
# sidebar's search. There ESC leaves the field; it used to stop the agent and
# pause the chat's queue as well.
@testitem "e2e:escape_in_app_editor" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    env = abspath(joinpath(@__DIR__, "..", "evalenv"))
    app = """
        using Bonito
        App() do
            DOM.div("edit me"; class = "esc-editor", contenteditable = "true")
        end"""
    s.agent_fn[] = _ -> [TK.bt_eval(app; env_path = env, id = "esc-app"), TK.text("still working"),
                         TK.delay(60000), TK.end_turn()]
    EDITOR = "document.querySelector('.bt-chatpane[aria-hidden=false] .esc-editor')"
    BUSY = "!!document.querySelector('.bt-busy.bt-busy-active')"
    try
        TK.new_chat(s; title = "EscEditor")
        TK.send_message(s, "show an editor")
        @test TK.wait_for(s, "the app's editor", "!!$EDITOR"; timeout = 180) == true
        @test TK.wait_for(s, "the turn running", BUSY; timeout = 60) == true

        TK.eval_js(s, "$EDITOR.focus(); true")
        @test TK.eval_js(s, "document.activeElement === $EDITOR") == true
        TK.press_key!(s, "Escape")
        # Nor does the sidebar's search: its ESC clears it.
        TK.set_input(s, ".bt-side-search", "esc")
        @test TK.eval_js(s, "document.activeElement === document.querySelector('.bt-side-search')") == true
        TK.press_key!(s, "Escape")
        window = 3.0
        sleep(window)
        @test TK.eval_js(s, BUSY) == true
        @test TK.eval_js(s, "document.querySelector('.bt-side-search').value") == ""

        # ESC elsewhere still stops it, and faster than the window above: had
        # the first one cancelled, the turn would have ended inside it.
        TK.eval_js(s, "$EDITOR.blur(); true")
        t = time()
        TK.press_key!(s, "Escape")
        @test TK.wait_for(s, "ESC elsewhere stops the turn", "!$BUSY"; timeout = 20) == true
        @test time() - t < window
        @test isempty(TK.js_errors(s))
    finally
        s.agent_fn[] = S.default_agent
    end
end
