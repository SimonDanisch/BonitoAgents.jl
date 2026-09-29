# Textured models for the 3D preview's tests: one square facing +Z, covered by a
# solid-colour PNG texture, and nothing else (no vertex colour), so the colour of
# the rendered square says whether the texture arrived. Written as a
# self-contained .glb, as a .gltf naming its .bin and .png siblings, and as an
# OBJ whose .mtl names a texture in another folder.
#
# Plain functions (no module): `include` it where needed.

using JSON

# A minimal PNG encoder: RGBA, 8 bits, one "stored" (uncompressed) deflate block.
function crc32_png(bytes::AbstractVector{UInt8})
    crc = 0xffffffff
    for b in bytes
        crc ⊻= UInt32(b)
        for _ in 1:8
            crc = (crc & 1) == 1 ? (crc >> 1) ⊻ 0xedb88320 : crc >> 1
        end
    end
    return ~crc
end

function png_bytes(w::Int, h::Int, rgba::NTuple{4,UInt8})
    raw = UInt8[]
    for _ in 1:h
        push!(raw, 0x00)                                   # filter: none
        for _ in 1:w; append!(raw, rgba); end
    end
    length(raw) <= 0xffff || error("png_bytes: one stored block holds 65535 bytes")
    a, b = UInt32(1), UInt32(0)
    for x in raw; a = (a + x) % 65521; b = (b + a) % 65521; end
    n = UInt16(length(raw))
    zlib = UInt8[0x78, 0x01, 0x01, n & 0xff, n >> 8, ~n & 0xff, (~n) >> 8]
    append!(zlib, raw)
    append!(zlib, reinterpret(UInt8, [hton(UInt32((b << 16) | a))]))   # (`% 65521` made them Int)
    chunk(kind, data) = (body = vcat(Vector{UInt8}(codeunits(kind)), data);
                         vcat(reinterpret(UInt8, [hton(UInt32(length(data)))]), body,
                              reinterpret(UInt8, [hton(crc32_png(body))])))
    ihdr = vcat(reinterpret(UInt8, [hton(UInt32(w)), hton(UInt32(h))]), UInt8[8, 6, 0, 0, 0])
    return vcat(UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
                chunk("IHDR", ihdr), chunk("IDAT", zlib), chunk("IEND", UInt8[]))
end

# The square: positions, normals, uvs and indices, back to back (all 4-aligned).
function textured_quad_geometry()
    positions = Float32[-1, -1, 0,  1, -1, 0,  1, 1, 0,  -1, 1, 0]
    normals   = Float32[0, 0, 1,  0, 0, 1,  0, 0, 1,  0, 0, 1]
    uvs       = Float32[0, 1,  1, 1,  1, 0,  0, 0]
    indices   = UInt16[0, 1, 2,  0, 2, 3]
    bin = vcat(reinterpret(UInt8, positions), reinterpret(UInt8, normals), reinterpret(UInt8, uvs),
               reinterpret(UInt8, indices))
    views = [(0, 48), (48, 48), (96, 32), (128, 12)]
    return bin, views
end

# The glTF JSON; `image` is the images[1] entry (a uri, or a buffer view).
function textured_quad_json(bin_length::Int, views, image::AbstractDict; buffer_uri = nothing)
    buffer = Dict{String,Any}("byteLength" => bin_length)
    buffer_uri === nothing || (buffer["uri"] = buffer_uri)
    return Dict{String,Any}(
        "asset" => Dict("version" => "2.0"),
        "scene" => 0, "scenes" => [Dict("nodes" => [0])], "nodes" => [Dict("mesh" => 0)],
        "meshes" => [Dict("primitives" => [Dict(
            "attributes" => Dict("POSITION" => 0, "NORMAL" => 1, "TEXCOORD_0" => 2),
            "indices" => 3, "material" => 0)])],
        "materials" => [Dict("pbrMetallicRoughness" => Dict(
            "baseColorTexture" => Dict("index" => 0), "metallicFactor" => 0.0, "roughnessFactor" => 1.0))],
        "textures" => [Dict("source" => 0, "sampler" => 0)],
        "samplers" => [Dict("magFilter" => 9728, "minFilter" => 9728)],
        "images" => [image],
        "buffers" => [buffer],
        "bufferViews" => [Dict("buffer" => 0, "byteOffset" => o, "byteLength" => l) for (o, l) in views],
        "accessors" => [
            Dict("bufferView" => 0, "componentType" => 5126, "count" => 4, "type" => "VEC3",
                 "min" => [-1, -1, 0], "max" => [1, 1, 0]),
            Dict("bufferView" => 1, "componentType" => 5126, "count" => 4, "type" => "VEC3"),
            Dict("bufferView" => 2, "componentType" => 5126, "count" => 4, "type" => "VEC2"),
            Dict("bufferView" => 3, "componentType" => 5123, "count" => 6, "type" => "SCALAR")])
end

"The textured square as ONE self-contained .glb at `path` (the texture in its binary chunk)."
function write_textured_glb(path::AbstractString; rgba::NTuple{4,UInt8} = (0xff, 0x00, 0x00, 0xff))
    geo, views = textured_quad_geometry()
    png = png_bytes(4, 4, rgba)
    while length(geo) % 4 != 0; push!(geo, 0x00); end
    image_view = (length(geo), length(png))
    bin = vcat(geo, png)
    while length(bin) % 4 != 0; push!(bin, 0x00); end
    gltf = textured_quad_json(length(bin), vcat(views, [image_view]),
                              Dict{String,Any}("bufferView" => 4, "mimeType" => "image/png"))
    json = Vector{UInt8}(codeunits(JSON.json(gltf)))
    while length(json) % 4 != 0; push!(json, 0x20); end
    open(path, "w") do io
        write(io, "glTF", UInt32(2), UInt32(12 + 8 + length(json) + 8 + length(bin)))
        write(io, UInt32(length(json)), UInt32(0x4E4F534A), json)
        write(io, UInt32(length(bin)), UInt32(0x004E4942), bin)
    end
    return path
end

"The textured square as `quad.gltf` in `dir`, naming `quad.bin` and `color.png` next to it."
function write_textured_gltf(dir::AbstractString; rgba::NTuple{4,UInt8} = (0xff, 0x00, 0x00, 0xff))
    geo, views = textured_quad_geometry()
    write(joinpath(dir, "quad.bin"), geo)
    write(joinpath(dir, "color.png"), png_bytes(4, 4, rgba))
    gltf = textured_quad_json(length(geo), views, Dict{String,Any}("uri" => "color.png"); buffer_uri = "quad.bin")
    write(joinpath(dir, "quad.gltf"), JSON.json(gltf))
    return joinpath(dir, "quad.gltf")
end

"""
The textured square as `models/quad.obj` in `dir`, with `models/quad.mtl` naming
`../textures/color.png`: the materials and a texture reached through `..`.
"""
function write_textured_obj(dir::AbstractString; rgba::NTuple{4,UInt8} = (0xff, 0x00, 0x00, 0xff))
    models, textures = mkpath(joinpath(dir, "models")), mkpath(joinpath(dir, "textures"))
    write(joinpath(textures, "color.png"), png_bytes(4, 4, rgba))
    write(joinpath(models, "quad.mtl"), "newmtl painted\nKd 1 1 1\nmap_Kd ../textures/color.png\n")
    write(joinpath(models, "quad.obj"), """
        mtllib quad.mtl
        v -1 -1 0
        v 1 -1 0
        v 1 1 0
        v -1 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        usemtl painted
        f 1/1/1 2/2/1 3/3/1 4/4/1
        """)
    return joinpath(models, "quad.obj")
end
