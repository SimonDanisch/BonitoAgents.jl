# Provider switching against the first-class-agent model.
#
# What changed: the old `@enum AgentProvider ClaudeCode/MiMoCode/OpenCode/MockCode`
# plus the `provider_label`/`provider_icon`/`find_provider_bin` tables and the
# `LocalTransport(; provider=)` / `WorkerTransport(; provider=)` constructors are
# GONE. An agent is now a first-class TYPE (`ClaudeCodeAgent` / `MiMoAgent` /
# `OpenCodeAgent` / `MockAgent` <: `BinAgent`); `switch_provider!(model, kind)`
# swaps the live agent INSTANCE's kind (not an enum on a transport).
#
# So the plumbing checks become UNIT tests over the agent types
# (`provider_name`/`label`/`icon`/`AGENT_KINDS`), and the switch checks drive a
# real local chat backed by a `MockAgent` (the only real-spawned agent without
# external binaries): `switch_provider!` must swap the agent kind AND restart the
# session alive. Headless — no Electron. The ONLY thing faked is the agent
# behaviour (the mock subprocess + ACP handshake are real).
#
# NOTE on subprocess hygiene: `switch_provider!` builds a fresh agent instance
# for the new kind but does NOT tear down the OLD agent's subprocess (it only
# reassigns `model.agent`; the old client is left open — a real leak in
# `switch_provider!`). The tests therefore capture each pre-switch agent and
# `stop!` it explicitly, so the suite leaves no orphaned mock processes. A plain
# `restart_chat_session!` on a single agent is leak-free (see test_transport_eof).

using Test
using BonitoAgents
using BonitoAgents.AgentClientProtocol
isdefined(Main, :BT) || (const BT = BonitoAgents)

newstate_ps() = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                                 worker_secret = "x")

# Build a live local chat on a real MockAgent (normal scenario) without a
# browser. `start_chat_client!` spawns the mock subprocess + does the ACP
# handshake. Returns the model; caller MUST `BT.stop!(model.agent)` in a finally.
function live_mock_chat(; scenario = "normal")
    st  = newstate_ps()
    ag  = BT.MockAgent(; cwd = mktempdir())
    ag.env["BT_MOCK_ACP_SCENARIO"] = scenario
    m   = BT.ChatModel(st, ag.cwd; agent = ag)
    BT.start_chat_client!(m)
    return m
end

# Switch the chat to `kind` and reap the orphaned pre-switch agent's subprocess
# (see the module note). Returns nothing; `model.agent` is the new live agent.
function switch_and_reap!(model, kind)
    old = model.agent
    BT.switch_provider!(model, kind)
    old === model.agent || BT.stop!(old)   # switch left the old subprocess open
    return nothing
end

# Count live mock subprocesses (pgrep exits 1 ⇒ none).
mock_proc_count() =
    try parse(Int, strip(read(`pgrep -fc mock_claude_agent_acp.jl`, String))) catch; 0 end

@testset "agent provider plumbing (over the new agent types)" begin
    # provider_name is the wire string the worker keys on AND the UI's stable
    # provider identity; label/icon are the human-facing display strings. These
    # replace the deleted provider_label/provider_icon tables and the enum.
    @test BT.provider_name(BT.ClaudeCodeAgent()) == "ClaudeCode"
    @test BT.provider_name(BT.MiMoAgent())       == "MiMoCode"
    @test BT.provider_name(BT.OpenCodeAgent())   == "OpenCode"
    @test BT.provider_name(BT.MockAgent())       == "MockCode"

    @test BT.label(BT.MockAgent()) == "Mock Agent"
    @test BT.icon(BT.MockAgent())  == "bt-provider-mock"

    # AGENT_KINDS is the menu tuple (replaces `instances(AgentProvider)`). Every
    # kind has a non-empty label + icon and a stable wire name.
    @test BT.MockAgent in BT.AGENT_KINDS
    for K in BT.AGENT_KINDS
        a = K(; cwd = mktempdir())
        @test a isa BT.BinAgent
        @test !isempty(BT.provider_name(a))
        @test !isempty(BT.label(a))
        @test !isempty(BT.icon(a))
    end

    # The Mock binary resolves to a real on-disk file (replaces the old
    # `find_provider_bin(MockCode)` check). It's the bin a MockAgent spawns.
    mb = BT.mock_bin()
    @test isfile(mb)
    @test occursin("mock_claude_agent_acp", mb)
