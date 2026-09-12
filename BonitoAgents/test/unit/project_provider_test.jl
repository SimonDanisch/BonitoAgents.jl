# A thread belongs to the agent that made it. `resume_session_id` is THAT agent's
# session id, and asking a different one to `session/load` it fails with a session
# it never created — which is why `switch_provider!` clears the id when you switch.
#
# So the project remembers which agent it was last used with, and reopening it (a
# reload, a server restart, the model being evicted) brings that one back. Before
# this, the choice lived only on the live `ChatModel` and every bring-up reset to
# `default_provider()`, so a Kimi chat came back as Claude.
#
# The stored value is the wire NAME (`provider_name`), the same string already
# sent to the worker on every `open_session` — so it stays a preference the
# worker resolves, not a promise this machine can keep.
@testitem "unit:project_provider" tags = [:unit] begin
    using Test
    using Dates
    using BonitoAgents
    const BT = BonitoAgents

    fresh_state() = BT.ServerState(; state_dir = mktempdir(),
                                   working_dir = mktempdir(), worker_secret = "x")

    project!(st, id) = begin
        root = mktempdir()
        p = BT.ProjectInfo(id, "Proj-$id", "w1", root, root, now(UTC))
        st.projects[][id] = p
        p
    end

    @testset "a project remembers which agent it belongs to" begin

        @testset "the choice survives a restart" begin
            st = fresh_state()
            p  = project!(st, "pp1")
            p.provider          = "KimiCode"
            p.resume_session_id = "sess-kimi-1"
            lock(st.lock) do; BT.save_projects!(st); end

            # A second ServerState over the same state dir IS the restart: the
            # constructor loads projects.json.
            st2 = BT.ServerState(; state_dir = st.state_dir,
                                 working_dir = mktempdir(), worker_secret = "x")
            @test st2.projects[]["pp1"].provider          == "KimiCode"
            # The pair travels together or not at all — a resume id without the
            # agent that issued it is the bug this whole field exists to prevent.
            @test st2.projects[]["pp1"].resume_session_id == "sess-kimi-1"
        end

        @testset "a projects.json written before this field loads as 'default'" begin
            st = fresh_state()
            p  = project!(st, "pp2")
            lock(st.lock) do; BT.save_projects!(st); end
            # Strip the key the way an older build's file would have it.
            f    = BT.projects_file(st)
            rows = BT.JSON.parse(read(f, String))
            for r in rows; delete!(r, "provider"); end
            write(f, BT.JSON.json(rows))

            st2 = BT.ServerState(; state_dir = st.state_dir,
                                 working_dir = mktempdir(), worker_secret = "x")
            loaded = st2.projects[]["pp2"]
            @test loaded.provider === nothing
            @test BT.project_provider(loaded) === BT.default_provider()
        end

        @testset "a stored agent that IS installed here resolves to it" begin
            st = fresh_state()
            p  = project!(st, "pp3")
            # Whatever this machine actually has — the assertion is identity, so
            # it holds on a box with one provider and on a box with five.
            prov = first(BT.current_providers())
            p.provider = BT.provider_name(prov)
            @test BT.project_provider(p) === prov
        end

        @testset "an agent that is gone falls back instead of throwing" begin
            st = fresh_state()
            p  = project!(st, "pp4")
            p.provider = "AgentThatWasUninstalled"
            # Uninstalled since, or the project was copied to another worker.
            # Opening with the default beats refusing to open. Resolution itself
            # stays quiet: it runs per card on the overview, and the bring-up in
            # `dashboard.jl` is what reports the substitution.
            # No patterns ⇒ asserts NOTHING is logged at Info or above.
            @test_logs begin
                @test BT.project_provider(p) === BT.default_provider()
            end
        end

        @testset "recording a switch persists it, and only on a real change" begin
            st  = fresh_state()
            p   = project!(st, "pp5")
            dir = mktempdir()
            agent = BT.WorkerAgent(st, "w1", p.worker_path)
            model = BT.ChatModel(st, dir; project_id = "pp5", agent = agent)

            prov = first(BT.current_providers())
            BT.record_project_provider!(model, prov)
            @test p.provider == BT.provider_name(prov)

            # It reached disk, not just the struct.
            st2 = BT.ServerState(; state_dir = st.state_dir,
                                 working_dir = mktempdir(), worker_secret = "x")
            @test st2.projects[]["pp5"].provider == BT.provider_name(prov)

            # Re-selecting the current agent must not rewrite the file — the
            # dropdown re-emits its value on every re-render.
            before = mtime(BT.projects_file(st))
            sleep(0.01)
            BT.record_project_provider!(model, prov)
            @test mtime(BT.projects_file(st)) == before
        end

        @testset "switching records it, even when the restart can't land" begin
            st    = fresh_state()
            p     = project!(st, "pp6")
            agent = BT.WorkerAgent(st, "w1", p.worker_path)
            model = BT.ChatModel(st, mktempdir(); project_id = "pp6", agent = agent)

            cur   = BT.shared(model).provider[]
            provs = BT.current_providers()
            other = provs[findfirst(p -> p !== cur, provs)]

            # No worker is connected here, so the restart inside `switch_provider!`
            # fails and is swallowed by design (the chat stays alive with
            # `last_error` set). The RECORD still has to stand: it is written with
            # the `resume_session_id` clear, BEFORE the restart — otherwise a
            # switch whose bring-up fails would leave the project pointing at the
            # old agent while the live chat runs the new one, and the next reopen
            # would hand the new agent's session id to the old one.
            @test_logs (:error,) match_mode = :any BT.switch_provider!(model, other)
            @test p.provider == BT.provider_name(other)
            @test BT.shared(model).agent.provider === other
            # Cleared for the new agent: the old id means nothing to it.
            @test BT.shared(model).agent.resume_session_id === nothing
        end
    end
end
