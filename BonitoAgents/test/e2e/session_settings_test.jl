@testitem "e2e:session_settings" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    s = TK.dev_server(; session_config = true, agent = p -> [TK.text("Received: $p")])
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    picker(category) = "[...$pane.querySelectorAll('.bt-msearch')].find(w => w.querySelector('.bt-msearch-trigger')?.textContent.trim().startsWith('$category:'))"
    choices = "[...($(picker("model")))?.querySelectorAll('.bt-msearch-item') ?? []].map(e => e.textContent.trim())"
    pick(category, value) = TK.eval_js(s, "($(picker(category))).querySelector('.bt-msearch-trigger').click(); " *
        "[...($(picker(category))).querySelectorAll('.bt-msearch-item')].find(e => e.textContent.trim().toLowerCase() === $(repr(lowercase(value)))).click()")
    reply(text) = "$pane.querySelector('.bt-messages').textContent.includes($(repr("Received: " * text * " (effective permissions: full)")))"
    try
        TK.open_browser(s)
        TK.new_chat(s; title = "Confirmed session settings")
        @test TK.wait_for(s, "first provider model choices", "JSON.stringify($choices) === '[\"Alpha\",\"Beta\"]'"; timeout = 60)
        pick("model", "Beta")
        pick("permissions", "Full access")
        TK.send_message(s, "immediately after choosing full access")
        @test TK.wait_for(s, "prompt waits for full access confirmation", reply("immediately after choosing full access"); timeout = 30)

        # Switch while the old model choice is persisted. The new provider has
        # different model ids, and starts in auto-review until settings settle.
        TK.switch_agent(s, "Mock Agent 2")
        @test TK.wait_for(s, "new provider replaces all model choices", "JSON.stringify($choices) === '[\"Gamma\",\"Delta\"]'"; timeout = 60)
        TK.send_message(s, "first prompt on the new agent")
        @test TK.wait_for(s, "first new-agent prompt uses saved permissions", reply("first prompt on the new agent"); timeout = 30)
        @test TK.eval_js(s, "($(picker("model"))).querySelector('.bt-msearch-value').textContent === 'Gamma'")
        @test TK.eval_js(s, "JSON.stringify($choices) === '[\"Gamma\",\"Delta\"]'")
        TK.reload!(s)
        @test TK.wait_for(s, "new choices survive reload", "JSON.stringify($choices) === '[\"Gamma\",\"Delta\"]'"; timeout = 30)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-confirmed-session-settings.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
