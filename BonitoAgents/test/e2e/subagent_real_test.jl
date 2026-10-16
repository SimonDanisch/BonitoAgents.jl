# A background subagent of the REAL Claude Code agent finishes: its row leaves
# the bar once the subagent has ended. The mock-based subagent items hand the
# card its transcript path themselves; only the real claude-agent-acp shows
# whether that path arrives at all. From 2026-09-17 it did not: we announced the
# JetBrains AIR extension to every agent, Claude's adapter took us for AIR and
# left `outputFile` out of the launch, and every background agent read
# "running" forever.
#
# Opt-in (`BT_REAL_AGENT=1`): it needs `claude-agent-acp` on PATH (or
# CLAUDE_AGENT_ACP), an authenticated Claude account, and it spends real tokens.
# Workers install the adapter's latest release: run this against that one (the
# version is logged). 0.81.2 sent `outputFile` either way; 0.84.0 did not.
@testitem "e2e:subagent_real" setup = [SharedServer] tags = [:e2e, :real] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

    if get(ENV, "BT_REAL_AGENT", "") != "1"
        @info "e2e:subagent_real skipped — set BT_REAL_AGENT=1 (needs claude-agent-acp + an authenticated Claude account)"
        @test true
    elseif Sys.which("claude-agent-acp") === nothing && isempty(get(ENV, "CLAUDE_AGENT_ACP", ""))
        error("BT_REAL_AGENT=1 but no claude-agent-acp on PATH (or CLAUDE_AGENT_ACP)")
    else
        bin = something(get(ENV, "CLAUDE_AGENT_ACP", nothing), Sys.which("claude-agent-acp"))
        pkg = read(joinpath(dirname(dirname(realpath(bin))), "package.json"), String)
        @info "e2e:subagent_real runs claude-agent-acp" version = match(r"\"version\":\s*\"([^\"]+)\"", pkg)[1] bin
        server = TK.dev_server(mock = false, agent_bin = bin)
        cwd = mktempdir()
        try
            TK.open_browser(server)
            TK.new_chat(server; cwd = cwd, title = "realsubagent")
            TK.send_message(server, "Use the Agent tool exactly once, with run_in_background: true, " *
                "subagent_type \"general-purpose\", description \"probe\", prompt \"Reply with only the word done.\". " *
                "Then end your turn at once without waiting for it.")
            row = "[...document.querySelectorAll('.bt-taskbar-slot')].find(r => (r.textContent || '').includes('probe'))"
            @test TK.wait_for(server, "the running agent in the bar", "!!($row)"; timeout = 120) == true
            # It leaves once the subagent has ended and the agent's report on it is over.
            @test TK.wait_for(server, "the finished agent out of the bar", "!($row)"; timeout = 240) == true
        finally
            close(server)
            rm(joinpath(homedir(), ".claude", "projects", BT.AgentProviders.claude_project_key(cwd));
               recursive = true, force = true)
        end
    end
end
