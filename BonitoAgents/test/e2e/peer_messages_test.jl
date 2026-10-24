@testitem "e2e:peer_messages" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    target = Ref("")
    agent(prompt) = if prompt == "coordinate"
        [TK.mcp_call("bt_dev_control"; real_process = true, op = "send_message",
                     project_id = target[], text = "GPU is available", id = "peer-send"),
         TK.text("Coordination sent")]
    elseif prompt == "keep working"
        [TK.text("Working on the original task"),
         [e for _ in 1:15 for e in (TK.delay(2000), TK.bash("echo boundary", "boundary"))]...,
         TK.text("Original task finished")]
    else
        [TK.text("Received: " * prompt)]
    end
    s = TK.dev_server(; agent)
    try
        TK.open_browser(s)
        sender = TK.new_chat(s; title = "Sending agent")
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        TK.eval_js(s, "window.confirm = () => true; $pane.querySelector('.bt-header-menu .bt-menu-trigger').click(); " *
            "$pane.querySelector('.bt-header-devmode').click()")
        @test TK.wait_for(s, "sender dev tools enabled",
            "$pane.querySelector('.bt-header-devmode')?.classList.contains('bt-cap-on') === true"; timeout = 30)
        target[] = TK.new_chat(s; title = "Receiving agent")
        TK.send_message(s, "keep working")
        @test TK.wait_for(s, "receiver working", "$pane.textContent.includes('Working on the original task')"; timeout = 60)
        TK.open_chat(s, sender)
        TK.send_message(s, "coordinate")
        @test TK.wait_for(s, "sender sent coordination", "$pane.textContent.includes('Coordination sent')"; timeout = 60)
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "peer message received during work", "$pane.textContent.includes('Received: GPU is available')"; timeout = 30)
        @test TK.eval_js(s, "!$pane.textContent.includes('Original task finished')")
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-peer-message-during-work.png"))
        @test TK.wait_for(s, "original task completes normally",
            "$pane.textContent.includes('Original task finished') && !$pane.querySelector('.bt-busy-active')"; timeout = 45)
        @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
