@testitem "unit:markdown_render" tags = [:unit] begin

# `markdown_html` renders chat message text through CommonMark on every streamed
# chunk, so it is routinely handed half-formed markdown. It must NEVER throw —
# a parser exception there takes down the whole message render (and floods the
# server log), which is exactly what happened in production.
#
# The offender is CommonMark's GFM table rule: a separator row that starts with
# `|` and is all `|-: ` passes its permissive `valid_table_spec`, but
# `parse_table_spec` (which needs `|dashes|`) yields an EMPTY column spec, so its
# `inline_modifier` indexes `spec[0]` → BoundsError. A streamed table hits that
# on its way to `|---|` (separator arrives as `|`, `|-`, `| |`, …).
#
# `markdown_html` catches ONLY that BoundsError and shows the text verbatim. We
# deliberately do NOT "fix" it by tightening `valid_table_spec`: CommonMark
# consumes the header paragraph before it bails on an invalid spec, so that would
# silently DROP the header line. The verbatim fallback keeps all the text; the
# next streamed chunk re-renders the finished table cleanly.

using Test
import BonitoAgents
const BT = BonitoAgents

@testset "markdown_html never throws on half-formed table markdown" begin
    # Each forms a zero-column CommonMark Table and used to throw
    # `BoundsError: 0-element Vector{Symbol} at index [0]`.
    crashers = [
        "alpha | beta\n|-",                # streamed separator, mid-flight
        "alpha | beta\n| |",
        "alpha | beta\n|::|",
        "| alpha | beta |\n|::|::|\n| 1 | 2 |",
    ]
    for s in crashers
        local html
        @test (html = BT.markdown_html(s); true)             # no throw
        @test startswith(html, "<div class=\"markdown-body\">")
        @test occursin("alpha", html) && occursin("beta", html)  # content preserved
    end
end

@testset "a render that would erase the message falls back to verbatim" begin
    # The content-preservation guarantee above cannot rest on WHICH exception
    # CommonMark throws. Our pinned version raises a BoundsError on a
    # half-formed table; the newer fork CI resolves to returns successfully with
    # a zero-column <table> and no cells, so the message rendered BLANK and only
    # CI saw it. The guard therefore checks the OUTPUT.
    #
    # It is keyed on words surviving, not on the output having any text at all —
    # these render to nothing by design and must keep doing so.
    @test occursin("<hr", BT.markdown_html("---"))
    @test occursin("<hr", BT.markdown_html("***"))
    # ... while anything carrying words keeps them, however it is parsed.
    for s in ["alpha | beta\n|-", "| alpha | beta |\n|::|::|\n| 1 | 2 |",
              "# heading", "- item one\n- item two", "`code span`"]
        h = BT.markdown_html(s)
        for w in ["alpha", "beta", "heading", "item", "one", "two", "code", "span"]
            occursin(w, s) && @test occursin(w, h)
        end
    end
end

@testset "markdown_html still renders well-formed markdown" begin
    @test occursin("<strong", BT.markdown_html("hello **world**"))
    @test occursin("<table", BT.markdown_html("| a | b |\n|---|---|\n| 1 | 2 |"))
    h = BT.markdown_html("plain text")
    @test occursin("plain text", h) && !occursin("<table", h)
end
end
