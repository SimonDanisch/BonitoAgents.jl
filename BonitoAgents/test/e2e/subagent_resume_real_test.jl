# A background subagent of the REAL Claude Code agent, revived with SendMessage:
# it is back in the bar while it runs, and the chat is free once the agent's own
# reply is over. Claude's adapter holds a prompt open while a background subagent
# that the prompt started or revived runs, and answers it only when the subagent
# ends or the next prompt comes. On 2026-11-11 a revived logo agent ran for an
# hour with nothing in the bar, the chat looked busy, and every message "for when
# done" waited behind it. The mock agent answered every prompt at once, so no
# other test could see either.
#
# Opt-in like `e2e:subagent_real` (`BT_REAL_AGENT=1`): it needs claude-agent-acp
# on PATH (or CLAUDE_AGENT_ACP), an authenticated Claude account, and it spends
# real tokens.
@testitem "e2e:subagent_resume_real" setup = [SharedServer] tags = [:e2e, :real] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

    if get(ENV, "BT_REAL_AGENT", "") != "1"
        @info "e2e:subagent_resume_real skipped — set BT_REAL_AGENT=1 (needs claude-agent-acp + an authenticated Claude account)"
        @test true
    elseif Sys.which("claude-agent-acp") === nothing && isempty(get(ENV, "CLAUDE_AGENT_ACP", ""))
        error("BT_REAL_AGENT=1 but no claude-agent-acp on PATH (or CLAUDE_AGENT_ACP)")
    else
        bin = something(get(ENV, "CLAUDE_AGENT_ACP", nothing), Sys.which("claude-agent-acp"))
        pkg = read(joinpath(dirname(dirname(realpath(bin))), "package.json"), String)
        @info "e2e:subagent_resume_real runs claude-agent-acp" version = match(r"\"version\":\s*\"([^\"]+)\"", pkg)[1] bin
        server = TK.dev_server(mock = false, agent_bin = bin)
        cwd = mktempdir()
        pid = ""
        try
            TK.open_browser(server)
            pid = TK.new_chat(server; cwd = cwd, title = "resumeagent")
            row = "[...document.querySelectorAll('.bt-taskbar-slot')].find(r => (r.textContent || '').includes('sleeper'))"
            idle = "!document.querySelector('.bt-busy.bt-busy-active')"
            # Claude Code refuses a foreground command that starts with `sleep` of
            # 25 s or more, so the subagent waits through python.
            wait_cmd(s) = "`python3 -c 'import time; time.sleep($s)'`"
            TK.send_message(server, "Use the Agent tool exactly once, with run_in_background: true, " *
                "subagent_type \"general-purpose\", description \"sleeper\", prompt " *
                "\"Run the shell command $(wait_cmd(60)) with the Bash tool in the foreground, then reply with only the word done.\". " *
                "Then end your turn at once with one short sentence, without waiting for it.")
            # The reply is over while the subagent runs: the chat is free.
            @test TK.wait_for(server, "the subagent in the bar", "!!($row)"; timeout = 120) == true
            @test TK.wait_for(server, "the chat free while the subagent runs", idle; timeout = 60) == true
            @test TK.eval_js(server, "!!($row)") == true
            # A message for when the agent is done goes out now, not after the subagent.
            TK.send_message(server, "Reply with the word banana spelled backwards, in lowercase, and nothing else.")
            @test TK.wait_for(server, "the answer while the subagent runs",
                "document.body.textContent.includes('ananab')"; timeout = 90) == true
            @test TK.eval_js(server, "!!($row)") == true
            @test TK.wait_for(server, "the subagent out of the bar", "!($row)"; timeout = 240) == true
            @test TK.wait_for(server, "the agent idle after its report", idle; timeout = 120) == true

            # Revived with SendMessage: in the bar again, and the chat is free once
            # the reply is over.
            TK.send_message(server, "Use the SendMessage tool exactly once, to the agent you started " *
                "(its agentId is in the Agent tool's result), with the message " *
                "\"Run the shell command $(wait_cmd(60)) with the Bash tool in the foreground, then reply with only the word again.\". " *
                "Then end your turn at once with one short sentence, without waiting for it.")
            @test TK.wait_for(server, "the revived subagent in the bar", "!!($row)"; timeout = 120) == true
            @test TK.wait_for(server, "the chat free while the revived subagent runs", idle; timeout = 60) == true
            @test TK.eval_js(server, "!!($row)") == true
            @test TK.wait_for(server, "the revived subagent out of the bar", "!($row)"; timeout = 300) == true
        finally
            # `BT_CAPTURE_WIRE=<file>` keeps the run's ACP wire: how
            # AgentClientProtocol/test/fixtures/claude_bg_subagent_hold_wire.jsonl was made.
            capture = get(ENV, "BT_CAPTURE_WIRE", "")
            if !isempty(capture) && !isempty(pid)
                cp(joinpath(server.h.state_dir, "chats", pid, "acp.jsonl"), capture; force = true)
            end
            close(server)
            rm(joinpath(homedir(), ".claude", "projects", BT.AgentProviders.claude_project_key(cwd));
               recursive = true, force = true)
        end
    end
end
