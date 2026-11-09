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
        elseif prompt == "fail a job"
            # `--flag_name` and `_second_line_` are what markdown used to mangle.
            [call("start";card="process-fail-start",id="fail-1",label="Failing build",cwd,
                  argv=["sh","-c","echo first_line; echo _second_line_; exit 3","--flag_name"]),
             call("wait";card="process-fail-wait",id="fail-1",seconds=30),TK.end_turn()]
        elseif prompt == "start unlabelled"
            [call("start";card="process-nolabel",id="nolabel-1",argv=["echo","no-label-output"],cwd),TK.end_turn()]
        elseif prompt == "list jobs"
            [call("list";card="process-list"),TK.end_turn()]
        elseif prompt == "unknown job"
            [call("status";card="process-unknown",id="never_started"),TK.end_turn()]
        elseif prompt == "json tool"
            [TK.mcp_call("bt_progress";id="progress-json",real_process=true,
                arguments=Dict{String,Any}("action"=>"start","id"=>"card_job","label"=>"Card job")),
             TK.mcp_call("bt_progress";id="progress-json-end",real_process=true,
                arguments=Dict{String,Any}("action"=>"finish","id"=>"card_job")),TK.end_turn()]
        elseif prompt == "restart fixture"
            [call("start";card="process-restart-start",id="restart-1",argv=["sh","-c","echo restart-ready; sleep 300"],label="Restart fixture",cwd),TK.end_turn()]
        elseif endswith(prompt, "inspect restarted")   # the old job's end note rides it
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
                const header=c.querySelector('.bt-tool-header');
                if (header.dataset.expanded!=='true') { header.click(); return false; }
                return c.innerText.includes($(repr(text)));
            })()"""
        end
        part(id,cls) = "$(card(id))?.querySelector('$cls')"
        title_is(id,text) = "$(part(id,".bt-tool-title"))?.textContent === $(repr(text))"
        summary_has(id,text) = "!!$(part(id,".bt-tool-summary"))?.textContent.includes($(repr(text)))"
        function opened(id,check)
            target = card(id)
            return """(() => {
                const c = $target; if (!c) return false;
                const header=c.querySelector('.bt-tool-header');
                if (header.dataset.expanded!=='true') { header.click(); return false; }
                return $check;
            })()"""
        end
        try
            TK.send_message(s,"start managed")
            @test TK.wait_for(s,"worker job is in the taskbar with live output",
                "!!$(task()) && $(task()).textContent.includes('managed-ready') && !$vp.querySelector('.bt-busy-active')";timeout=120)
            @test TK.eval_js(s,"$(task()).textContent.includes('Managed render')")
            @test TK.eval_js(s,"$(task()).title.includes($(repr(cwd)))")

            # Collapsed, the card says what the call did and how it went.
            @test TK.wait_for(s,"the start card names the job",title_is("process-start","Start Managed render");timeout=30,
                describe=part("process-start",".bt-tool-title") * "?.textContent")
            @test TK.eval_js(s,summary_has("process-start","running"))
            @test TK.eval_js(s,"$(part("process-start",".bt-tool-header")).dataset.expanded") == "false"

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
            @test TK.wait_for(s,"bounded wait returns without ending the job",result_says("process-wait","timeout");
                timeout=30,describe=card("process-wait") * "?.innerText")
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
            TK.eval_js(s,"$(task()).querySelector('.bw-menu-trigger').click(); true")
            TK.eval_js(s,"[...$(task()).querySelectorAll('.bw-menu-item')].find(b => b.textContent==='Force kill').click(); true")
            @test TK.wait_for(s,"confirmed kill removes the live task","!$(task())";timeout=30)
            TK.send_message(s,"inspect managed")
            @test TK.wait_for(s,"status confirms the forced exit",result_says("process-status","killed");timeout=30)
            @test TK.eval_js(s,"$(card("process-status")).textContent.includes('9')")

            # A job that fails: named, with its exit code, and not on a green pill.
            TK.send_message(s,"fail a job")
            @test TK.wait_for(s,"the wait card names the job and how it ended",
                title_is("process-fail-wait","Wait for Failing build") * " && " * summary_has("process-fail-wait","failed · exit 3");
                timeout=60,describe=card("process-fail-wait") * "?.innerText")
            @test TK.eval_js(s,"$(part("process-fail-wait",".bt-tool-status")).textContent") == "failed"
            @test TK.eval_js(s,"$(part("process-fail-wait",".bt-tool-status")).classList.contains('bt-status-failed')")
            # Opened: the details, with the text exactly as the job wrote it.
            @test TK.wait_for(s,"opening shows the job's details",
                opened("process-fail-wait","!!c.querySelector('.bt-process-facts')");timeout=30)
            facts = part("process-fail-wait",".bt-process-facts")
            for text in ("failed · exit 3","--flag_name","exited","fail-1",cwd)
                @test TK.eval_js(s,"$(facts).innerText.includes($(repr(text)))")
            end
            console = part("process-fail-wait",".bt-console")
            @test TK.wait_for(s,"output keeps its lines and its underscores",
                "!!$(console)?.innerText.includes('first_line\\n_second_line_')";timeout=30,describe=console * "?.innerText")
            @test TK.eval_js(s,"!$(part("process-fail-wait",".bt-tool-md")) && !$(part("process-fail-wait",".bt-tool-body em"))")
            # The facts line up as a table, not one run-on paragraph.
            @test TK.eval_js(s,"getComputedStyle($(facts)).display") == "grid"
            @test TK.eval_js(s,"$(facts).querySelectorAll('dt').length") == TK.eval_js(s,"$(facts).querySelectorAll('dd').length") > 5
            # Closing the card goes back to the one line.
            TK.eval_js(s,"$(part("process-fail-wait",".bt-tool-toggle")).click(); true")
            @test TK.wait_for(s,"the card collapses again",
                "$(part("process-fail-wait",".bt-tool-header")).dataset.expanded === 'false'";timeout=10)

            # No label: the command names it, not the id.
            TK.send_message(s,"start unlabelled")
            @test TK.wait_for(s,"an unlabelled job is named by its command",
                title_is("process-nolabel","Start echo no-label-output");timeout=30,describe=part("process-nolabel",".bt-tool-title") * "?.textContent")

            # A list: how many, and one row per job that opens to its details.
            TK.send_message(s,"list jobs")
            @test TK.wait_for(s,"the list card counts the jobs",
                title_is("process-list","List background commands") * " && " * summary_has("process-list","commands");
                timeout=30,describe=card("process-list") * "?.innerText")
            @test TK.wait_for(s,"the list opens to a row per job",
                opened("process-list","c.querySelectorAll('.bt-subsection').length >= 2");timeout=30)
            row = """[...$(card("process-list")).querySelectorAll('.bt-subsection')].find(r => r.querySelector('summary').innerText.includes('Failing build'))"""
            @test TK.eval_js(s,"!$(row).open && $(row).innerText.includes('failed · exit 3')")
            @test TK.eval_js(s,"!![...$(card("process-list")).querySelectorAll('summary')].find(r => r.innerText.includes('echo no-label-output'))")
            TK.eval_js(s,"$(row).querySelector('summary').click(); true")
            @test TK.wait_for(s,"a row opens to its job",
                "$(row).open && $(row).querySelector('.bt-process-facts').innerText.includes('--flag_name')";timeout=10)

            # A call that failed shows its error, literally and on a red pill.
            TK.send_message(s,"unknown job")
            @test TK.wait_for(s,"an error stays literal",
                opened("process-unknown","!!c.querySelector('.bt-tool-body .bt-code')");timeout=30,describe=card("process-unknown") * "?.innerText")
            @test TK.eval_js(s,"$(part("process-unknown",".bt-tool-status")).textContent") == "failed"
            @test TK.eval_js(s,"!$(part("process-unknown",".bt-tool-md"))")

            # The other tools that answer in JSON show it as JSON.
            TK.send_message(s,"json tool")
            @test TK.wait_for(s,"a JSON tool's body is JSON code",
                opened("progress-json","c.querySelector('.bt-tool-body .bt-code')?.dataset.lang === 'json'");timeout=30,
                describe=card("progress-json") * "?.innerText")
            @test TK.eval_js(s,"$(part("progress-json",".bt-code")).textContent.includes('update_queued')")
            @test TK.eval_js(s,"!$(part("progress-json",".bt-tool-md"))")

            TK.reload!(s)
            @test TK.wait_for(s,"a reload keeps the cards as they were",
                title_is("process-fail-wait","Wait for Failing build") * " && " * summary_has("process-fail-wait","failed · exit 3");
                timeout=30,describe=card("process-fail-wait") * "?.innerText")
            @test TK.eval_js(s,"$(part("process-fail-wait",".bt-tool-status")).textContent") == "failed"

            TK.send_message(s,"restart fixture")
            @test TK.wait_for(s,"second command runs", "!!$(task("restart-1")) && !$vp.querySelector('.bt-busy-active')";timeout=30)
            TK.eval_js(s,"$vp.querySelector('.bt-header-menu .bw-menu-trigger').click(); true")
            TK.eval_js(s,"[...$vp.querySelectorAll('.bt-header-menu .bw-menu-item')].find(b => b.textContent.trim().startsWith('Restart session')).click(); true")
            @test TK.wait_for(s,"restart confirms cleanup before dropping the job", "!$(task("restart-1"))";timeout=60)
            TK.send_message(s,"inspect restarted")
            @test TK.wait_for(s,"replacement session sees actual cleanup result",result_says("process-after-restart","killed");timeout=60)
            @test isempty(TK.js_errors(s))
        finally
            s.agent_fn[] = SharedServer.default_agent
        end
    end
end
