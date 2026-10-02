# `markdown_html` renders chat message text through CommonMark on every streamed
# chunk, so it is routinely handed half-formed markdown. The guarantee it owes
# the user is simple and absolute: RENDERING MUST NOT LOSE TEXT. A message that
# renders unstyled is a nuisance; a message that renders with sentences missing
# is a lie.
#
# The thing that breaks it is `CommonMark.TableRule`, which deletes text.
# `gfm_table` does
#
#     finalize_literal!(container)     # empties the paragraph
#     header = container.literal       # takes its text
#     … only THEN validates the spec
#
# so every line of a paragraph before the last `|`-leading line is dropped, with
# no error — verified against CommonMark 1.0.4:
#
#     "x\n| a |\n| b |"  →  <p>| b |</p>
#
# `defuse_table_rule` escapes the leading `|` of any line that is not part of a
# valid table, so the rule never fires on prose. These tests pin the guarantee,
# not the mechanism: whatever we do, the words have to come out the other side.
@testitem "unit:markdown_render" tags = [:unit] begin

using Test
import BonitoAgents
const BT = BonitoAgents

# Every word of `src` must survive into the rendered html.
function keeps(src, words)
    h = BT.markdown_html(src)
    all(w -> occursin(w, h), words) || return false
    # …and our escaping must never leak into what the user sees.
    return !occursin("\\|", h) && !occursin("\\1", h)
end

@testset "CommonMark's table rule must not eat prose" begin
    # Each of these loses text through a bare CommonMark 1.0.4 parse.
    @test keeps("x\n| a |\n| b |", ["x", "a", "b"])
    @test keeps("| a |\n| b |\n| c |", ["a", "b", "c"])
    @test keeps("| alpha | beta |\n| 1 | 2 |", ["alpha", "beta", "1", "2"])
    # A table mid-stream, on its way to `|---|` — the common case, since the
    # message is re-rendered per chunk.
    @test keeps("alpha | beta\n|-", ["alpha", "beta"])
    @test keeps("alpha | beta\n| |", ["alpha", "beta"])
    @test keeps("alpha | beta\n|::|", ["alpha", "beta"])
    @test keeps("| alpha | beta |\n|::|::|\n| 1 | 2 |", ["alpha", "beta", "1", "2"])
end

@testset "a real table still renders as a table" begin
    h = BT.markdown_html("| a | b |\n|---|---|\n| 1 | 2 |")
    @test occursin("<table", h)
    for w in ["a", "b", "1", "2"]; @test occursin(w, h); end
    # Alignment specs are specs too.
    @test occursin("<table", BT.markdown_html("| a | b |\n|:--|--:|\n| 1 | 2 |"))
end

@testset "code keeps its pipes, unescaped" begin
    fenced = BT.markdown_html("```\n| a |\n| b |\n```")
    @test occursin("<code>", fenced) && occursin("| a |", fenced)
    indented = BT.markdown_html("    | a | b |")
    @test occursin("<code>", indented) && occursin("| a | b |", indented)
end

# Structure is not content. An ordered list's `1.` becomes `<ol><li>` with the
# digit drawn by a CSS counter, so it is absent from the html by design — the
# previous guard read that as erased content and dumped whole messages to
# escaped plain text, which is how a numbered list broke every message carrying
# one.
@testset "ordinary markdown renders as markdown" begin
    for s in ["1. alpha\n2. beta", "1) alpha\n2) beta", "  1. nested\n  2. list"]
        h = BT.markdown_html(s)
        @test occursin("<ol", h) && occursin("<li>", h)
        @test occursin("alpha", h) || occursin("nested", h)
    end
    @test occursin("<ul", BT.markdown_html("- alpha\n- beta"))
    @test occursin("<strong", BT.markdown_html("hello **world**"))
    @test occursin("<h1", BT.markdown_html("# heading"))
    @test occursin("<code", BT.markdown_html("`code span`"))
    @test occursin("<a", BT.markdown_html("see [x](https://example.com)"))
    # These render to no text at all, by design, and must keep doing so.
    @test occursin("<hr", BT.markdown_html("---"))
    @test occursin("<hr", BT.markdown_html("***"))
end

# The defusing is a workaround for an upstream bug; when CommonMark validates
# the spec before gutting the paragraph, it can go. Until then it must be a
# no-op for anything that cannot trigger the rule, so it never costs a message
# that has no leading pipe anything.
@testset "defuse_table_rule only touches what it must" begin
    for s in ["hello world", "- a\n- b", "a | b\nc | d", "# x", ""]
        @test BT.defuse_table_rule(s) === s      # identity, not just equal
    end
    @test BT.defuse_table_rule("x\n| a |") == "x\n\\| a |"
    # Indentation in front of the pipe is preserved.
    @test BT.defuse_table_rule("x\n  | a |") == "x\n  \\| a |"
    # A valid table is left exactly as it was.
    tbl = "| a | b |\n|---|---|\n| 1 | 2 |"
    @test BT.defuse_table_rule(tbl) === tbl
end
end

# A markdown FILE's pictures and clips are relative to the file; shown in the
# dashboard they must point at that file on the worker, or the browser resolves
# them against the dashboard's URL and they break. `markdown_html(text, link)`
# hands every relative source to `link` and leaves the rest alone.
@testitem "unit:markdown_file_links" tags = [:unit] begin
    import BonitoAgents as BT
    using Test

    link(path) = startswith(path, "..") ? nothing : "/w/" * path
    html = BT.markdown_html("""
        ![plot](figs/plot.png) ![remote](https://example.com/a.png) ![abs](/etc/a.png)
        ![data](data:image/png;base64,AAAA) ![out](../secret.png) [a link](notes.md)

        ![clip](clips/run.mp4)

        <img src="figs/raw.png" alt="raw"> <video src="v.webm"></video> <img src="#top">
        """, link)
    @test occursin("src=\"/w/figs/plot.png\"", html)
    @test occursin("src=\"https://example.com/a.png\"", html)     # absolute: as written
    @test occursin("src=\"/etc/a.png\"", html)
    @test occursin("src=\"data:image/png;base64,AAAA\"", html)
    @test occursin("src=\"../secret.png\"", html)                 # refused by `link`
    @test occursin("href=\"notes.md\"", html)                     # a link is not a picture
    # A clip written as an image is a video.
    @test occursin("<video controls preload=\"metadata\" src=\"/w/clips/run.mp4\"", html)
    @test occursin("<img src=\"/w/figs/raw.png\" alt=\"raw\">", html)
    @test occursin("<video src=\"/w/v.webm\">", html)
    @test occursin("<img src=\"#top\">", html)
    # What `link` is handed: the path, unescaped, without query or fragment.
    @test BT.relative_reference("figs/a%20b.png?v=2#x") == "figs/a b.png"
    @test BT.relative_reference("https://x/a.png") === nothing
    @test BT.relative_reference("/abs.png") === nothing
    @test BT.relative_reference("#top") === nothing
    # Without a file, a message renders as before.
    @test !occursin("/w/", BT.markdown_html("![plot](figs/plot.png)"))
end
