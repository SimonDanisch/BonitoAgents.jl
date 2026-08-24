# Whether a chat persists its session id is answered by the agent's `initialize`
# handshake (`agentCapabilities.loadSession`), not by a table keyed on provider
# type. The table said no for MiMo/OpenCode/Kimi; all three advertise the
# capability and do replay a real session, so those chats silently started fresh
# every time.
@testitem "unit:resume_gate" tags = [:unit] begin
    using Test
    using Dates
    using Bonito: Observable
    using BonitoAgents
    const BT = BonitoAgents

    fresh_state() = BT.ServerState(; state_dir = mktempdir(),
                                   working_dir = mktempdir(), worker_secret = "x")

    setup(id) = begin
        st   = fresh_state()
        root = mktempdir()
        p    = BT.ProjectInfo(id, "Proj-$id", "w1", root, root, now(UTC))
        st.projects[][id] = p
        agent = BT.WorkerAgent(st, "w1", root)
        (st, p, agent, BT.ChatModel(st, mktempdir(); project_id = id, agent = agent))
    end

    @testset "an id is persisted only when the agent can load it back" begin

        @testset "an agent that never handshook records nothing" begin
            st, p, agent, model = setup("rg1")
            @test agent.loads_sessions == false        # nothing bound it yet
            BT.record_bound_session!(model, "sess-1")
            @test p.resume_session_id === nothing
        end

        @testset "loadSession=true records, whatever the provider is" begin
            for prov in BT.current_providers()
                st, p, agent, model = setup("rg-$(BT.provider_name(prov))")
                agent.provider       = prov
                agent.loads_sessions = true
                BT.record_bound_session!(model, "sess-$(BT.provider_name(prov))")
                @test p.resume_session_id == "sess-$(BT.provider_name(prov))"
            end
        end

        @testset "loadSession=false records nothing, whatever the provider is" begin
            for prov in BT.current_providers()
                st, p, agent, model = setup("rgx-$(BT.provider_name(prov))")
                agent.provider       = prov
                agent.loads_sessions = false
                BT.record_bound_session!(model, "sess-x")
                @test p.resume_session_id === nothing
            end
        end

        @testset "a discovered row carries the agent that owns it" begin
            st = fresh_state()
            card = BT.WorkerCard(st, "w1";
                error_obs = Observable(""), picker_state = Observable(""),
                discover_state = Observable(""), busy = Observable(BT.BUSY_IDLE),
                discover_busy = Observable(false),
                discover_results = Observable(Dict{String,Any}[]),
                do_import = (a...; k...) -> nothing, trigger_scan = () -> nothing)
            base = Dict{String,Any}("path" => "/tmp/x", "name" => "x",
                                    "session_id" => "s1", "last_used" => 1.0,
                                    "kind" => "session", "running" => false,
                                    "first_prompt" => "hi")

            # session/list rows name their provider; the row shows it and hands
            # it to the import, so resuming reaches the agent that has the id.
            acp = BT.SessionRow(card, merge(base, Dict{String,Any}(
                "agent_type" => nothing, "provider" => "KimiCode")))
            @test acp.provider == "KimiCode"
            @test occursin("KimiCode", acp.meta)

            # A Claude file-scan row has no `provider` key, and `agent_type`
            # keeps its own meaning there (the SUBAGENT type).
            file = BT.SessionRow(card, merge(base, Dict{String,Any}(
                "kind" => "subagent", "agent_type" => "Explore")))
            @test file.provider == ""
            @test occursin("subagent: Explore", file.meta)
        end

        @testset "the recorded pair reaches disk together" begin
            st, p, agent, model = setup("rg2")
            prov = last(BT.current_providers())
            agent.provider       = prov
            agent.loads_sessions = true
            BT.record_project_provider!(model, prov)
            BT.record_bound_session!(model, "sess-2")

            st2 = BT.ServerState(; state_dir = st.state_dir,
                                 working_dir = mktempdir(), worker_secret = "x")
            loaded = st2.projects[]["rg2"]
            @test loaded.resume_session_id == "sess-2"
            @test loaded.provider == BT.provider_name(prov)
            # And it comes back up under the agent that minted it.
            @test BT.project_provider(loaded) === prov
        end
    end
end
