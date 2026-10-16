# A tool body that arrives after its row, and a picture whose bytes arrive after
# its element, both moved everything below them when they landed. The browser
# reports what it measured once, and later renders carry it: a history row its
# body's height (`body_h`), a media element its file's natural size. These drive
# the real wire parse, handlers, stores and their files.
@testitem "unit:measured_sizes" tags = [:unit] begin
    using BonitoAgents
    using Bonito
    import AgentClientProtocol
    import JSON
    const BT = BonitoAgents
    const ACP = AgentClientProtocol

    sdir = mktempdir()
    state = BT.ServerState(; state_dir = sdir, working_dir = mktempdir())
    root = mktempdir()
    state.projects[]["p1"] = BT.ProjectInfo("p1", "Sizes", "w1", root, root, BT.now(BT.UTC))
    chat(st) = BT.ChatModel(st, root; project_id = "p1", agent = BT.WorkerAgent(st, "w1", root))
    model = chat(state)
    session = Bonito.Session()
    size_cmd(d) = BT.parse_chat_command(Dict{String,Any}(d))

    @testset "the wire" begin
        cmd = size_cmd(("type" => "media.size", "path" => "/w/a.png", "w" => 640, "h" => 480))
        @test cmd isa BT.MediaSizeCommand && cmd.path == "/w/a.png" && (cmd.w, cmd.h) == (640, 480)
        cmd = size_cmd(("type" => "tool.size", "id" => "t1", "w" => 600.4, "h" => 311.6))
        @test cmd isa BT.BodyHeightCommand && cmd.tool_id == "t1" && (cmd.w, cmd.h) == (600, 312)
        for bad in (("w" => 0, "h" => 5), ("w" => 5,), ("w" => "5", "h" => 5),
                    ("w" => 5, "h" => 1e9), ("w" => NaN, "h" => 5))
            @test size_cmd(("type" => "tool.size", "id" => "t1", bad...)) isa BT.UnknownCommand
        end
        @test size_cmd(("type" => "media.size", "w" => 5, "h" => 5)) isa BT.UnknownCommand
        @test size_cmd(("type" => "tool.size", "w" => 5, "h" => 5)) isa BT.UnknownCommand
    end

    @testset "a picture's size, by its worker file, survives a restart" begin
        @test BT.media_size(state, "w1", "/w/a.png") === nothing
        BT.handle_command!(model, session, BT.MediaSizeCommand("/w/a.png", 640, 480))
        @test BT.media_size(state, "w1", "/w/a.png") == (640, 480)
        @test BT.media_size(state, "w2", "/w/a.png") === nothing      # another worker's file
        st = BT.ShowTool(state, "p1", root, "/w/a.png")
        @test BT.media_size(st) == (640, 480)
        again = BT.ServerState(; state_dir = sdir, working_dir = mktempdir())
        @test BT.media_size(again, "w1", "/w/a.png") == (640, 480)
    end

    function render_html(x)
        s = Bonito.Session(Bonito.NoConnection(); asset_server = Bonito.NoServer())
        dom = Bonito.session_dom(s, Bonito.App(() -> DOM.div(x)))
        return sprint(io -> show(io, MIME"text/html"(), dom))
    end

    @testset "the media element lays out at that size" begin
        img = render_html(BT.media_element("/f.png", "image/png", false; worker_path = "/w/a.png",
                                           size = (640, 480)))
        @test occursin(r"<img[^>]*\swidth=\"640\"", img)
        @test occursin(r"<img[^>]*\sheight=\"480\"", img)
        vid = render_html(BT.media_element("/f.mp4", "video/mp4", true; size = (1920, 1080)))
        @test occursin(r"<video[^>]*\swidth=\"1920\"", vid)
        none = render_html(BT.media_element("/f.png", "image/png", false))
        @test !occursin(r"<img[^>]*\swidth=\"", none)
    end

    @testset "a tool body's height, by width, comes with its row" begin
        fixtures = joinpath(dirname(dirname(pathof(ACP))), "test", "fixtures")
        out = Channel{Any}(256)
        ts = ACP.TurnState()
        for l in eachline(joinpath(fixtures, "kimi_mcp_tool_call.jsonl"))
            ACP.parse_update!(out, ts, ACP.parse_session_update(JSON.parse(l)))
        end
        ACP.close_turn!(out, ts); close(out)
        m = BT.replayed_tool_msg(only(x for x in collect(out) if x isa ACP.ToolCall))
        push!(model.msgs_store, m)
        id = BT.tool_id(m)
        @test !haskey(BT.row_dict(model, m), "body_h")

        BT.handle_command!(model, session, BT.BodyHeightCommand(id, 600, 312))
        @test BT.row_dict(model, m)["body_h"] == Dict("600" => 312)
        BT.handle_command!(model, session, BT.BodyHeightCommand(id, 601, 300))   # the same width
        @test BT.row_dict(model, m)["body_h"] == Dict("601" => 300)
        for w in (320, 800, 1024, 1280)
            BT.handle_command!(model, session, BT.BodyHeightCommand(id, w, w ÷ 2))
        end
        want = Dict("320" => 160, "800" => 400, "1024" => 512, "1280" => 640)   # the oldest went
        @test BT.row_dict(model, m)["body_h"] == want

        # What the browser loads history with carries it.
        @test BT.transcript_tail(model)["msgs"][end]["body_h"] == want
        replies = Dict{String,Any}[]
        on(e -> push!(replies, e), model.comm)
        idx = length(model.msgs_store) - 1
        BT.handle_command!(model, session, BT.MsgsRequestCommand(idx, idx, nothing, 0, 1))
        @test only(replies)["msgs"][1]["body_h"] == want
        tab = copy(model, Bonito.Session())                  # every tab shares one record
        @test BT.body_heights(tab, id) == want
        @test BT.body_heights(chat(state), id) == want       # and it comes back with the chat
    end
end