end

@testset "switch_provider! swaps the agent kind on a live chat" begin
    # Old: `switch_provider!` flipped a `transport.provider` enum on a
    # LocalTransport/WorkerTransport. New: it swaps the live agent INSTANCE to a
    # fresh one of the requested KIND, carrying the chat context, then restarts.
    model = live_mock_chat()
    try
        @test BT.agent_kind(model.agent) == BT.MockAgent
        @test model.provider[] == BT.MockAgent
        @test BT.provider_name(model.agent) == "MockCode"

        old_agent = model.agent
        # Switch to ClaudeCodeAgent, but point its binary at the mock so the
        # bring-up genuinely succeeds (no real claude-agent-acp in CI). This
        # exercises a REAL kind change with a live, alive session — exactly the
        # old "provider enum changed + session restarts" intent, expressed
        # against the agent model. (The bin resolver reads CLAUDE_AGENT_ACP.)
        withenv("CLAUDE_AGENT_ACP" => BT.mock_bin()) do
            BT.switch_provider!(model, BT.ClaudeCodeAgent)
        end

        @test BT.agent_kind(model.agent) == BT.ClaudeCodeAgent   # kind genuinely changed
        @test model.agent !== old_agent                          # fresh instance
        @test model.provider[] == BT.ClaudeCodeAgent             # provider obs tracks the agent
        @test BT.provider_name(model.agent) == "ClaudeCode"
        @test model.session_alive[] == true                      # session restarted alive
        @test isempty(model.last_error[])
        @test BT.client(model.agent) !== nothing

        BT.stop!(old_agent)   # reap the orphaned pre-switch subprocess
    finally
        BT.stop!(model.agent)
    end
end

@testset "switch_provider! to the SAME kind makes a fresh, alive instance" begin
    # The old MockTransport test asserted a switch creates a FRESH transport
    # (`!== old_transport`) and the session stays alive. Mapped: a switch builds
    # a fresh agent INSTANCE even for the same kind, and re-brings-up alive.
    model = live_mock_chat()
    try
        old_agent = model.agent
        BT.switch_provider!(model, BT.MockAgent)
        @test model.agent !== old_agent                # fresh instance
        @test model.agent isa BT.MockAgent
        @test BT.agent_kind(model.agent) == BT.MockAgent
        @test model.provider[] == BT.MockAgent
        @test model.session_alive[] == true
        @test isempty(model.last_error[])
        @test BT.client(model.agent) !== nothing
        BT.stop!(old_agent)   # reap the orphaned pre-switch subprocess
    finally
        BT.stop!(model.agent)
    end
end

@testset "rapid switches: last switch wins, session alive, no orphan leak" begin
    # The provider-switcher coalesces rapid clicks via RESTART_GEN; the final
    # session must reflect the LAST switch and stay alive. Each switch swaps the
    # agent instance + restarts; none may leave the chat dead. `switch_and_reap!`
    # tears down each orphaned pre-switch subprocess so the cycle leaks nothing.
    before = mock_proc_count()
    model = live_mock_chat()
    try
        withenv("CLAUDE_AGENT_ACP" => BT.mock_bin(),
                "MOCK_AGENT_ACP"   => BT.mock_bin()) do
            for kind in (BT.ClaudeCodeAgent, BT.MockAgent, BT.ClaudeCodeAgent, BT.MockAgent)
                switch_and_reap!(model, kind)
                @test BT.agent_kind(model.agent) == kind
                @test model.session_alive[] == true
                @test isempty(model.last_error[])
            end
        end
        @test BT.agent_kind(model.agent) == BT.MockAgent   # last switch wins
        @test BT.client(model.agent) !== nothing
    finally
        BT.stop!(model.agent)
    end
    # All reaped: net mock-subprocess count returns to the pre-test baseline.
    @test timedwait(() -> mock_proc_count() <= before, 6.0) === :ok
end
