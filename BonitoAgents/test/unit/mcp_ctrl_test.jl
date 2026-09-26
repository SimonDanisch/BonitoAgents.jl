@testitem "unit:mcp_ctrl" tags = [:unit] setup = [LinkPair] begin

# The MCP control channel, plus the AGENTS.md → system-prompt `_meta` plumbing.
# More relay coverage (a real MCP subprocess, grants, replacement) is in
# mcp_relay_test.jl and e2e/remote_eval_test.jl.
#
#   1. Real round-trip: a BonitoMCP `start_ctrl_dialback!` in THIS process,
#      armed with a worker relay's grant the way production arms it, reaches
#      the server over a real link; `interrupt_project_eval!` sends
#      `interrupt_eval` and gets the `interrupt_result` reply (0 interrupted —
#      no eval in flight, but the whole path server → MCP process → reply →
#      pending_rpcs is exercised). The SAME channel also carries the debug
#      chat's `bt_dev_*` requests in the opposite direction (MCP → server →
#      reply), which is exercised here too.
#   2. `system_prompt_meta`: empty text ⇒ no `_meta` (params byte-identical
#      to before); non-empty ⇒ the claude_code preset with `append`.
#   3. `global_agents_md` round-trip through the state dir.

using Test
using Bonito
using BonitoAgents
import BonitoMCP, BonitoWorker, WorkerLink
const BT = BonitoAgents

