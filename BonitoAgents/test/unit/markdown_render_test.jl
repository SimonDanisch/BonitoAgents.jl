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

# The preservation guard is keyed on every word surviving, which quietly made it
# a rule about MARKUP too: an ordered list's `1.` is rendered as `<ol><li>` with
# the digit drawn by a CSS counter, so it is absent from the html by design. The
# guard read that as "the render erased content" and dumped the whole message to
# escaped plain text — asterisks, backticks and all. It looked agent-dependent
# because it only bit when the digit appeared nowhere else in the message.
@testset "structure is not content: numbered lists still render" begin
    for s in ["1. alpha\n2. beta",            # the minimal case
              "1) alpha\n2) beta",            # the `)` delimiter
              "  1. nested\n  2. list",       # indented
              "1. one\n2. two\n3. three\n4. four"]
        h = BT.markdown_html(s)
        @test occursin("<ol", h)
        @test occursin("<li>", h)
        # …and the prose still survives, which is what the guard is FOR.
        for w in ["alpha", "beta", "nested", "list", "one", "two", "three", "four"]
            occursin(w, s) && @test occursin(w, h)
        end
    end
    # A link reference definition is consumed whole and emits nothing, so its
    # label must not be demanded back either.
    h = BT.markdown_html("see [1] for details\n\n[1]: https://example.com/x")
    @test occursin("<a", h) && occursin("example.com", h)

    # The guard must still FIRE on the case it exists for: a half-formed table
    # whose header row CommonMark swallows falls back to verbatim.
    bad = BT.markdown_html("| alpha | beta |\n|::|::|\n| 1 | 2 |")
    @test occursin("alpha", bad) && occursin("beta", bad)
end

@testset "markdown_html still renders well-formed markdown" begin
    @test occursin("<strong", BT.markdown_html("hello **world**"))
    @test occursin("<table", BT.markdown_html("| a | b |\n|---|---|\n| 1 | 2 |"))
    h = BT.markdown_html("plain text")
    @test occursin("plain text", h) && !occursin("<table", h)
end
end
