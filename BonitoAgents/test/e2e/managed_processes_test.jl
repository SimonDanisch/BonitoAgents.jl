@testitem "e2e:managed_processes" setup=[SharedServer] tags=[:e2e] begin
    if Sys.isunix()
        TK = SharedServer.TK
        s = SharedServer.server()
        cwd = mktempdir()
        call(action;card="process-"*action,kw...) = TK.mcp_call("bt_process";id=card,real_process=true,
            arguments=merge(Dict{String,Any}("action"=>action,"id"=>"render-1"),Dict(string(k)=>v for (k,v) in kw)))
        s.agent_fn[] = prompt -> if prompt == "start managed"
            [call("start";argv=["sh","-c","trap '' INT TERM; echo managed-ready; sleep 300 & wait"],label="Managed render",cwd),TK.end_turn()]
        elseif prompt == "repeat managed"
            [call("start";card="process-repeat",argv=["sh","-c","trap '' INT TERM; echo managed-ready; sleep 300 & wait"],label="Managed render",cwd),TK.end_turn()]
        elseif prompt == "inspect managed"
            [call("status"),TK.end_turn()]
        elseif prompt == "wait managed"
            [call("wait";seconds=0.5),TK.end_turn()]
        elseif prompt == "restart fixture"
            [call("start";card="process-restart-start",id="restart-1",argv=["sh","-c","echo restart-ready; sleep 300"],label="Restart fixture",cwd),TK.end_turn()]
        elseif prompt == "inspect restarted"
            [call("status";card="process-after-restart",id="restart-1"),TK.end_turn()]
        else
            [TK.text("Received notification"),TK.end_turn()]
        end
        pid = TK.new_chat(s;cwd,title="Supervised commands")
        vp = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
        task(id="render-1") = "$vp.querySelector('.bt-process-task[data-process-id=\"$id\"]')"
        card(id) = "$vp.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
        function result_says(id,text)
            target = card(id)
            return """(() => {
                const c = $target; if (!c) return false;
                if (!c.dataset.processTestOpen) { c.dataset.processTestOpen='1'; c.querySelector('.bt-tool-header').click(); }
                return c.innerText.includes($(repr(text)));
            })()"""
        end
        try
            TK.send_message(s,"start managed")
            @test TK.wait_for(s,"worker job is in the taskbar with live output",
                "!!$(task()) && $(task()).textContent.includes('managed-ready') && !$vp.querySelector('.bt-busy-active')";timeout=120)
            @test TK.eval_js(s,"$(task()).textContent.includes('Managed render')")
            @test TK.eval_js(s,"$(task()).title.includes($(repr(cwd)))")
            TK.send_message(s,"repeat managed")
            @test TK.wait_for(s,"repeated start finishes",result_says("process-repeat","running");timeout=30)
            @test TK.eval_js(s,"$vp.querySelectorAll('.bt-process-task[data-process-id=\"render-1\"]').length") == 1
            TK.reload!(s)
            @test TK.wait_for(s,"reload retains the managed process and output",
                "!!$(task()) && $(task()).textContent.includes('managed-ready')";timeout=30)
            TK.drop_worker_connection!(s)
            @test TK.wait_for(s,"reconnect retains the same managed job",
                "!!$(task()) && $(task()).dataset.processStatus === 'running' && !$(task()).textContent.includes('worker disconnected')";timeout=30)
            TK.send_message(s,"wait managed")
            @test TK.wait_for(s,"bounded wait returns without ending the job",result_says("process-wait","timeout");timeout=30)
            @test TK.eval_js(s,"$(task()).dataset.processStatus") == "running"
            TK.eval_js(s,"$(task()).querySelector('.bt-taskbar-slot-stop').click(); true")
            @test TK.wait_for(s,"uncooperative interrupt stays visible",
                "$(task())?.dataset.processStatus === 'interrupting'";timeout=20)
            TK.emulate_phone(s) do
                TK.eval_js(s,"$(task()).open = true; true")
                @test TK.wait_for(s,"process controls fit the phone",
                    "$(task()).getBoundingClientRect().right <= innerWidth+1 && $(task()).scrollWidth <= $(task()).clientWidth+1";timeout=10)
                TK.screenshot(s,joinpath(tempdir(),"bonitoagents-managed-process-phone.png"))
            end
            TK.eval_js(s,"$(task()).querySelector('.bt-menu-trigger').click(); true")
            TK.eval_js(s,"[...$(task()).querySelectorAll('.bt-menu-item')].find(b => b.textContent==='Force kill').click(); true")
            @test TK.wait_for(s,"confirmed kill removes the live task","!$(task())";timeout=30)
            TK.send_message(s,"inspect managed")
            @test TK.wait_for(s,"status confirms the forced exit",result_says("process-status","killed");timeout=30)
            @test TK.eval_js(s,"$(card("process-status")).textContent.includes('9')")

            TK.send_message(s,"restart fixture")
            @test TK.wait_for(s,"second command runs", "!!$(task("restart-1")) && !$vp.querySelector('.bt-busy-active')";timeout=30)
            TK.eval_js(s,"$vp.querySelector('.bt-header-menu .bt-menu-trigger').click(); true")
            TK.eval_js(s,"[...$vp.querySelectorAll('.bt-header-menu .bt-menu-item')].find(b => b.textContent.trim().startsWith('Restart session')).click(); true")
            @test TK.wait_for(s,"restart confirms cleanup before dropping the job", "!$(task("restart-1"))";timeout=60)
            TK.send_message(s,"inspect restarted")
            @test TK.wait_for(s,"replacement session sees actual cleanup result",result_says("process-after-restart","killed");timeout=60)
            @test isempty(TK.js_errors(s))
        finally
            s.agent_fn[] = SharedServer.default_agent
        end
    end
end
