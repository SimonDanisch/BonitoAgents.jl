# The `bt_process` card under the REAL Claude Code agent. `e2e:managed_processes`
# drives the real tool through a mock agent; only claude-agent-acp shows that its
# wire reaches the card too: arguments streamed in late, the result's JSON untouched.
#
# Opt-in (`BT_REAL_AGENT=1`): it needs `claude-agent-acp` on PATH (or CLAUDE_AGENT_ACP),
# an authenticated Claude account, and it spends real tokens.
@testitem "e2e:process_card_real" setup = [SharedServer] tags = [:e2e, :real] begin
    const TK = SharedServer.TestKit
    import BonitoAgents as BT

    if get(ENV, "BT_REAL_AGENT", "") != "1"
        @info "e2e:process_card_real skipped: set BT_REAL_AGENT=1 (needs claude-agent-acp + an authenticated Claude account)"
        @test true
    elseif Sys.which("claude-agent-acp") === nothing && isempty(get(ENV, "CLAUDE_AGENT_ACP", ""))
        error("BT_REAL_AGENT=1 but no claude-agent-acp on PATH (or CLAUDE_AGENT_ACP)")
    else
        bin = something(get(ENV, "CLAUDE_AGENT_ACP", nothing), Sys.which("claude-agent-acp"))
        server = TK.dev_server(mock = false, agent_bin = bin)
        cwd = mktempdir()
        try
            TK.open_browser(server)
            TK.new_chat(server; cwd = cwd, title = "realprocesscard")
            TK.send_message(server, "Call the bt_process tool exactly twice and do nothing else. " *
                "First with action \"start\", id \"real-job-1\", label \"Real job\" and " *
                "argv [\"sh\", \"-c\", \"echo first_line; echo _second_line_; exit 4\"]. " *
                "Then with action \"wait\", id \"real-job-1\" and seconds 30. " *
                "Then end your turn with the single word done.")
            titled(title) = "[...document.querySelectorAll('.bt-tool-msg')].find(c => c.querySelector('.bt-tool-title')?.textContent === $(repr(title)))"
            start, wait = titled("Start Real job"), titled("Wait for Real job")
            everything = "[...document.querySelectorAll('.bt-tool-msg, .bt-permission-card')].map(c => c.innerText).join(' | ')"
            # Answer the agent's permission prompts as a user would.
            approving(check) = """(() => {
                document.querySelector('.bt-permission-card:not(.bt-perm-answered) .bt-perm-allow')?.click();
                return $check;
            })()"""
            @test TK.wait_for(server, "the start card names the job", approving("!!($start)"); timeout = 240, describe = everything)
            @test TK.wait_for(server, "the wait card says how the job ended",
                approving("!!$wait?.querySelector('.bt-tool-summary')?.textContent.includes('failed · exit 4')");
                timeout = 180, describe = everything)
            @test TK.eval_js(server, "$wait.querySelector('.bt-tool-status').textContent") == "failed"
            TK.eval_js(server, "$wait.querySelector('.bt-tool-header').click(); true")
            @test TK.wait_for(server, "the opened card shows the job",
                "$wait.querySelector('.bt-process-facts')?.innerText.includes('exit 4')";
                timeout = 30, describe = "$wait.innerText")
            @test TK.wait_for(server, "the output is as the job wrote it",
                "$wait.querySelector('.bt-console')?.innerText.includes('first_line\\n_second_line_')";
                timeout = 30, describe = "$wait.innerText")
            @test TK.eval_js(server, "!$wait.querySelector('.bt-tool-md')")
        finally
            close(server)
            rm(joinpath(homedir(), ".claude", "projects", BT.AgentProviders.claude_project_key(cwd));
               recursive = true, force = true)
        end
    end
end
