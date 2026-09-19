# Full propagation regression for a provider that cannot be spawned:
# worker open_session_failed frame -> pending server RPC -> restart last_error ->
# provider-switch failure detail -> rendered, copyable progress card.
@testitem "e2e:provider_failure" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    import BonitoAgents as BT
    const TK = TestKit

    agent(prompt) = [TK.text("mock reply: $prompt"), TK.end_turn()]
    missing = "/nonexistent/bonitoagents-test-codex-acp"

    try
        withenv("CODEX_AGENT_ACP" => missing) do
            server = TK.dev_server(agent = agent, name = "codex-failure-worker")
            try
                TK.open_browser(server)
                TK.new_chat(server; title = "Provider failure")

                # Bind a real Mock ACP session first. A failed Codex switch must
                # restore this live provider, not strand the chat offline.
                TK.send_message(server, "before switch")
                @test TK.wait_for(server, "initial mock reply",
                    "[...document.querySelectorAll('.bt-agent-msg')].some(e => " *
                    "(e.innerText || '').includes('mock reply: before switch'))";
                    timeout = 30) == true

                TK.switch_agent(server, "Codex")
                @test TK.wait_for(server, "Codex failure reaches progress card",
                    "!!document.querySelector('.bt-prog.bt-prog-err')";
                    timeout = 30) == true

                title = TK.eval_js(server,
                    "document.querySelector('.bt-prog-err .bt-prog-title').innerText")
                detail = TK.eval_js(server,
                    "document.querySelector('.bt-prog-err .bt-prog-detail').innerText")
                @test title == "Switching to Codex failed"
                # This text originates in BonitoWorker's spawn catch. Asserting
                # it in the DOM proves no layer replaced it with the old generic
                # "session did not come up" message.
                @test occursin("failed to spawn agent", detail)
                @test occursin(missing, detail)
                @test occursin("codex-failure-worker", detail)
                @test occursin("npm install -g @agentclientprotocol/codex-acp", detail)
                @test occursin("codex login", detail)

                @test TK.wait_for(server, "provider rolled back to Mock Agent",
                    "(document.querySelector('.bt-header-provider-pick " *
                    ".bt-msearch-value')?.textContent || '').trim() === 'Mock Agent'";
                    timeout = 30) == true

                # The restored session must answer, which covers the recovery
                # path as well as the error text.
                TK.send_message(server, "after failure")
                @test TK.wait_for(server, "restored provider answers",
                    "[...document.querySelectorAll('.bt-agent-msg')].some(e => " *
                    "(e.innerText || '').includes('mock reply: after failure'))";
                    timeout = 30) == true
                @test isempty(TK.js_errors(server))
            finally
                close(server)
            end
        end
    finally
        # `current_providers()` is memoised after reading the override. Restore
        # the normal descriptors for any later test item in this worker process.
        BT.refresh_providers!()
    end
end
