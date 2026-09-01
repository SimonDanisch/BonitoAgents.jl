@testitem "unit:mcp_ctrl" tags = [:unit] begin

# MCP control channel (/mcp-ws) — the transport the per-tool eval interrupt
# rides on — plus the AGENTS.md → system-prompt `_meta` plumbing.
#
#   1. Real WS round-trip: a BonitoMCP `start_ctrl_dialback!` (driven by the
#      same env vars production uses) dials a live BonitoAgents server;
#      `interrupt_project_eval!` sends `interrupt_eval` and gets the
#      `interrupt_result` reply (0 interrupted — no eval in flight, but the
#      whole path server → MCP process → reply → pending_rpcs is exercised).
#      The SAME socket also carries the debug chat's `bt_dev_*` requests in the
#      opposite direction (MCP → server → reply), which is exercised here too.
#   2. `system_prompt_meta`: empty text ⇒ no `_meta` (params byte-identical
#      to before); non-empty ⇒ the claude_code preset with `append`.
#   3. `global_agents_md` round-trip through the state dir.

using Test
using Bonito
using BonitoAgents
import BonitoMCP
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

    @testset "ctrl dial-back + interrupt round-trip" begin
        state = BT.ServerState(; state_dir = mktempdir(),
                                 working_dir = mktempdir(),
                                 worker_secret = "ctrl-secret")
        # A minimal live server carrying just the WS routes.
        srv = Bonito.Server(Bonito.App(() -> Bonito.DOM.div("x")),
                            "127.0.0.1", 0)
        try
            state.srv = srv
            BT.add_worker_ws_routes!(srv, state)
            url = "http://127.0.0.1:$(srv.port)"

            # Drive the REAL BonitoMCP dial loop with the env production uses.
            withenv("BONITOAGENTS_SERVER_URL" => url,
                    "BONITOAGENTS_SECRET"     => "ctrl-secret",
                    "BONITOAGENTS_PROJECT_ID" => "ctrl-proj") do
                # The control channel is once-per-process; reset for test
                # isolation (other test files don't arm it — env is unset
                # there). `reset_ctrl_dialback!` stops any prior loop, waits
                # it out, and clears task/ws/stop so this arm starts fresh.
                BonitoMCP.reset_ctrl_dialback!()
                BonitoMCP.start_ctrl_dialback!()
            end
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
            # Same socket, MCP → server. This is the only place the request
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
            # Teardown order matters: stop the dial loop (so it doesn't
            # reconnect against the closing server), then close the live
            # ctrl WS — `close(srv)` BLOCKS until its websocket handlers
            # drain, and the handler sits in `for msg in ws` until the
            # socket actually closes. Bounded close as a backstop.
            BonitoMCP.reset_ctrl_dialback!()
            ws = BT.mcp_ctrl_for(state, "ctrl-proj")
            if ws !== nothing
                try
                    close(ws)
                catch e
                    @warn "test_mcp_ctrl: ctrl ws close failed" exception = e
                end
            end
            close_task = @async close(srv)
            timedwait(() -> istaskdone(close_task), 15.0) === :ok ||
                @warn "test_mcp_ctrl: server close didn't drain in time"
        end
    end
end

end