@testset "MCP control channel + AGENTS.md" begin

    @testset "system_prompt_meta" begin
        @test BT.system_prompt_meta("") == Dict{String,Any}()
        m = BT.system_prompt_meta("Always write tests.")
        sp = m["_meta"]["systemPrompt"]
        @test sp["type"] == "preset"
        @test sp["preset"] == "claude_code"
        @test sp["append"] == "Always write tests."
    end

    @testset "global_agents_md round-trip" begin
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        @test BT.global_agents_md(state) == ""
        BT.set_global_agents_md!(state, "## House rules\nBe pedantic.\n")
        @test BT.global_agents_md(state) == "## House rules\nBe pedantic."
        # Clearing works too.
        BT.set_global_agents_md!(state, "")
        @test BT.global_agents_md(state) == ""
    end

    @testset "agents_prompt_appendix: built-in rules always ride along" begin
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(), worker_secret = "x")
        # No user AGENTS.md → the appendix IS the built-in rules (never empty,
        # so every Claude session gets the house rules).
        @test BT.agents_prompt_appendix(state) == BT.BUILTIN_AGENT_RULES
        @test occursin("bt_julia_eval", BT.BUILTIN_AGENT_RULES)
        # Every background-capable tool is NAMED, so the agent is told what to
        # reach for instead of inventing a shell incantation...
        for tool in ("run_in_background", "bt_julia_continue", "Task")
            @test occursin(tool, BT.BUILTIN_AGENT_RULES)
        end
        # ... and the shell forms that produce an UNTRACKED orphan are named
        # too. Backgrounding this way yields no completion signal, no task-bar
        # pill and no notification, so the agent falls back to polling — the
        # zombie-watcher failure the rest of the rule is about.
        for shell in ("nohup", "disown", "setsid", "screen -dm", "tmux new -d")
            @test occursin(shell, BT.BUILTIN_AGENT_RULES)
        end
        # User AGENTS.md composes AFTER the built-in rules.
        BT.set_global_agents_md!(state, "## House rules\nBe pedantic.")
        appendix = BT.agents_prompt_appendix(state)
        @test startswith(appendix, BT.BUILTIN_AGENT_RULES)
        @test endswith(appendix, "Be pedantic.")
        # And the composed appendix is what system_prompt_meta ships.
        m = BT.system_prompt_meta(appendix)
        @test m["_meta"]["systemPrompt"]["append"] == appendix
    end

    @testset "control channel + interrupt round-trip" begin
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(),
                                 worker_secret = "unused")
        state.projects[]["ctrl-proj"] = BT.ProjectInfo("ctrl-proj", "ctrl", "ctrl-worker",
                                                       mktempdir(), mktempdir(), BT.now(BT.UTC))
        # A live server for the requests that report on it.
        srv = Bonito.Server(Bonito.App(() -> Bonito.DOM.div("x")), "127.0.0.1", 0)
        state.srv = srv
        server_link, worker_link = link_pair(; on_open = ch -> BT.accept_worker_channel(state, "ctrl-worker", ch))
        state.worker_links["ctrl-worker"] = server_link
        relay = BonitoWorker.start_mcp_relay(worker_link)
        try
            # The REAL BonitoMCP control loop, armed with a grant the way the
            # worker arms a chat's MCP process.
            # The control channel is once-per-process; reset for test isolation.
            # `reset_ctrl_dialback!` stops any prior loop, waits it out, and
            # clears grant/task/ws/stop so this arm starts fresh.
            BonitoMCP.reset_ctrl_dialback!()
            BonitoMCP.take_relay_grant!(BonitoWorker.mcp_relay_env(relay, "ctrl-proj"))
            BonitoMCP.start_ctrl_dialback!()
            @test timedwait(5.0) do
                BT.mcp_ctrl_for(state, "ctrl-proj") !== nothing
            end === :ok

            # Full round-trip: request → MCP process → interrupt_result reply.
            n = BT.interrupt_project_eval!(state, "ctrl-proj")
            @test n == 0                       # nothing in flight, but it answered

            # Scoped form goes through the same path.
            n2 = BT.interrupt_project_eval!(state, "ctrl-proj";
                                            env_path = "/tmp/nonexistent-env")
            @test n2 == 0

            # Unknown project fails fast with a clear error.
            @test_throws ErrorException BT.interrupt_project_eval!(state, "nope")

            # ── the OTHER direction: the debug chat's dev tools ──────────────
            # Same channel, MCP → server. This is the only place the request
            # framing on both sides is exercised against a real wire; every
            # other dev-API test calls `dev_request` directly and would pass
            # even if the two halves disagreed about the frame shape.
            @testset "dev_request round-trip (MCP → server → reply)" begin
                BT.install_log_ring!()
                @info "unit:mcp_ctrl dev probe"

                overview = BonitoMCP.call_server("inspect"; section = "overview")
                @test overview isa AbstractDict
                @test overview["pid"] == getpid()
                @test haskey(overview["counts"], "projects")

                logs = BonitoMCP.call_server("logs"; limit = 50,
                                             contains = "unit:mcp_ctrl dev probe")
                @test logs["matched"] >= 1

                mem = BonitoMCP.call_server("memory"; gc = false)
                @test mem["live_bytes_after"] > 0

                # An op the server rejects comes back as an ERROR the tool can
                # report — not a hang until the timeout, which is what a dropped
                # reply would look like.
                @test_throws Exception BonitoMCP.call_server("no-such-op")
                @test_throws Exception BonitoMCP.call_server("inspect"; section = "bogus")

                # And through the registered TOOL, exactly as the agent calls it
                # — including the gate that decides whether it exists at all.
                withenv("BONITOAGENTS_DEV_TOOLS" => "1") do
                    tool = only(filter(t -> t.name == "bt_dev_inspect",
                                       BonitoMCP.available_tools()))
                    res = tool.handler(Dict{String,Any}("section" => "overview"))
                    @test res["isError"] == false
                    @test occursin("\"pid\"", res["content"][1]["text"])
                    # A bad section is a tool error with a usable message.
                    bad = tool.handler(Dict{String,Any}("section" => "bogus"))
                    @test bad["isError"] == true
                    @test occursin("bogus", bad["content"][1]["text"])
                end
                withenv("BONITOAGENTS_DEV_TOOLS" => nothing) do
                    @test !any(t -> t.name == "bt_dev_inspect", BonitoMCP.available_tools())
                end
            end
        finally
            # Stop the loop first, so it doesn't reconnect into the closing relay.
            BonitoMCP.reset_ctrl_dialback!()
            close(relay)
            foreach(l -> WorkerLink.kill!(l, "done"), (server_link, worker_link))
            close(srv)
        end
    end
end

end
