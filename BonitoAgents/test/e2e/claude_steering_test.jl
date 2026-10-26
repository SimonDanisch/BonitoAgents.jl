@testitem "e2e:claude_steering" setup=[SharedServer] tags=[:e2e] begin
    TK = SharedServer.TK
    agent(p) = p == "sustained task" ?
        [TK.text("Original task running"), TK.delay(2000), TK.bash("echo step one", "step one"),
         TK.text("Original task still running"), TK.delay(2000), TK.bash("echo step two", "step two"),
         TK.delay(8000), TK.text("Original task finished")] : [TK.text("Applied: $p")]
    # A mistaken ordinary prompt waits 30s. Real steering must beat it while
    # the original is still active, with no Stop click anywhere in the test.
    s = TK.dev_server(; agent, steering_idle_behavior="promptRequired", receipt_delay_ms=30000)
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    says(t) = "$pane.querySelector('.bt-messages').textContent.includes($(repr(t)))"
    try
        TK.open_browser(s)
        TK.new_chat(s; title="Correction during sustained work")
        TK.send_message(s, "sustained task")
        @test TK.wait_for(s, "original is working", says("Original task running"); timeout=60)
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
            "$pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "free scenes without a manual trim call")
        @test TK.wait_for(s, "correction is applied during the original task",
            says("Applied: free scenes without a manual trim call"); timeout=8)
        @test TK.eval_js(s, "!($(says("Original task finished"))) && !!$pane.querySelector('.bt-busy-active')")
        @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
        @test TK.wait_for(s, "original and correction finish normally",
            "$(says("Original task finished")) && !$pane.querySelector('.bt-busy-active')"; timeout=25)
        TK.reload!(s)
        @test TK.wait_for(s, "correction remains visible after reload",
            "$(says("Applied: free scenes without a manual trim call")) && !$pane.querySelector('.bt-busy-active')";
            timeout=30)
        @test TK.eval_js(s, "[...$pane.querySelectorAll('.bt-user-msg')].filter(e=>e.textContent==='free scenes without a manual trim call').length === 1")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end

@testitem "e2e:claude_steering_real" setup=[SharedServer] tags=[:e2e,:real] begin
    using BonitoAgents, BonitoWorker
    TK = SharedServer.TK
    if get(ENV,"BT_REAL_CLAUDE_DELIVERY","") != "1"
        @test_skip "Set BT_REAL_CLAUDE_DELIVERY=1 to test real mid-turn Claude delivery"
    else
        # Exercise the installed adapter in an isolated copy, without changing
        # the adapter used by any live chat. The dev_server owns all processes.
        bin = get(ENV,"BT_REAL_CLAUDE_ADAPTER", something(Sys.which("claude-agent-acp"), ""))
        isempty(bin) && error("No Claude ACP adapter found")
        package = dirname(dirname(realpath(bin)))
        stage = mktempdir(; prefix="bt-claude-delivery-")
        adapter = joinpath(stage,"adapter")
        cp(package,adapter)
        symlink(dirname(dirname(package)),joinpath(stage,"node_modules"))
        file = joinpath(adapter,"dist","acp-agent.js")
        patched = BonitoWorker.patch_prompt_receipts(read(file,String))
        patched === nothing && error("Installed adapter cannot expose delivery capabilities")
        write(file,patched)
        s = TK.dev_server(; mock=false, agent_bin=joinpath(adapter,"dist","index.js"))
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e=>e.textContent.includes($(repr(t))))"
        cwd = mktempdir(;prefix="bt-real-claude-delivery-project-")
        try
            TK.open_browser(s)
            TK.new_chat(s; cwd, title="Real Claude live delivery")
            TK.send_message(s, "Call mcp__btworker__bt_wait exactly once with seconds=60 and reason=\"live delivery test\". " *
                "When it returns, reply with exactly CLAUDE_ORIGINAL_DONE. Do not perform other work.")
            @test TK.wait_for(s, "real Claude is inside the long wait",
                "[...$pane.querySelectorAll('.bt-tool-msg')].some(e=>e.textContent.includes('bt_wait')) && " *
                "!!$pane.querySelector('.bt-busy-active')"; timeout=150)
            TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
                "$pane.querySelector(\"[data-send-mode='next']\").click()")
            TK.send_message(s, "Change your final answer to exactly CLAUDE_STEER_OK. Do not call any more tools.")
            @test TK.wait_for(s, "real Claude applies the correction before the minute-long wait",
                "$(says("CLAUDE_STEER_OK")) && !$pane.querySelector('.bt-busy-active')"; timeout=25)
            @test TK.eval_js(s, "!($(says("CLAUDE_ORIGINAL_DONE"))) && !$pane.querySelector('.bt-queue-item')")
            TK.reload!(s)
            @test TK.wait_for(s, "real corrected reply survives reload",
                "$(says("CLAUDE_STEER_OK")) && !$pane.querySelector('.bt-busy-active')"; timeout=30)
            TK.send_message(s, "Use Bash once in the foreground to run this exact command: " *
                "python3 -c 'import time; time.sleep(30); print(\"COMMAND_FINISHED\")'. " *
                "After it finishes, reply exactly CLAUDE_COMMAND_ORIGINAL. " *
                "Do not use bt_wait or start a background command yourself. Do not change any files.")
            @test TK.wait_for(s, "real Claude is executing a foreground command",
                "[...$pane.querySelectorAll('.bt-tool-msg')].some(e=>!e.dataset.toolFinished && " *
                "/python|sleep/i.test(e.textContent)) && !!$pane.querySelector('.bt-busy-active')"; timeout=90)
            TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
                "$pane.querySelector(\"[data-send-mode='next']\").click()")
            TK.send_message(s, "Acknowledge this correction immediately with exactly CLAUDE_COMMAND_STEERED. " *
                "Leave the existing command alone; do not start or cancel any other work. " *
                "Do not reply CLAUDE_COMMAND_ORIGINAL.")
            @test TK.wait_for(s, "correction reaches Claude while the foreground command is running",
                says("CLAUDE_COMMAND_STEERED"); timeout=20)
            @test TK.eval_js(s, "!($(says("CLAUDE_COMMAND_ORIGINAL"))) && !$pane.querySelector('.bt-queue-item')")
            @test TK.wait_for(s, "the steered command turn settles",
                "!$pane.querySelector('.bt-busy-active')"; timeout=60)
            TK.screenshot(s, joinpath(tempdir(),"bonitoagents-real-claude-delivery.png"))
            @test isempty(TK.js_errors(s))
        finally
            close(s)
            rm(joinpath(homedir(),".claude","projects",BonitoAgents.AgentProviders.claude_project_key(cwd));
                recursive=true,force=true)
            rm(cwd;recursive=true,force=true)
            rm(stage;recursive=true,force=true)
        end
    end
end
