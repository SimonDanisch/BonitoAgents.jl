# The chat's Stop ends the turn, not the background work: a background subagent
# of the REAL Claude Code agent runs on after a Stop and finishes. Claude Code's
# interrupt spares background subagents only when the client says it stops them
# one by one (`perTaskStopAffordance`, `session_meta`); before we said so, a
# Stop to ask a question killed every running subagent, silently, and the agent
# waited on one for 17 minutes (2026-10-20). Only the real adapter shows this.
#
# Opt-in like `e2e:subagent_real` (`BT_REAL_AGENT=1`): it needs claude-agent-acp
# on PATH (or CLAUDE_AGENT_ACP), an authenticated Claude account, and it spends
# real tokens.
@testitem "e2e:subagent_survives_stop" setup = [SharedServer] tags = [:e2e, :real] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

    if get(ENV, "BT_REAL_AGENT", "") != "1"
        @info "e2e:subagent_survives_stop skipped — set BT_REAL_AGENT=1 (needs claude-agent-acp + an authenticated Claude account)"
        @test true
    elseif Sys.which("claude-agent-acp") === nothing && isempty(get(ENV, "CLAUDE_AGENT_ACP", ""))
        error("BT_REAL_AGENT=1 but no claude-agent-acp on PATH (or CLAUDE_AGENT_ACP)")
    else
        bin = something(get(ENV, "CLAUDE_AGENT_ACP", nothing), Sys.which("claude-agent-acp"))
        pkg = read(joinpath(dirname(dirname(realpath(bin))), "package.json"), String)
        @info "e2e:subagent_survives_stop runs claude-agent-acp" version = match(r"\"version\":\s*\"([^\"]+)\"", pkg)[1] bin
        server = TK.dev_server(mock = false, agent_bin = bin)
        cwd = mktempdir()
        try
            TK.open_browser(server)
            TK.new_chat(server; cwd = cwd, title = "stopsparesagent")
            TK.send_message(server, "Do exactly these two steps. 1) Use the Agent tool once, with " *
                "run_in_background: true, subagent_type \"general-purpose\", description \"sleeper\", prompt " *
                "\"Run the shell command `sleep 40` with the Bash tool, then reply with only the word done.\". " *
                "2) Right after launching it, run the shell command `sleep 120` with the Bash tool in the foreground.")
            row = "[...document.querySelectorAll('.bt-taskbar-slot')].find(r => (r.textContent || '').includes('sleeper'))"
            @test TK.wait_for(server, "the subagent in the bar", "!!($row)"; timeout = 120) == true
            fg = "[...document.querySelectorAll('.bt-tool-msg')].find(m => (m.textContent || '').includes('sleep 120'))"
            @test TK.wait_for(server, "the foreground command running", "!!($fg)"; timeout = 120) == true
            sleep(3)
            # Stop, as the reader presses it to ask something while the agent works.
            TK.click(server, ".bt-stop-btn")
            @test TK.wait_for(server, "the turn stopped",
                "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true
            card = "[...document.querySelectorAll('.bt-tool-msg')].find(m => (m.querySelector('.bt-tool-title')?.textContent || '').includes('sleeper'))"
            # The subagent ran on and finished: its row leaves the bar once its
            # report is over, and its card does not say it was interrupted.
            @test TK.wait_for(server, "the subagent out of the bar", "!($row)"; timeout = 240) == true
            @test TK.eval_js(server, "($card)?.querySelector('.bt-tool-status')?.textContent") == "completed"
            @test !occursin("Interrupted", something(TK.eval_js(server, "($card)?.textContent || ''"), ""))
        finally
            close(server)
            rm(joinpath(homedir(), ".claude", "projects", BT.AgentProviders.claude_project_key(cwd));
               recursive = true, force = true)
        end
    end
end
