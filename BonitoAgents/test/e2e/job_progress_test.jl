@testitem "e2e:job_progress" setup=[SharedServer] tags=[:e2e] begin
    s=SharedServer.server()
    TK=SharedServer.TK
    tool(action;kwargs...) = TK.mcp_call("bt_progress";real_process=true,arguments=merge(Dict{String,Any}("action"=>action,"id"=>"farm"),Dict(string(k)=>v for (k,v) in kwargs)))
    s.agent_fn[]=function(prompt)
        if prompt=="show tool progress"
            return [tool("start";label="Render farm",total=100,completed=25,unit="frames"),
                TK.text("Farm is rendering"),TK.delay(8000),
                tool("update";completed=60),
                TK.delay(8000),TK.end_turn()]
        elseif prompt=="finish tool progress"
            return [tool("finish"),TK.text("Farm complete"),TK.end_turn()]
        elseif prompt=="unknown progress"
            return [tool("start";label="Encoding",total=nothing,detail="Waiting for encoder"),TK.end_turn()]
        elseif prompt=="failed progress"
            return [tool("fail";detail="Encoder exited with status 1"),TK.end_turn()]
        elseif prompt=="native progress"
            return [TK.bt_eval("job=BonitoProgress.progress(\"Native render\";id=\"native\",total=20); BonitoProgress.update!(job,8); sleep(8); BonitoProgress.finish!(job); :native_done";real_process=true),TK.text("Eval complete"),TK.end_turn()]
        elseif prompt=="logged progress"
            return [TK.bt_eval("using Logging; @info \"Logged render\" progress=0.35 _id=:logged; sleep(8); @info \"Logged render\" progress=1.0 _id=:logged; @info \"Logged render\" progress=\"done\" _id=:logged; :logged_done";real_process=true),TK.text("Eval complete"),TK.end_turn()]
        elseif prompt=="detached progress"
            program = "using .BonitoProgress; job=progress(\"Detached farm\";id=\"detached\",total=40,completed=12); flush_progress(job); sleep(15); finish!(job); flush_progress(job) || error(\"progress was not acknowledged\")"
            code = "run(pipeline(detach(`\$(Base.julia_cmd()) --startup-file=no -L \$(ENV[\"BONITOAGENTS_PROGRESS_CLIENT\"]) -e \$(" * repr(program) * ")`);stdout=devnull,stderr=stderr);wait=false); :launched"
            return [TK.bt_eval(code;real_process=true),TK.text("Coordinator launched"),TK.end_turn()]
        end
        return [TK.text("Received $prompt"),TK.end_turn()]
    end
    pid=TK.new_chat(s;title="Measured job progress")
    pane="document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
    job="$pane.querySelector('.bt-job-progress')"
    ring="document.querySelector('.bt-side-item[data-project-id=\"$pid\"] .bt-job-icon')"
    says(t)="$pane.querySelector('.bt-messages').textContent.includes($(repr(t)))"
    TK.send_message(s,"show tool progress")
    @test TK.wait_for(s,"tool progress reaches chat and sidebar",
        "!$job.hidden && $job.querySelector('.bt-job-percent').textContent==='25%' && !$ring.hidden";timeout=90)
    @test TK.eval_js(s,"$ring.querySelector('.bt-job-ring-fill').getAttribute('stroke-dashoffset')==='75'")
    @test TK.eval_js(s,"$job.getBoundingClientRect().height <= 52")
    @test TK.wait_for(s,"update arrives during a running turn",
        "$job.querySelector('.bt-job-percent').textContent==='60%' && !!$pane.querySelector('.bt-busy-active')";timeout=30)
    TK.reload!(s)
    @test TK.wait_for(s,"reload agrees about progress",
        "$job?.querySelector('.bt-job-percent')?.textContent==='60%' && $ring?.querySelector('.bt-job-ring-fill')?.getAttribute('stroke-dashoffset')==='40'";timeout=30)
    @test TK.wait_for(s,"agent turn finishes without finishing the job",
        "!$pane.querySelector('.bt-busy-active') && $job.dataset.status==='running'";timeout=30)
    TK.drop_worker_connection!(s)
    @test TK.wait_for(s,"disconnected jobs retain their measured count",
        "$job.dataset.status==='offline' && $job.querySelector('.bt-job-percent').textContent==='60%' && $ring.dataset.status==='offline'";timeout=10)
    @test TK.wait_for(s,"worker resumes without losing progress",
        "$job.dataset.status==='running' && $job.querySelector('.bt-job-percent').textContent==='60%'";timeout=30)
    TK.eval_js(s,"$ring.click(); true")
    @test TK.wait_for(s,"sidebar icon expands job details","$job.open";timeout=10)
    TK.emulate_phone(s) do
        @test TK.wait_for(s,"phone progress fits viewport",
            "$job.getBoundingClientRect().right<=innerWidth && $job.scrollWidth<=$job.clientWidth+1";timeout=10)
        TK.screenshot(s,joinpath(tempdir(),"bonitoagents-job-progress-phone.png"))
    end
    TK.send_message(s,"finish tool progress")
    @test TK.wait_for(s,"explicit completion reaches both views",
        "$job.dataset.status==='completed' && $job.querySelector('.bt-job-percent').textContent==='Completed · 100%' && " *
        "$ring.querySelector('.bt-job-ring-fill').getAttribute('stroke-dashoffset')==='0' && ! $pane.querySelector('.bt-busy-active')";timeout=30)
    TK.send_message(s,"native progress")
    @test TK.wait_for(s,"running code updates without an agent tool roundtrip",
        "$job.dataset.jobId==='native' && $job.querySelector('.bt-job-percent').textContent==='40%'";timeout=90)
    @test TK.wait_for(s,"native job completes", "$job.dataset.status==='completed' && !$pane.querySelector('.bt-busy-active')";timeout=40)
    TK.send_message(s,"logged progress")
    @test TK.wait_for(s,"standard Julia progress logs reach the same job row",
        "$job.dataset.jobId==='logged' && $job.querySelector('.bt-job-percent').textContent==='35%'";timeout=60)
    @test TK.wait_for(s,"standard logging finishes normally",
        "$job.dataset.status==='completed' && !$pane.querySelector('.bt-busy-active')";timeout=30)
    TK.eval_js(s,"if (!$job.open) $job.querySelector('summary').click(); $job.querySelector('button').click(); true")
    @test TK.wait_for(s,"dismissed job leaves both views", "$job.dataset.jobId!=='logged' && $ring.dataset.jobId!=='logged'";timeout=10)
    TK.reload!(s)
    @test TK.wait_for(s,"dismissal survives reload", "$job?.dataset.jobId!=='logged' && !!$pane?.querySelector('.bt-text-input')";timeout=30)
    TK.send_message(s,"detached progress")
    @test TK.wait_for(s,"detached program reports after the agent turn ends",
        "$job.dataset.jobId==='detached' && $job.querySelector('.bt-job-percent').textContent==='30%' && !$pane.querySelector('.bt-busy-active')";timeout=60)
    TK.reload!(s)
    @test TK.wait_for(s,"detached progress survives a browser reload",
        "$job?.dataset.jobId==='detached' && $job.querySelector('.bt-job-percent').textContent==='30%'";timeout=20)
    @test TK.wait_for(s,"detached coordinator finishes independently",
        "$job.dataset.jobId==='detached' && $job.dataset.status==='completed' && $ring.querySelector('.bt-job-ring-fill').getAttribute('stroke-dashoffset')==='0'";timeout=40)
    TK.send_message(s,"unknown progress")
    @test TK.wait_for(s,"unknown work has no invented percentage",
        "$job.dataset.jobId==='farm' && $job.dataset.indeterminate==='true' && !$job.querySelector('progress').hasAttribute('value') && $ring.dataset.indeterminate==='true' && !$pane.querySelector('.bt-busy-active')";timeout=30)
    TK.send_message(s,"failed progress")
    @test TK.wait_for(s,"failed jobs retain their details",
        "$job.dataset.status==='failed' && $ring.dataset.status==='failed' && $job.querySelector('.bt-job-detail-text').textContent.includes('Encoder exited') && !$pane.querySelector('.bt-busy-active')";timeout=30)
    @test isempty(TK.js_errors(s))
