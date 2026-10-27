@testitem "e2e:wait_messages" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    target = Ref("")
    agent(p) = startswith(p, "wait for") ?
        [TK.mcp_call("bt_wait"; real_process = true, seconds = 60, reason = p,
            id = replace(p, " " => "-")),
         TK.text("Wait released: $p"), TK.delay(3000)] : p == "coordinate" ?
        [TK.mcp_call("bt_dev_control"; real_process = true, op = "send_message",
            project_id = target[], text = "peer wakes the wait"), TK.text("Peer sent")] :
        [TK.text("Received: $p"), TK.delay(3000)]
    s = TK.dev_server(; agent, prompt_queueing = false, active_steering = true)
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes($(repr(t))))"
    waiting(id) = "!!$pane.querySelector('.bt-tool-body[data-tool-id=\"$id\"]') && !!$pane.querySelector('.bt-busy-active')"
    try
        TK.open_browser(s)
        sender = TK.new_chat(s; title = "Wait sender")
        TK.eval_js(s, "window.confirm=()=>true; $pane.querySelector('.bt-header-menu .bw-menu-trigger').click(); $pane.querySelector('.bt-header-devmode').click()")
        @test TK.wait_for(s, "peer tools enabled", "$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-on')"; timeout = 60)
        target[] = TK.new_chat(s; title = "Wait receiver")
        TK.send_message(s, "wait for user")
        @test TK.wait_for(s, "user wait running", waiting("wait-for-user"); timeout = 60)
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); $pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "user wakes the wait")
        @test TK.wait_for(s, "user message delivered without a tool boundary", says("Received: user wakes the wait"); timeout = 15)
        @test TK.wait_for(s, "user message releases the minute-long wait", "$(says("Wait released: wait for user")) && !$pane.querySelector('.bt-busy-active')"; timeout = 15)
        TK.send_message(s, "wait for peer")
        @test TK.wait_for(s, "peer wait running", waiting("wait-for-peer"); timeout = 60)
        TK.eval_js(s, "$pane.querySelector('.bt-yolo-bar').click()")
        @test TK.wait_for(s, "receiver in YOLO", "$pane.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')"; timeout = 10)
        TK.open_chat(s, sender)
        TK.send_message(s, "coordinate")
        @test TK.wait_for(s, "peer sent", says("Peer sent"); timeout = 60)
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "stamped peer received during YOLO wait",
            "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes('Received: Message from chat') && " *
            "e.textContent.includes('Sent at (server UTC):') && e.textContent.includes('peer wakes the wait'))"; timeout = 15)
        @test TK.wait_for(s, "peer releases the minute-long wait", says("Wait released: wait for peer"); timeout = 15)
        @test TK.eval_js(s, "$pane.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')")
        TK.eval_js(s, "$pane.querySelector('.bt-stop-btn').click()")
        @test TK.wait_for(s, "Stop remains usable", "!$pane.querySelector('.bt-busy-active')"; timeout = 20)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-wait-messages.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
