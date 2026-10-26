@testitem "e2e:process_wait_messages" setup=[SharedServer] tags=[:e2e] begin
    if Sys.isunix()
        TK = SharedServer.TK
        target = Ref("")
        function agent(prompt)
            if startswith(prompt,"wait for")
                id = replace(prompt," "=>"-")
                return [TK.mcp_call("bt_process";real_process=true,id="start-$id",
                    arguments=Dict("action"=>"start","id"=>"waiting-job","argv"=>["sh","-c","sleep 300"],"label"=>"Waiting job")),
                    TK.mcp_call("bt_process";real_process=true,id=id,
                        arguments=Dict("action"=>"wait","id"=>"waiting-job","seconds"=>60)),
                    TK.text("Wait released: $prompt"),TK.delay(3000)]
            elseif prompt == "coordinate"
                return [TK.mcp_call("bt_dev_control";real_process=true,op="send_message",
                    project_id=target[],text="peer wakes process wait"),TK.text("Peer sent")]
            end
            return [TK.text("Received: $prompt"),TK.delay(3000)]
        end
        s = TK.dev_server(;agent,prompt_queueing=false,active_steering=true)
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes($(repr(t))))"
        waiting(id) = "!!$pane.querySelector('.bt-tool-body[data-tool-id=\"$id\"]') && !!$pane.querySelector('.bt-busy-active')"
        try
            TK.open_browser(s)
            sender = TK.new_chat(s;title="Process wait sender")
            TK.eval_js(s,"window.confirm=()=>true; $pane.querySelector('.bt-header-menu .bt-menu-trigger').click(); $pane.querySelector('.bt-header-devmode').click()")
            @test TK.wait_for(s,"peer tools enabled","$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-on')";timeout=60)
            target[] = TK.new_chat(s;title="Process wait receiver")
            TK.send_message(s,"wait for user")
            @test TK.wait_for(s,"process wait running",waiting("wait-for-user");timeout=90)
            TK.eval_js(s,"$pane.querySelector('.bt-send-mode-trigger').click(); $pane.querySelector(\"[data-send-mode='next']\").click()")
            TK.send_message(s,"user wakes process wait")
            @test TK.wait_for(s,"user reaches active process wait",says("Received: user wakes process wait");timeout=15)
            @test TK.wait_for(s,"user releases process wait", "$(says("Wait released: wait for user")) && !$pane.querySelector('.bt-busy-active')";timeout=15)
            @test TK.eval_js(s,"!!$pane.querySelector('.bt-process-task[data-process-status=\"running\"]')")
            TK.send_message(s,"wait for peer")
            @test TK.wait_for(s,"second process wait running",waiting("wait-for-peer");timeout=60)
            TK.open_chat(s,sender)
            TK.send_message(s,"coordinate")
            @test TK.wait_for(s,"peer sent",says("Peer sent");timeout=60)
            TK.open_chat(s,target[])
            @test TK.wait_for(s,"peer reaches active process wait",
                "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes('Received: Message from chat') && e.textContent.includes('peer wakes process wait'))";timeout=15)
            @test TK.wait_for(s,"peer releases process wait",says("Wait released: wait for peer");timeout=15)
            @test TK.eval_js(s,"!!$pane.querySelector('.bt-process-task[data-process-status=\"running\"]')")
            TK.screenshot(s,joinpath(tempdir(),"bonitoagents-process-wait-messages.png"))
            @test isempty(TK.js_errors(s))
        finally
            close(s)
        end
    end
end
