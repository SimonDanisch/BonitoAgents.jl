@testitem "unit:show_tool" tags = [:unit] begin

# Tests for the `bt_show` file-preview path, end to end:
#
#   bt_show (BonitoMCP)  → emits `shown: <path> (<mime>, <size>)`
#   parse_show_path       → pulls the path back out of that reference
#   ShowTool / fetch_show_file → resolves the worker path to a server file
#   render_show_file      → picks <img> / <video> / Monaco / caption by ext
#   Bonito Range support  → 206 + Content-Range so <video> actually plays
#
# All headless — no Electron, no live worker (the fetch is exercised via the
# "already on the server" short-circuit; the worker WS itself is covered by the
# transfer tests).

using Test
using Dates
using BonitoAgents
using BonitoMCP
using Bonito
const BT = BonitoAgents

# Classify what `render_show_file` produced without needing a live session.
function show_kind(node)
    nameof(typeof(node)) === :MonacoEditor && return :text
    s = sprint(show, node)
    occursin("<img", s)   && return :image
    occursin("<video", s) && return :video
    occursin("bt-tool-empty", s) && return :caption
    return :unknown
end

newstate() = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(),
                              worker_secret = "x")

@testset "bt_show / ShowTool" begin

    @testset "parse_show_path" begin
        @test BT.parse_show_path("shown: /a/b/v.mp4 (video/mp4, 2.5MB)") == "/a/b/v.mp4"
        @test BT.parse_show_path("shown: .bonitoAgents/show/x.png")        == ".bonitoAgents/show/x.png"
        @test BT.parse_show_path("shown: /tmp/f.txt")                    == "/tmp/f.txt"
        @test BT.parse_show_path("shown: /a.png (image/png, 1KB)\nmore") == "/a.png"
        @test BT.parse_show_path("not a show reference")                 === nothing
        @test BT.parse_show_path("")                                     === nothing
    end

    @testset "bt_show tool handler (BonitoMCP)" begin
        @test BonitoMCP.show_mime_from_path("/x/a.mp4")  == "video/mp4"
        @test BonitoMCP.show_mime_from_path("/x/a.PNG")  == "image/png"   # case-insensitive
        @test BonitoMCP.show_mime_from_path("/x/a.weird") == "application/octet-stream"

        mktempdir() do dir
            f = joinpath(dir, "clip.mp4"); write(f, rand(UInt8, 100))
            res = BonitoMCP.julia_show_handler(Dict("path" => f))
            @test res["isError"] == false
            txt = res["content"][1]["text"]
            @test startswith(txt, "shown: $f (video/mp4, ")
            # the chat side must be able to recover the path from that text
            @test BT.parse_show_path(txt) == f

            @test BonitoMCP.julia_show_handler(Dict("path" => ""))["isError"] == true
            @test BonitoMCP.julia_show_handler(Dict("path" => joinpath(dir, "nope")))["isError"] == true
        end
    end

    @testset "fetch_show_file path resolution" begin
        state = newstate()
        cwd = mktempdir()

        # Relative path already mirrored on the server → returned as-is, no fetch.
        mkpath(joinpath(cwd, "sub"))
        write(joinpath(cwd, "sub", "a.png"), UInt8[0x89,0x50,0x4e,0x47])
        st_rel = BT.ShowTool(state, "", cwd, "sub/a.png")
        @test BT.fetch_show_file(st_rel) == joinpath(cwd, "sub", "a.png")

        # Absolute path outside any project → server-side cache location.
        cache = joinpath(cwd, ".bt-show-cache", "out.png")
        mkpath(dirname(cache)); write(cache, UInt8[1,2,3])
        st_abs = BT.ShowTool(state, "", cwd, "/somewhere/else/out.png")
        @test BT.fetch_show_file(st_abs) == cache

        # Not present and no worker to fetch from → throws (no silent empty).
        st_missing = BT.ShowTool(state, "", cwd, "sub/missing.png")
        @test_throws Exception BT.fetch_show_file(st_missing)
    end

    @testset "render_show_file element selection" begin
        state = newstate()
        cwd = mktempdir()
        write(joinpath(cwd, "a.png"), UInt8[0x89,0x50,0x4e,0x47])
        write(joinpath(cwd, "v.mp4"), rand(UInt8, 32))
        write(joinpath(cwd, "n.txt"), "hello")
        write(joinpath(cwd, "x.bin"), rand(UInt8, 8))
        kind(p) = show_kind(BT.render_show_file(BT.ShowTool(state, "", cwd, p)))
        @test kind("a.png") == :image
        @test kind("v.mp4") == :video
        @test kind("n.txt") == :text
        @test kind("x.bin") == :caption
    end

    @testset "Bonito HTTP Range support" begin
        pr = Bonito.parse_byte_range
        @test pr("bytes=0-3", 10)   == (0, 3)
        @test pr("bytes=5-", 10)    == (5, 9)
        @test pr("bytes=-3", 10)    == (7, 9)
        @test pr("", 10)            === nothing
        @test pr("bytes=20-30", 10) === nothing
        @test pr("bytes=0-3", 0)    === nothing

        mktempdir() do dir
            f = joinpath(dir, "blob"); write(f, UInt8.(1:10))
            H = Bonito.HTTP
            r200 = Bonito.serve_asset(H.Request("GET", "/f"), nothing, f, "video/mp4", "no-cache")
            @test r200.status == 200
            @test H.header(r200, "Accept-Ranges") == "bytes"
            @test length(r200.body) == 10

            r206 = Bonito.serve_asset(H.Request("GET", "/f", ["Range" => "bytes=2-5"]),
                                      nothing, f, "video/mp4", "no-cache")
            @test r206.status == 206
            @test H.header(r206, "Content-Range") == "bytes 2-5/10"
            @test r206.body == UInt8[3, 4, 5, 6]
        end
    end

    @testset "show_server_path + auto-expand flag" begin
        state = newstate()
        cwd = mktempdir()
        # relative → server mirror under cwd; absolute-outside → cache.
        @test BT.show_server_path(BT.ShowTool(state, "", cwd, "sub/x.png")) ==
              joinpath(cwd, "sub", "x.png")
        @test BT.show_server_path(BT.ShowTool(state, "", cwd, "/elsewhere/y.png")) ==
              joinpath(cwd, ".bt-show-cache", "y.png")

        # tool_header_dict flags a bt_show tool for auto-expand (its persisted
        # content carries a `shown:` ref); a normal tool gets no expand flag.
        ACP = BonitoAgents.AgentClientProtocol
        chat_dir = mktempdir()
        showtc = ACP.GenericTool("tid", "other", "bt_show", "completed",
                                  ACP.ToolContent[ACP.TextContent("shown: /x/v.mp4 (video/mp4, 1MB)")],
                                  Channel{ACP.ToolCall}(1))
        BT.persist_tool_content!(chat_dir, showtc)
        @test BT.tool_header_dict(BT.GenericToolMsg(BT.Message("tid","other","","bt_show","completed","",
                                                     0.0, 0.0, nothing)), chat_dir)["expand"] == true

        readtc = ACP.GenericTool("tid2", "read", "cat", "completed",
                                  ACP.ToolContent[ACP.TextContent("plain file contents")],
                                  Channel{ACP.ToolCall}(1))
        BT.persist_tool_content!(chat_dir, readtc)
        @test !haskey(BT.tool_header_dict(BT.GenericToolMsg(BT.Message("tid2","read","","cat","completed","",
                                                              0.0, 0.0, nothing)), chat_dir), "expand")
    end

    @testset "show_mime on the wire (native-image toggle)" begin
        # parse_show_mime: extracts the mime from the reference tail.
        @test BT.parse_show_mime("shown: /a/b.png (image/png, 34 KB)") == "image/png"
        @test BT.parse_show_mime("shown: /a/b c.png (image/png, 1.2 MB)") == "image/png"
        @test BT.parse_show_mime("shown: /x/v.mp4 (video/mp4, 1MB)") == "video/mp4"
        # Older refs without the parenthesized tail → no mime, no crash.
        @test BT.parse_show_mime("shown: /a/plain") === nothing
        @test BT.parse_show_mime("not a show ref") === nothing

        # tool_header_dict ships show_mime alongside expand for image shows.
        ACP = BonitoAgents.AgentClientProtocol
        chat_dir = mktempdir()
        imgtc = ACP.GenericTool("img1", "other", "bt_show", "completed",
                                 ACP.ToolContent[ACP.TextContent("shown: /p/plot.png (image/png, 34 KB)")],
                                 Channel{ACP.ToolCall}(1))
        BT.persist_tool_content!(chat_dir, imgtc)
        d = BT.tool_header_dict(BT.GenericToolMsg(BT.Message("img1","other","","bt_show","completed","",
                                                   0.0, 0.0, nothing)), chat_dir)
        @test d["expand"] == true
        @test d["show_mime"] == "image/png"

        # Non-show tools carry no show_mime.
        plaintc = ACP.GenericTool("p1", "read", "cat", "completed",
                                   ACP.ToolContent[ACP.TextContent("file contents")],
                                   Channel{ACP.ToolCall}(1))
        BT.persist_tool_content!(chat_dir, plaintc)
        @test !haskey(BT.tool_header_dict(BT.GenericToolMsg(BT.Message("p1","read","","cat","completed","",
                                                              0.0, 0.0, nothing)), chat_dir), "show_mime")

        # Inline image content (e.g. Read on a PNG) ships its mime too —
        # but does NOT auto-expand (that's bt_show's behavior only).
        imgread = ACP.GenericTool("r1", "read", "Read x.png", "completed",
                                   ACP.ToolContent[ACP.ImageContent("aGk=", "image/png")],
                                   Channel{ACP.ToolCall}(1))
        BT.persist_tool_content!(chat_dir, imgread)
        d2 = BT.tool_header_dict(BT.GenericToolMsg(BT.Message("r1","read","","Read x.png","completed","",
                                                    0.0, 0.0, nothing)), chat_dir)
        @test d2["show_mime"] == "image/png"
        @test !haskey(d2, "expand")

        # tool_media_mime: show ref wins over inline images; text-only → nothing.
        @test BT.tool_media_mime(Any[ACP.TextContent("shown: /a.png (image/png, 1 KB)"),
                                     ACP.ImageContent("aGk=", "image/jpeg")]) == "image/png"
        @test BT.tool_media_mime(Any[ACP.TextContent("hello")]) === nothing
    end
end

end
