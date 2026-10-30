@testitem "e2e:peer_messages" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    target = Ref("")
    agent(prompt) = if prompt == "coordinate"
        [TK.mcp_call("bt_chat"; real_process = true, action = "send",
                     project_id = target[], text = "GPU is available", id = "peer-send"),
         TK.text("Coordination sent")]
    elseif prompt == "keep working"
        [TK.text("Working on the original task"),
         [e for _ in 1:15 for e in (TK.delay(2000), TK.bash("echo boundary", "boundary"))]...,
         TK.text("Original task finished")]
    else
        [TK.text("Received: " * prompt)]
    end
    s = TK.dev_server(; agent, prompt_queueing = false, active_steering = true)
    try
        TK.open_browser(s)
        sender = TK.new_chat(s; title = "Sending agent")
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        TK.set_chat_messaging(s)
        @test TK.eval_js(s, "!$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-on')")
        target[] = TK.new_chat(s; title = "Receiving agent")
        TK.set_chat_messaging(s)
        TK.send_message(s, "keep working")
        @test TK.wait_for(s, "receiver working", "$pane.textContent.includes('Working on the original task')"; timeout = 60)
        TK.open_chat(s, sender)
        TK.send_message(s, "coordinate")
        @test TK.wait_for(s, "sender sent coordination", "$pane.textContent.includes('Coordination sent')"; timeout = 60)
        TK.open_chat(s, target[])
        received = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => " *
            "e.textContent.includes('Received: Message from chat') && e.textContent.includes($(repr("chat ID: $sender"))) && " *
            "e.textContent.includes('Sent at (server UTC):') && e.textContent.includes('Dispatched at (server UTC):') && " *
            "e.textContent.includes('Message ID:') && e.textContent.includes('GPU is available'))"
        @test TK.wait_for(s, "peer receives identity and timestamps during work", received; timeout = 30)
        @test TK.eval_js(s, "!$pane.textContent.includes('Original task finished')")
        message_js = "[...$pane.querySelectorAll('.bt-user-msg')].find(e => e.textContent.includes('GPU is available'))?.textContent"
        stamped = TK.eval_js(s, message_js)
        @test occursin("chat ID: $sender", stamped)
        @test TK.eval_js(s, "(() => { const t=$message_js; " *
            "const sent=t.split('Sent at (server UTC): ')[1]?.split(String.fromCharCode(10))[0]; " *
            "const dispatched=t.split('Dispatched at (server UTC): ')[1]?.split(String.fromCharCode(10))[0]; " *
            "return sent.endsWith('Z') && dispatched.endsWith('Z') && Date.parse(dispatched) >= Date.parse(sent); })()")
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-peer-message-during-work.png"))
        @test TK.wait_for(s, "original task completes normally",
            "$pane.textContent.includes('Original task finished') && !$pane.querySelector('.bt-busy-active')"; timeout = 45)
        @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
        TK.reload!(s)
        @test TK.wait_for(s, "peer metadata survives reload", received; timeout = 30)
        @test TK.eval_js(s, message_js) == stamped

        # With no active turn the same tool goes through ordinary prompt
        # delivery. It must stamp that path too, rather than only steering.
        target[] = TK.new_chat(s; title = "Idle receiver")
        TK.set_chat_messaging(s)
        TK.open_chat(s, sender)
        TK.send_message(s, "coordinate")
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "ordinary peer prompt includes metadata",
            "$received && !$pane.querySelector('.bt-busy-active')"; timeout = 45)
        @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
