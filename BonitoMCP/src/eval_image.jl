# ── Eval results that are images → PNG files ────────────────────────────────
# A colour matrix returned by `bt_julia_eval` is encoded HERE, in the host,
# because this process runs in our own environment (`@bonito-agents`). The eval
# worker runs the USER's project, where PNGFiles is normally not loadable, and
# without it a Colorant matrix has no `image/png` show method at all — the old
# result was Colors' swatch SVG, one `<rect>` per pixel, which no agent can look
# at. So the worker only converts the matrix to plain 8-bit RGBA bytes (that
# needs the user's colour types) and hands them over; see `pixel_block` in
# helper_payload.jl. Raw bytes rather than the matrix itself: Malt deserialises
# with THIS process's ColorTypes, which need not be the version the worker has.

# The block type the worker uses for "encode these pixels". It never leaves this
# process: `materialize_images` replaces it with the `shown:` reference.
const PIXEL_BLOCK = "bt_pixels"

# Encode one pixel block to the PNG file it names and return the `shown:`
# reference, in the same shape `bt_show` produces (absolute path, mime, size)
# plus the value's type on a second line.
function write_eval_image(b::AbstractDict)
    w = Int(b["width"])
    h = Int(b["height"])
    rgba = reinterpret(RGBA{N0f8}, Vector{UInt8}(b["pixels"]))
    # The worker writes rows one after another, x fastest: that is a
    # column-major (width, height) array, and an image is indexed [row, column].
    img = permutedims(reshape(rgba, w, h))
    path = String(b["path"])
    mkpath(dirname(path))
    # Colour type 2 when nothing is transparent: a fourth channel of 255s is a
    # quarter of the pixel data for nothing.
    PNGFiles.save(path, Bool(b["opaque"]) ? color.(img) : img)
    text = "shown: $path (image/png, $(bt_show_format_bytes(filesize(path))))\n" *
           "type: $(b["typeof"])"
    return Dict{String,Any}("type" => "text", "text" => text)
end

"""
    materialize_images(blocks) -> Vector{Dict{String,Any}}

The worker's value blocks, with every pixel block encoded to its PNG file and
replaced by the `shown:` reference the agent and the chat read.
"""
materialize_images(blocks::AbstractVector) =
    Dict{String,Any}[get(b, "type", "") == PIXEL_BLOCK ? write_eval_image(b) : b
                     for b in blocks]
