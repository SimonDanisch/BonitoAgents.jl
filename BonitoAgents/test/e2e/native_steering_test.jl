@testitem "e2e:native_steering" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    agent(p) = startswith(p, "original") ?
        [TK.text("Original task is running"), TK.delay(2000), TK.bash("echo boundary", "boundary"),
         TK.delay(2000), TK.bash("echo boundary again", "boundary again"),
         TK.delay(3000), TK.text("Original task finished")] :
        startswith(p, "cancel") ?
        [TK.text("Cancelable original is running"), TK.delay(2000),
         TK.bash("echo boundary", "boundary"), TK.delay(60000)] : [TK.text("Received: $p")]
    s = TK.dev_server(; agent, prompt_queueing = false, active_steering = true)
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    says(t) = "$pane.querySelector('.bt-messages').textContent.includes($(repr(t)))"
    idle = "!$pane.querySelector('.bt-busy-active')"
    try
        TK.open_browser(s)
        TK.new_chat(s; title = "Native steering without overlapping prompts")
        TK.send_message(s, "original task")
        @test TK.wait_for(s, "original streams", says("Original task is running"); timeout = 60)
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
            "$pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "first correction")
        TK.send_message(s, "second correction")
        @test TK.wait_for(s, "both native messages reach the running turn",
            "$(says("Received: first correction")) && $(says("Received: second correction"))"; timeout = 15)
        @test TK.eval_js(s, "!($(says("Original task finished")))")
        @test TK.wait_for(s, "the sole prompt completes and clears busy", "$(says("Original task finished")) && $idle"; timeout = 20)
        @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
        TK.reload!(s)
        @test TK.wait_for(s, "completion survives reload", "$(says("Original task finished")) && $idle"; timeout = 30)
        @test TK.eval_js(s, "[...$pane.querySelectorAll('.bt-user-msg')].filter(e => e.textContent === 'first correction').length === 1")
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
            "$pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "cancel original")
        @test TK.wait_for(s, "a new original streams", says("Cancelable original is running"); timeout = 30)
        TK.send_message(s, "correction before Stop")
        @test TK.wait_for(s, "native correction accepted", says("Received: correction before Stop"); timeout = 15)
        TK.eval_js(s, "$pane.querySelector('.bt-stop-btn').click()")
        @test TK.wait_for(s, "Stop clears the original prompt", idle; timeout = 20)
        TK.send_message(s, "follow-up after Stop")
        @test TK.wait_for(s, "the same session remains usable", "$(says("Received: follow-up after Stop")) && $idle"; timeout = 30)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-native-steering.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
