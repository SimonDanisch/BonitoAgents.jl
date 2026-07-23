# Headless unit test for the agent-facing eval summary renderer
# (`RemoteProxy.summary_html`): a returned display value's DOM, rendered to
# compact HTML for the AGENT — with NO base64/binary inlined (that would balloon
# the agent's context by megabytes), and a render-time error surfaced as a
# `CapturedException` (a VALUE), never swallowed.
#
# `RemoteProxy` is the standalone module the eval worker `include`s (it's
# deliberately NOT part of the BonitoMCP package — see BonitoMCP.jl — because it
# references `Bonito.*` types). We load it here the SAME way and call the pure
# renderer directly: `summary_html` renders on a throwaway `NoConnection`
# session, so it needs no bridge, worker, or server.
#
# This guards two contracts the full-stack e2e can't see (the descriptor `repr`
# never reaches the DOM): the no-base64 property, and that an App value's render
# error becomes a CapturedException (the double-wrap bug where `App(App(...))`
# routed the inner error through `handle_render_error` and it was lost).
@testitem "unit:summary_html" tags = [:unit] begin
    import Bonito
    import BonitoMCP
    include(BonitoMCP.remote_proxy_path())     # defines `RemoteProxy`, as in the worker
    using Test
    const RP = RemoteProxy

    bin_img() = Bonito.BinaryAsset(rand(UInt8, 4096), "image/png")

    @testset "display value → compact, assetless HTML" begin
        # A returned App containing an image: its DOM is rendered, but the image
        # is a SHORT stub, never a base64 `data:` URL that would flood the agent.
        app = Bonito.App(() -> Bonito.DOM.div(
            Bonito.DOM.img(src = bin_img()), Bonito.DOM.span("SUMMARK_ok")))
        html = RP.summary_html(app)
        @test html isa String
        @test occursin("SUMMARK_ok", html)          # the DOM structure is present
        @test !occursin("base64", html)             # NO inlined bytes
        @test !occursin("data:", html)
        @test occursin("[binary:", html)            # the asset is a short stub marker
        # A 4 KB image alone would be >5 KB of base64; the whole fragment stays tiny.
        @test length(html) < 2000
    end

    @testset "render-time error → CapturedException (a value, not swallowed)" begin
        # Regression: when the value IS an App, `display_app` must NOT re-wrap it
        # as `App(App(...))` — that routes the inner error through Bonito's
        # `handle_render_error` (→ error-HTML) before summary_html's catch sees it,
        # so the error would silently become a "successful" HTML string.
        bad = Bonito.App(() -> (error("SUMMARK_BOOM"); Bonito.DOM.div("never")))
        r = RP.summary_html(bad)
        @test r isa CapturedException
        @test occursin("SUMMARK_BOOM", sprint(showerror, r))
    end

    @testset "plain DOM value renders compactly" begin
        r = RP.summary_html(Bonito.App(() -> Bonito.DOM.div("PLAINMARK_z")))
        @test r isa String
        @test occursin("PLAINMARK_z", r)
        @test !occursin("base64", r)
    end
end
