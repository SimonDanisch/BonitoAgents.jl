@testitem "e2e:prompt_receipts" setup=[SharedServer] tags=[:e2e] begin
    TK = SharedServer.TK
    agent(prompt) = occursin("long original", prompt) ?
        [TK.text("Working before the next boundary"), TK.delay(2000),
         TK.bash("echo boundary", "boundary"), TK.delay(30000), TK.text("Original finished")] :
        [TK.text("Actually received: " * prompt)]
    s = TK.dev_server(; agent, receipt_delay_ms=15000)
    try
        TK.open_browser(s)
        pid = TK.new_chat(s; title="Receipt before history")
        pane = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
        queue = "$pane.querySelector('.bt-queue-item')"
        users = "[...$pane.querySelectorAll('.bt-user-msg')].map(e=>e.textContent)"
        says(t) = "$pane.textContent.includes($(repr(t)))"
        idle = "!$pane.querySelector('.bt-busy-active')"
        TK.send_message(s, "long original")
        @test TK.wait_for(s, "original is running", says("Working before the next boundary"); timeout=60)
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
            "$pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "free the scene without manual trimming")
        @test TK.wait_for(s, "written prompt still awaits real receipt",
            "$queue?.dataset.status === 'submitted'"; timeout=15)
        @test TK.eval_js(s, "!$users.includes('free the scene without manual trimming')")
        TK.eval_js(s, "$pane.querySelector('.bt-stop-btn').click()")
        @test TK.wait_for(s, "cancelled queued input is retained",
            "$queue?.dataset.status === 'paused' && $idle"; timeout=30)
        @test TK.eval_js(s, "!$(says("Actually received: free the scene"))")
        @test TK.eval_js(s, "!$users.includes('free the scene without manual trimming')")
        TK.reload!(s)
        @test TK.wait_for(s, "undelivered instruction survives reload",
            "$queue?.dataset.status === 'paused' && $idle"; timeout=30)
        TK.eval_js(s, "$queue.querySelector('summary').click(); " *
            "$queue.querySelector(\"[data-queue-action='send']\").click()")
        @test TK.wait_for(s, "retry is actually received and answered",
            "$(says("Actually received: free the scene without manual trimming")) && !$queue && $idle";
            timeout=30)
        @test TK.eval_js(s, "$users.filter(t=>t==='free the scene without manual trimming').length === 1")
        TK.reload!(s)
        @test TK.wait_for(s, "confirmed history stays consistent after reload",
            "$(says("Actually received: free the scene without manual trimming")) && !$queue && $idle";
            timeout=30)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-prompt-receipts.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end

@testitem "e2e:prompt_receipt_wait" setup=[SharedServer] tags=[:e2e] begin
    TK = SharedServer.TK
    target = Ref("")
    agent(p) = startswith(p, "wait for") ?
        [TK.mcp_call("bt_wait"; real_process=true, seconds=60, reason=p,
            id=replace(p," "=>"-")), TK.text("Wait released: $p")] : p == "coordinate" ?
        [TK.mcp_call("bt_chat"; real_process=true, action="send",
            project_id=target[], text="peer wakes receipt wait"), TK.text("Coordination sent")] :
        [TK.text("Received: $p")]
    s = TK.dev_server(; agent, receipt_delay_ms=1500)
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e=>e.textContent.includes($(repr(t))))"
    waiting(id) = "!!$pane.querySelector('.bt-tool-body[data-tool-id=\"$id\"]') && !!$pane.querySelector('.bt-busy-active')"
    try
        TK.open_browser(s)
        sender = TK.new_chat(s; title="Receipt coordinator")
        TK.set_chat_messaging(s)
        target[] = TK.new_chat(s; title="Acknowledged queue receiver")
        TK.set_chat_messaging(s)
        TK.send_message(s, "wait for user receipt")
        @test TK.wait_for(s, "voluntary wait is running", waiting("wait-for-user-receipt"); timeout=60)
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
            "$pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "user wakes receipt wait")
        @test TK.wait_for(s, "user releases the wait and reaches the agent",
            "$(says("Wait released: wait for user receipt")) && $(says("Received: user wakes receipt wait")) && " *
            "!$pane.querySelector('.bt-queue-item') && !$pane.querySelector('.bt-busy-active')"; timeout=15)
        TK.send_message(s, "wait for peer receipt")
        @test TK.wait_for(s, "peer wait is running", waiting("wait-for-peer-receipt"); timeout=60)
        TK.open_chat(s, sender)
        TK.send_message(s, "coordinate")
        @test TK.wait_for(s, "peer sent its message", says("Coordination sent"); timeout=60)
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "peer releases the wait and reaches the agent",
            "$(says("Wait released: wait for peer receipt")) && $(says("peer wakes receipt wait")) && " *
            "!$pane.querySelector('.bt-queue-item') && !$pane.querySelector('.bt-busy-active')"; timeout=15)
        @test TK.eval_js(s, "[...$pane.querySelectorAll('.bt-user-msg')].filter(e=>e.textContent.includes('peer wakes receipt wait')).length === 1")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
