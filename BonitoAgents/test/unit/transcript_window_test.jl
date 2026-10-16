# The transcript loads one block of messages at a time, and the server answers
# each request to the tab that asked. Range replies used to go out on the
# chat's shared channel, so one tab loading its history pushed every byte of it
# into each other tab with the chat open (5 MB per open of a 10,878-message
# chat, measured). These drive the real handlers through two per-tab copies.
@testitem "unit:transcript_replies" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    const BT = BonitoAgents

    state = BT.serve(; host = "127.0.0.1", port = 0,
                     state_dir = mktempdir(), working_dir = mktempdir())
    parent = BT.ChatModel(state, mktempdir(); project_id = "proj",
                          agent = BT.WorkerAgent(state, "w1", "/p"))
    for i in 0:99
        push!(parent.msgs_store, BT.UserMsg("message $i"))
    end
    sa, sb = Bonito.Session(), Bonito.Session()
    a, b = copy(parent, sa), copy(parent, sb)
    seen(tab) = (events = Dict{String,Any}[]; on(e -> push!(events, e), tab.comm); events)
    ea, eb, shared = seen(a), seen(b), seen(parent)
    texts(r) = [m["text"] for m in r["msgs"]]

    @testset "a range goes to the asking tab only" begin
        BT.handle_command!(a, sa, BT.MsgsRequestCommand(10, 19, nothing, 3, 7))
        @test length(ea) == 1
        r = ea[end]
        @test r["type"] == "msgs.range" && r["start"] == 10
        @test texts(r) == ["message $i" for i in 10:19]
        @test r["epoch"] == 3 && r["req"] == 7
        @test isempty(eb) && isempty(shared)
    end

    @testset "a range past the end is clamped" begin
        BT.handle_command!(a, sa, BT.MsgsRequestCommand(95, 120, nothing, 3, 8))
        r = ea[end]
        @test r["start"] == 95 && texts(r) == ["message $i" for i in 95:99]
    end

    @testset "a lens asks for exactly its matches" begin
        BT.handle_command!(b, sb, BT.MsgsRequestCommand(0, -1, [5, 50, 99, 150], 0, 9))
        r = eb[end]
        @test r["indices"] == [5, 50, 99]            # 150 does not exist
        @test texts(r) == ["message 5", "message 50", "message 99"]
        @test !haskey(r, "start")
        @test length(ea) == 2                        # a saw none of it
    end

    @testset "the count answers init on the asking tab" begin
        n_a = length(ea)
        BT.handle_command!(b, sb, BT.InitCommand())
        @test any(e -> e["type"] == "msgs.count" && e["n"] == 100, eb)
        @test !any(e -> e["type"] == "msgs.count", ea[(n_a + 1):end])
    end

    @testset "the tail the pane is rendered with" begin
        t = BT.transcript_tail(a)
        @test t["n"] == 100 && t["start"] == 60
        @test texts(t) == ["message $i" for i in 60:99]
        @test BT.transcript_tail(a; count = 5)["start"] == 95
        empty = BT.ChatModel(state, mktempdir(); project_id = "empty",
                             agent = BT.WorkerAgent(state, "w1", "/q"))
        @test BT.transcript_tail(empty) == Dict{String,Any}("n" => 0, "start" => 0, "msgs" => Any[])
    end

    @testset "a malformed index list is not a request" begin
        cmd = BT.parse_chat_command(Dict{String,Any}("type" => "msgs.request", "indices" => ["x"]))
        @test cmd isa BT.UnknownCommand
        cmd = BT.parse_chat_command(Dict{String,Any}("type" => "msgs.request", "indices" => [1, 2], "req" => 4))
        @test cmd isa BT.MsgsRequestCommand && cmd.indices == [1, 2] && cmd.req == 4
    end
end

# Every chat open claims its project for the worker. When the worker holds the
# claim already (the usual case) nothing changes, so nothing may be written or
# announced: the write rewrote projects.json and the announcement re-rendered
# the project list in every open tab (53 messages per tab), on each open.
@testitem "unit:claim_unchanged" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    const BT = BonitoAgents

    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    pid = "claim1"
    root = mktempdir()
    p = BT.ProjectInfo(pid, "Claim", "w1", root, root, BT.now(BT.UTC))
    state.projects[][pid] = p
    notified = Ref(0)
    on(_ -> notified[] += 1, state.projects)

    BT.claim_project!(state, p, "w1")
    @test p.locked_by == "w1"
    @test notified[] == 1
    file = joinpath(state.state_dir, "projects.json")
    @test isfile(file)
    written = read(file, String)
    rm(file)

    BT.claim_project!(state, p, "w1")              # nothing changes
    @test notified[] == 1
    @test !isfile(file)
    @test_throws ErrorException BT.claim_project!(state, p, "w2")
    @test p.locked_by == "w1"
    @test !isempty(written)
end
