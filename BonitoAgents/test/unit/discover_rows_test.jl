# A discovered row is a snapshot: what its folder compares to decide whether to
# re-render, so equal content has to compare equal and a change has to show.
@testitem "unit:discover_rows" tags = [:unit] begin
    using Dates
    using Bonito: Observable, on
    import BonitoAgents as BT

    st = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    card = BT.WorkerCard(st, "w1";
        error_obs = Observable(""), picker_state = Observable(""),
        gh_state = Observable(""), discover_state = Observable(""),
        busy = Observable(BT.BUSY_IDLE),
        discover_busy = Observable(false),
        discover_results = Observable(Dict{String,Any}[]),
        do_import = (a...; k...) -> nothing,
        do_github = (a...; k...) -> nothing,
        trigger_scan = () -> nothing)
    scan = Dict{String,Any}("path" => "/tmp/x", "name" => "x", "session_id" => "s1", "last_used" => 1.0,
                            "kind" => "session", "running" => false, "first_prompt" => "hi")
    row(; k...) = BT.SessionRow(card, scan; k...)

    @testset "equal content compares equal, so a folder doesn't re-render" begin
        @test row() == row()
        @test [row(), row()] == [row(), row()]
        changing = Observable([row()]; ignore_equal_values = true)
        renders = Ref(0)
        on(_ -> (renders[] += 1), changing)
        changing[] = [row()]
        @test renders[] == 0
        changing[] = [row(; titles = Dict("s1" => "Renamed"))]
        @test renders[] == 1
    end

    @testset "the title: the preview, unless a chat pins one" begin
        @test row().title == "hi"
        @test row(; titles = Dict("other" => "Renamed")).title == "hi"
        @test row(; titles = Dict("s1" => "Renamed")).title == "Renamed"
        @test BT.SessionRow(card, merge(scan, Dict{String,Any}("first_prompt" => nothing))).title == "Untitled session"
    end

    @testset "the pill: open in the sidebar" begin
        @test !row().open
        @test row(; imported = Set(["s1"])).open
        @test !BT.SessionRow(card, merge(scan, Dict{String,Any}("session_id" => nothing)); imported = Set([""])).open
    end

    @testset "pinned titles: this worker's, by session" begin
        function chat(id; session, worker = "w1", title = id)
            p = BT.ProjectInfo(id, id, worker, joinpath(st.working_dir, id), "/work/" * id, now(UTC))
            p.resume_session_id = session
            p.title[] = title
            return id => p
        end
        projects = Dict(chat("a"; session = "s1", title = "A"), chat("b"; session = "s2", worker = "w2"),
                        chat("c"; session = nothing), chat("d"; session = ""))
        @test BT.pinned_titles(projects, "w1") == Dict("s1" => "A")
    end
end
