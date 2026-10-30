@testitem "e2e:agent_workflow" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    s.agent_fn[] = _ -> [TK.mcp_call("bt_help"; id="workflow-help", real_process=true),
        TK.text("Workflow read"), TK.end_turn()]
    try
        TK.new_chat(s; title="Discover BonitoAgents workflow")
        TK.send_message(s, "Read the BonitoAgents workflow")
        card = "document.querySelector('.bt-chatpane[aria-hidden=false] .bt-tool-msg[data-msg-id*=workflow-help]')"
        @test TK.wait_for(s, "worker MCP returned help",
            "!!$(card) && $(card).querySelector('.bt-tool-status')?.textContent === 'completed'"; timeout=90)
        TK.eval_js(s, "$(card).querySelector('.bt-tool-header').click(); true")
        @test TK.wait_for(s, "guide includes progress, file links and server instructions",
            "['BonitoProgress.progress', './src/app.jl', 'bt_julia_wait', 'screen -dm'].every(t => $(card).innerText.includes(t))";
            timeout=20)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-workflow-help.png"))
        @test isempty(TK.js_errors(s))
    finally
        s.agent_fn[] = SharedServer.default_agent
    end
end
