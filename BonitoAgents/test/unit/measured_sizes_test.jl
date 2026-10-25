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
        @test cmd isa BT.BodyHeightCommand && cmd.tool_id == "t1" && (cmd.w, cmd.h, cmd.extra) == (600, 312, 0)
        cmd = size_cmd(("type" => "tool.size", "id" => "t1", "w" => 600, "h" => 312, "extra" => 26.2))
        @test cmd isa BT.BodyHeightCommand && cmd.extra == 26
        for bad in (("w" => 0, "h" => 5), ("w" => 5,), ("w" => "5", "h" => 5),
                    ("w" => 5, "h" => 1e9), ("w" => NaN, "h" => 5),
                    ("w" => 5, "h" => 5, "extra" => -1), ("w" => 5, "h" => 5, "extra" => 6),
                    ("w" => 5, "h" => 5, "extra" => "2"))
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

        BT.handle_command!(model, session, BT.BodyHeightCommand(id, 600, 312, 0))
        @test BT.row_dict(model, m)["body_h"] == Dict("600" => 312)
        BT.handle_command!(model, session, BT.BodyHeightCommand(id, 601, 300, 0))   # the same width
        @test BT.row_dict(model, m)["body_h"] == Dict("601" => 300)
        for w in (320, 800, 1024, 1280)
            BT.handle_command!(model, session, BT.BodyHeightCommand(id, w, w ÷ 2, 0))
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

        # A file written before `extra` was measured: its heights, nothing else.
        old = mktempdir()
        write(joinpath(old, "body_heights.json"), JSON.json(Dict("t9" => [[600, 312]])))
        @test only(BT.load_body_heights(old).heights["t9"]) == (600, 312, 0)
    end

    @testset "a bt_show picture: its measured size and its Share row come with its row" begin
        pic = joinpath(root, "shown.png")
        tc = ACP.GenericTool("show-1", "other", "bt_show", "completed",
                             ACP.ToolContent[ACP.TextContent("shown: $(pic) (image/png, 4KB)")],
                             ACP.MessageStream{ACP.ToolCall}())
        BT.persist_tool_content!(model.chat_dir, tc)
        m = BT.GenericToolMsg(BT.Message("show-1", "other", "", "bt_show", "completed", "", 0.0, 0.0, nothing))
        push!(model.msgs_store, m)
        d = BT.row_dict(model, m)
        @test d["show_mime"] == "image/png"
        @test !haskey(d, "media")                            # never shown
        BT.handle_command!(model, session, BT.MediaSizeCommand(pic, 1200, 600))
        @test BT.row_dict(model, m)["media"] == [1200, 600]
        @test !haskey(BT.row_dict(model, m), "media_extra")
        BT.handle_command!(model, session, BT.BodyHeightCommand(BT.tool_id(m), 800, 426, 26))
        d = BT.row_dict(model, m)
        @test d["media_extra"] == 26 && d["body_h"] == Dict("800" => 426)
        @test BT.media_extra(chat(state), BT.tool_id(m)) == 26  # kept with the heights
    end
end

# A picture the agent read carries its bytes, so its size is known before any
# browser saw it: read from the header, for each format pictures come in.
@testitem "unit:image_size" tags = [:unit] begin
    using BonitoAgents
    using Base64
    import AgentClientProtocol
    const BT = BonitoAgents
    const ACP = AgentClientProtocol

    be32(n) = UInt8[(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]
    le16(n) = UInt8[n & 0xff, (n >> 8) & 0xff]
    le24(n) = UInt8[n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff]
    png(w, h) = vcat(b"\x89PNG\r\n\x1a\n", be32(13), b"IHDR", be32(w), be32(h), UInt8[8, 6, 0, 0, 0])
    gif(w, h) = vcat(b"GIF89a", le16(w), le16(h), UInt8[0, 0, 0])
    # SOI, an APP1 segment of 300 bytes (EXIF comes first in a photo), then SOF2.
    jpeg(w, h) = vcat(UInt8[0xff, 0xd8, 0xff, 0xe1], UInt8[0x01, 0x2e], zeros(UInt8, 300),
                      UInt8[0xff, 0xc2, 0x00, 0x11, 0x08, h >> 8, h & 0xff, w >> 8, w & 0xff, 0x03])
    riff(chunk, payload) = vcat(b"RIFF", zeros(UInt8, 4), b"WEBP", chunk, zeros(UInt8, 4), payload)
    webp_lossy(w, h) = riff(b"VP8 ", vcat(UInt8[0, 0, 0, 0x9d, 0x01, 0x2a], le16(w), le16(h)))
    webp_lossless(w, h) = riff(b"VP8L", vcat(UInt8[0x2f],
        let bits = (w - 1) | (h - 1) << 14; UInt8[bits & 0xff, (bits >> 8) & 0xff, (bits >> 16) & 0xff, (bits >> 24) & 0xff] end))
    webp_extended(w, h) = riff(b"VP8X", vcat(zeros(UInt8, 4), le24(w - 1), le24(h - 1)))

    @test BT.image_size(png(1920, 1080)) == (1920, 1080)
    @test BT.image_size(gif(320, 200)) == (320, 200)
    @test BT.image_size(jpeg(4032, 3024)) == (4032, 3024)
    @test BT.image_size(webp_lossy(800, 600)) == (800, 600)
    @test BT.image_size(webp_lossless(1000, 750)) == (1000, 750)
    @test BT.image_size(webp_extended(4096, 2160)) == (4096, 2160)

    # Not a picture, or cut short: no size, rather than a wrong one.
    @test BT.image_size(Vector{UInt8}(b"%PDF-1.7 and so on")) === nothing
    @test BT.image_size(png(10, 10)[1:20]) === nothing
    @test BT.image_size(jpeg(10, 10)[1:200]) === nothing
    @test BT.image_size(UInt8[]) === nothing

    # From an image content's base64, and as the tool's content gives it.
    c = ACP.ImageContent(base64encode(vcat(png(640, 480), rand(UInt8, 100_000))), "image/png")
    @test BT.image_size(c) == (640, 480)
    @test BT.tool_media_size(Any[ACP.TextContent("read it"), c]) == (640, 480)
    @test BT.tool_media_size(Any[ACP.TextContent("no picture")]) === nothing
    @test BT.image_size(ACP.ImageContent("not base64 at all!", "image/png")) === nothing
end
