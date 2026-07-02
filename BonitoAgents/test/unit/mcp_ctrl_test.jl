@testitem "unit:mcp_ctrl" tags = [:unit] begin

# MCP control channel (/mcp-ws) — the transport the per-tool eval interrupt
# rides on — plus the AGENTS.md → system-prompt `_meta` plumbing.
#
#   1. Real WS round-trip: a BonitoMCP `start_ctrl_dialback!` (driven by the
#      same env vars production uses) dials a live BonitoAgents server;
#      `interrupt_project_eval!` sends `interrupt_eval` and gets the
#      `interrupt_result` reply (0 interrupted — no eval in flight, but the
#      whole path server → MCP process → reply → pending_rpcs is exercised).
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
        @test occursin("Background commands", BT.BUILTIN_AGENT_RULES)
        @test occursin("bt_julia_eval", BT.BUILTIN_AGENT_RULES)
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
                # CTRL_TASK is once-per-process; reset for test isolation
                # (other test files don't arm it — env is unset there).
                BonitoMCP.CTRL_STOP[] = false
                BonitoMCP.CTRL_TASK[] = nothing
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
        finally
            # Teardown order matters: stop the dial loop (so it doesn't
            # reconnect against the closing server), then close the live
            # ctrl WS — `close(srv)` BLOCKS until its websocket handlers
            # drain, and the handler sits in `for msg in ws` until the
            # socket actually closes. Bounded close as a backstop.
            BonitoMCP.CTRL_STOP[] = true
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
