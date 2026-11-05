# The worker's half of "Delete chat": `delete_session` removes what belongs to one
# session and nothing else, and refuses an id that could reach anything else.
@testitem "unit:delete_session" tags = [:unit] begin
    using BonitoWorker
    import BonitoAgents as BT
    const AgentProviders = BT.AgentProviders

    # Claude's layout, under a throwaway home.
    provider = AgentProviders.provider_name(AgentProviders.ClaudeCodeAgent())
    fmt = AgentProviders.session_state_format(AgentProviders.ClaudeCodeAgent())
    home = mktempdir()
    cwd = "/some/project"
    dir = AgentProviders.transcript_dir(fmt, home, cwd)
    delete(session_id) = BonitoWorker.delete_session(; provider, cwd, session_id, home)

    function seed!(sid)
        mkpath(joinpath(dir, sid))
        write(joinpath(dir, sid * ".jsonl"), "{}\n")
        write(joinpath(dir, sid, "sub.jsonl"), "{}\n")
    end

    @testset "removes the session's own entries, nothing else" begin
        seed!("session-a")
        seed!("session-b")
        mkpath(joinpath(dir, "memory"))
        write(joinpath(dir, "memory", "MEMORY.md"), "shared\n")

        @test sort(delete("session-a")) == ["session-a", "session-a.jsonl"]
        @test !ispath(joinpath(dir, "session-a.jsonl"))
        @test !ispath(joinpath(dir, "session-a"))
        @test isfile(joinpath(dir, "session-b.jsonl"))
        @test isfile(joinpath(dir, "session-b", "sub.jsonl"))
        @test isfile(joinpath(dir, "memory", "MEMORY.md"))
    end

    @testset "a record that's already gone is not an error" begin
        @test delete("session-a") == String[]
        @test delete("never-existed") == String[]
    end

    @testset "refuses an id that isn't one session's own name" begin
        victim = joinpath(home, "outside.txt")
        write(victim, "keep\n")
        for bad in ("", ".", "..", "memory", "../../outside.txt", "a/b", "a\\b", "*")
            @test_throws ErrorException delete(bad)
        end
        @test isfile(victim)
        @test isfile(joinpath(dir, "memory", "MEMORY.md"))
        @test isfile(joinpath(dir, "session-b.jsonl"))
    end

    @testset "session and memory can be removed independently" begin
        for session in (false, true), memory in (false, true)
            seed!("chosen")
            mkpath(joinpath(dir, "memory", "nested"))
            write(joinpath(dir, "memory", "MEMORY.md"), "shared\n")
            write(joinpath(dir, "memory", "nested", "notes.md"), "more memory\n")
            removed = BonitoWorker.delete_session(; provider, cwd, session_id = "chosen",
                                                  session, memory, home)
            @test isfile(joinpath(dir, "chosen.jsonl")) == !session
            @test isdir(joinpath(dir, "chosen")) == !session
            @test isdir(joinpath(dir, "memory")) == !memory
            @test ("memory" in removed) == memory
            @test isfile(joinpath(dir, "session-b.jsonl"))
        end
        # Memory can also be wiped before the first agent session is bound.
        mkpath(joinpath(dir, "memory"))
        @test BonitoWorker.delete_session(; provider, cwd, session_id = "",
            session = false, memory = true, home) == ["memory"]
    end

    @testset "refuses an agent whose record it can't identify" begin
        @test_throws ErrorException BonitoWorker.delete_session(;
            provider = "not-an-agent", cwd, session_id = "session-b", home)
        @test isfile(joinpath(dir, "session-b.jsonl"))
    end
end

# What the confirmation promises has to match what `delete_chat!` will do.
@testitem "unit:delete_chat_question" tags = [:unit] begin
    using Dates
    import BonitoAgents as BT
    const AgentProviders = BT.AgentProviders

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    function chat(id; session = nothing, provider = nothing, worker = "w1", folder = "/work/" * id)
        p = BT.ProjectInfo(id, id, worker, joinpath(state.working_dir, id), folder, now(UTC))
        p.resume_session_id = session
        p.provider = provider
        state.projects[][id] = p
        return p
    end

    @testset "a session we can identify is deleted, and the question says so" begin
        p = chat("a"; session = "sid-a")
        @test BT.deletable_session(state, p) == "sid-a"
        @test occursin("the agent's session on its worker are removed", BT.delete_chat_question(state, p))
    end

    @testset "no session yet: only the transcript" begin
        p = chat("b")
        @test BT.deletable_session(state, p) === nothing
        @test occursin("Its transcript is removed. Shared", BT.delete_chat_question(state, p))
    end

    @testset "a session another chat in the folder resumes stays" begin
        p = chat("c"; session = "sid-shared", folder = "/work/shared")
        q = chat("d"; session = "sid-shared", folder = "/work/shared")
        @test BT.deletable_session(state, p) === nothing
        @test BT.deletable_session(state, q) === nothing
        delete!(state.projects[], "d")
        @test BT.deletable_session(state, p) == "sid-shared"
        # The same id on ANOTHER worker, or in another folder, is another record.
        chat("e"; session = "sid-shared", worker = "w2", folder = "/work/shared")
        chat("g"; session = "sid-shared", folder = "/work/elsewhere")
        @test BT.deletable_session(state, p) == "sid-shared"
    end

    @testset "an agent whose record we can't identify: the question says it stays" begin
        name = AgentProviders.provider_name(AgentProviders.CodexAgent())
        p = chat("f"; session = "sid-f", provider = name)
        @test BT.deletable_session(state, p) === nothing
        @test occursin("$(name)'s own copy on its worker stays", BT.delete_chat_question(state, p))
    end

    @testset "every question says what stays and that it's final" begin
        for p in values(state.projects[])
            q = BT.delete_chat_question(state, p)
            @test occursin("Project files stay", q)
            @test occursin("can't be undone", q)
        end
    end
end