end

@testitem "e2e:progress_completion" setup=[SharedServer] tags=[:e2e] begin
    TK=SharedServer.TK
    tool(action,id;kwargs...) = TK.mcp_call("bt_progress";real_process=true,
        arguments=merge(Dict{String,Any}("action"=>action,"id"=>id),Dict(string(k)=>v for (k,v) in kwargs)))
    s=TK.dev_server(agent=prompt -> if prompt=="start transfer"
        [tool("start","old";label="Previous transfer",total=1),tool("finish","old"),
         tool("start","sync";label="Pull from worker",total=57,completed=57,unit="files"),TK.end_turn()]
    elseif prompt=="finish transfer"
        [tool("finish","sync"),TK.end_turn()]
    elseif prompt=="fail transfer"
        [tool("start","failed";label="Failed transfer",total=10,completed=2),
         tool("fail","failed";detail="Destination refused write"),TK.end_turn()]
    else
        [TK.end_turn()]
    end)
    try
        TK.open_browser(s)
        pid=TK.new_chat(s)
        pane="document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
        job="$pane.querySelector('.bt-job-progress')"
        ring="document.querySelector('.bt-side-item[data-project-id=\"$pid\"] .bt-job-icon')"
        TK.send_message(s,"start transfer")
        @test TK.wait_for(s,"100 percent still waits for explicit completion",
            "!$job.hidden && $job.dataset.status==='running' && $job.querySelector('.bt-job-percent').textContent==='100% · finishing' && !$ring.hidden";timeout=60)
        @test TK.wait_for(s,"old completion expires while current transfer stays visible",
            "!$job.hidden && $job.dataset.jobId==='sync' && $job.querySelector('.bt-job-label').textContent==='Pull from worker' && !$ring.hidden";timeout=10)
        TK.send_message(s,"finish transfer")
        @test TK.wait_for(s,"successful completion is explicit",
            "!$job.hidden && $job.querySelector('.bt-job-percent').textContent==='Completed · 100%' && $ring.dataset.status==='completed'";timeout=20)
        TK.screenshot(s,joinpath(tempdir(),"bonitoagents-progress-completed.png"))
        @test TK.wait_for(s,"successful jobs clear automatically from both views",
            "$job.hidden && $ring.hidden";timeout=10)
        TK.reload!(s)
        @test TK.wait_for(s,"reload does not resurrect completed jobs",
            "!!$pane?.querySelector('.bt-text-input') && $job?.hidden && $ring?.hidden";timeout=30)
        TK.send_message(s,"fail transfer")
        @test TK.wait_for(s,"failure shown",
            "!$job.hidden && $job.dataset.status==='failed' && $ring.dataset.status==='failed'";timeout=30)
        TK.eval_js(s,"window.__failureShownAt=performance.now();true")
        @test TK.wait_for(s,"failure remains visible beyond success expiry",
            "performance.now()-window.__failureShownAt>6000 && !$job.hidden && !$ring.hidden && $job.querySelector('.bt-job-detail-text').textContent.includes('Destination refused write')";timeout=10)
        TK.reload!(s)
        @test TK.wait_for(s,"failure remains after reload",
            "!$job?.hidden && $job?.dataset.status==='failed' && !$ring?.hidden";timeout=30)
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
