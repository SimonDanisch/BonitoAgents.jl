# A `Matrix{RGB}` returned from `bt_julia_eval` used to reach the agent as a
# 155KB SVG it could not look at: the eval worker runs the USER's project, where
# nothing gives a colour matrix an `image/png` show method, so Colors' swatch SVG
# (one `<rect>` per pixel) won, and `summary_html` inlined it on the bridge path.
#
# The job is now split across the two processes that exist anyway:
#   * the eval worker (user's env) converts the matrix to 8-bit RGBA bytes —
#     `pixel_block`, the only part that needs the user's colour types;
#   * the BonitoMCP host (our env) encodes them with PNGFiles —
#     `materialize_images`, which replaces the pixel block with the `shown:`
#     reference the agent and the chat read.
# The bridge-path routing is covered end to end by `e2e:bt_eval_types`.
@testitem "unit:eval_png" tags = [:unit] begin
    using BonitoAgents, BonitoMCP, Bonito
    include(BonitoMCP.helper_payload_path())
    H = BonitoMCPHelper
    C = Bonito.Colors
    N0f8 = C.N0f8
    PNG = BonitoMCP.PNGFiles

    # Worker half → host half → decoded by PNGFiles, the way a real eval goes.
    function roundtrip(img, dir)
        b = H.pixel_block(img, dir)
        @test b !== nothing
        shown = only(BonitoMCP.materialize_images([b]))
        return b, shown, PNG.load(b["path"])
    end

    @testset "a colour matrix is recognised by TYPE, not by name" begin
        @test H.looks_like_image([C.RGB(1, 0, 0) for _ in 1:2, _ in 1:2])
        @test H.looks_like_image([C.Gray(0.5) for _ in 1:2, _ in 1:2])
        @test H.looks_like_image([C.RGBA(1, 0, 0, 0.5) for _ in 1:2, _ in 1:2])
        # The old rule matched the eltype's printed NAME, so every other
        # colorspace fell through to the SVG blob.
        @test H.looks_like_image([C.HSV(200, 1, 1) for _ in 1:2, _ in 1:2])
        @test H.looks_like_image([C.Lab(50, 20, -30) for _ in 1:2, _ in 1:2])
        # ...and a name is not a colour.
        @test !H.looks_like_image([1.0 2.0; 3.0 4.0])
        @test !H.looks_like_image([C.RGB(1, 0, 0), C.RGB(0, 1, 0)])   # 1-D
        @test !H.looks_like_image(["RGB" "Gray"; "x" "y"])
        @test !H.looks_like_image(nothing)
    end

    @testset "the worker hands over row-major RGBA bytes" begin
        img = [C.RGB{Float64}(1, 0, 0) C.RGB{Float64}(0, 1, 0)
               C.RGB{Float64}(0, 0, 1) C.RGB{Float64}(0, 0, 0)]
        mktempdir() do dir
            b = H.pixel_block(img, dir)
            @test b["type"] == BonitoMCP.PIXEL_BLOCK
            @test (b["width"], b["height"]) == (2, 2)   # [row, column] ⇒ dim 1 is the height
            @test b["opaque"] == true
            # Row 1 left to right, then row 2 — RGBA per pixel.
            @test b["pixels"] == UInt8[255, 0, 0, 255,   0, 255, 0, 255,
                                       0, 0, 255, 255,   0, 0, 0, 255]
            @test isabspath(b["path"]) && endswith(b["path"], ".png")
            @test !isfile(b["path"])        # the worker writes nothing itself
        end
    end

    @testset "the host encodes with PNGFiles and emits the `shown:` reference" begin
        img = [C.RGB{N0f8}(i / 60, j / 60, 0.2) for i in 1:60, j in 1:60]
        mktempdir() do dir
            b, shown, back = roundtrip(img, dir)
            @test back == img                             # exact for 8-bit input
            @test eltype(back) <: C.RGB                   # opaque ⇒ colour type 2
            @test shown["type"] == "text"
            @test startswith(shown["text"], "shown: $(b["path"]) (image/png, ")
            @test endswith(shown["text"], "\ntype: Array")
        end
    end

    @testset "transparency survives" begin
        img = [C.RGBA{N0f8}(1, 0, 0, 1) C.RGBA{N0f8}(0, 0, 1, 0)]
        mktempdir() do dir
            b, _, back = roundtrip(img, dir)
            @test b["opaque"] == false
            @test eltype(back) <: C.RGBA
            @test back == img
        end
    end

    @testset "every colorspace converts; out-of-gamut clamps instead of throwing" begin
        mktempdir() do dir
            _, _, gray = roundtrip(reshape([C.Gray(0.0), C.Gray(1.0)], 2, 1), dir)
            @test gray == reshape([C.RGB{N0f8}(0, 0, 0), C.RGB{N0f8}(1, 1, 1)], 2, 1)
            _, _, hsv = roundtrip(reshape([C.HSV(120, 1, 1)], 1, 1), dir)
            @test hsv[1] == C.RGB{N0f8}(0, 1, 0)
            # An HDR render is still worth looking at, and `N0f8(2.5)` would throw.
            _, _, hdr = roundtrip(reshape([C.RGB(2.5, -1.0, NaN)], 1, 1), dir)
            @test hdr[1] == C.RGB{N0f8}(1, 0, 0)
        end
    end

    @testset "a smooth image compresses (the point of a real encoder)" begin
        img = [C.RGB{Float64}(i / 400, j / 400, 0.5) for i in 1:400, j in 1:400]
        mktempdir() do dir
            b, _, _ = roundtrip(img, dir)
            # Uncompressed it is 400·400·3 = 480KB; a gradient deflates to a
            # tiny fraction of that.
            @test filesize(b["path"]) < 50_000
        end
    end

    @testset "empty and oversized images are not shipped" begin
        mktempdir() do dir
            @test H.pixel_block(Matrix{C.RGB{Float64}}(undef, 0, 3), dir) === nothing
        end
    end

    @testset "try_save_rich routes a colour matrix to the host, never to SVG" begin
        img = [C.RGB{Float64}(i / 60, j / 60, 0.2) for i in 1:60, j in 1:60]
        mktempdir() do dir
            b = H.try_save_rich(img, dir, 10_000)
            @test b["type"] == BonitoMCP.PIXEL_BLOCK
            @test isempty(filter(f -> endswith(f, ".svg"), readdir(dir)))
        end
        # Blocks that are not pixels pass through the host untouched.
        text = Dict{String,Any}("type" => "text", "text" => "hello")
        @test BonitoMCP.materialize_images([text]) == [text]
    end
end
