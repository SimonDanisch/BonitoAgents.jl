# ── 3D geometry preview: parse here, draw there ─────────────────────────────
# The file viewer previews .obj / .stl / .ply / .off / .glb / .gltf. Every one of
# those formats is parsed HERE, in Julia, down to one triangle soup, and the
# browser gets a single fixed-layout binary blob (see `write_mesh_blob`) that
# assets/meshview.js draws. Two reasons for the split:
#
#   • the format zoo is where the bugs live (binary STL vs ASCII STL, PLY
#     property orders, glTF accessor strides, node transforms) and it's testable
#     headlessly here — a JS parser would only ever be testable through a browser.
#   • the browser side stays a renderer, small enough to read in one sitting.
#
# Scope is deliberately GEOMETRY: positions, triangles, and smooth normals. No
# materials, textures, animations, or skins — this is "what shape is this file",
# which is the question a file preview answers. Formats we can't read produce a
# clear error the viewer shows, never a blank canvas.

# Everything the browser needs to draw a mesh. Positions/normals are xyz-major
# (3 per vertex); `indices` is 0-BASED triangle corners (the WebGL convention),
# not Julia's 1-based — the conversion happens once, at construction.
struct MeshData
    positions :: Vector{Float32}
    normals   :: Vector{Float32}
    indices   :: Vector{UInt32}
end

nvertices(m::MeshData) = length(m.positions) ÷ 3
ntriangles(m::MeshData) = length(m.indices) ÷ 3

# A mesh past this is a GPU/memory hazard in a preview pane (and a browser tab
# is not a DCC tool). Refusing loudly beats a locked-up window.
const MESH_MAX_TRIANGLES = 4_000_000

"""
    MeshParseError(msg)

A geometry file we could not turn into triangles: unsupported variant, malformed
content, or past [`MESH_MAX_TRIANGLES`](@ref). Carries a message meant for the
user, not a stack trace — the viewer renders `msg` in place of the canvas.
"""
struct MeshParseError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MeshParseError) = print(io, e.msg)

# Area-weighted smooth vertex normals. Area weighting (i.e. NOT normalising the
# face normal before accumulating) is what keeps a mesh with wildly uneven
# triangle sizes — every decimated scan, most CAD tessellations — from having its
# shading dominated by slivers.
function vertex_normals(positions::Vector{Float32}, indices::Vector{UInt32})
    normals = zeros(Float32, length(positions))
    for t in 1:3:length(indices)
        a, b, c = Int(indices[t]) * 3, Int(indices[t+1]) * 3, Int(indices[t+2]) * 3
        ux = positions[b+1] - positions[a+1]; uy = positions[b+2] - positions[a+2]; uz = positions[b+3] - positions[a+3]
        vx = positions[c+1] - positions[a+1]; vy = positions[c+2] - positions[a+2]; vz = positions[c+3] - positions[a+3]
        nx = uy * vz - uz * vy
        ny = uz * vx - ux * vz
        nz = ux * vy - uy * vx
        for base in (a, b, c)
            normals[base+1] += nx; normals[base+2] += ny; normals[base+3] += nz
        end
    end
    for i in 1:3:length(normals)
        len = sqrt(normals[i]^2 + normals[i+1]^2 + normals[i+2]^2)
        if len > 0
            normals[i] /= len; normals[i+1] /= len; normals[i+2] /= len
        else
            normals[i+2] = 1f0     # degenerate/isolated vertex: any unit normal
        end
    end
    return normals
end

function MeshData(positions::Vector{Float32}, indices::Vector{UInt32})
    length(indices) ÷ 3 <= MESH_MAX_TRIANGLES ||
        throw(MeshParseError("mesh has $(length(indices) ÷ 3) triangles — too large to preview " *
                             "(limit $(MESH_MAX_TRIANGLES))"))
    isempty(indices) && throw(MeshParseError("no triangles found in this file"))
    return MeshData(positions, vertex_normals(positions, indices), indices)
end

# Fan-triangulate one polygon given as 0-based vertex indices. Convex-assuming,
# which is what every other quick previewer does; concave n-gons (rare outside
# hand-authored OBJ) can show a spurious sliver rather than fail.
function push_polygon!(indices::Vector{UInt32}, corners::AbstractVector{<:Integer})
    length(corners) < 3 && return indices
    for k in 2:(length(corners) - 1)
        push!(indices, UInt32(corners[1]), UInt32(corners[k]), UInt32(corners[k+1]))
    end
    return indices
end

# ── Wavefront OBJ ───────────────────────────────────────────────────────────
# `v` lines build the vertex pool; `f` lines index it. Indices are 1-based and
# may be NEGATIVE (relative to the pool's current end). `v/vt/vn` triplets are
# split on '/' and only the position slot is read.
function parse_obj(io::IO)
    positions = Float32[]
    indices   = UInt32[]
    corners   = Int[]
    for line in eachline(io)
        # `startswith(line, "v ")` would miss tab-separated writers; strip first.
        s = strip(line)
        (isempty(s) || s[1] == '#') && continue
        if startswith(s, "v ") || startswith(s, "v\t")
            f = split(s)
            length(f) >= 4 ||
                throw(MeshParseError("OBJ: vertex line with fewer than 3 coordinates: $(s)"))
            push!(positions, parse(Float32, f[2]), parse(Float32, f[3]), parse(Float32, f[4]))
        elseif startswith(s, "f ") || startswith(s, "f\t")
            empty!(corners)
            nverts = length(positions) ÷ 3
            for tok in Iterators.drop(eachsplit(s), 1)
                isempty(tok) && continue
                slot = first(eachsplit(tok, '/'))
                isempty(slot) && continue
                i = parse(Int, slot)
                # OBJ is 1-based with negative-relative addressing; we emit 0-based.
                idx = i > 0 ? i - 1 : nverts + i
                (0 <= idx < nverts) ||
                    throw(MeshParseError("OBJ: face references vertex $(i) but only $(nverts) are defined"))
                push!(corners, idx)
            end
            push_polygon!(indices, corners)
        end
    end
    return MeshData(positions, indices)
end

# ── STL ─────────────────────────────────────────────────────────────────────
# Binary STL is a fixed record layout with NO magic number: the header is 80
# arbitrary bytes, which famously can start with the word "solid" (some
# exporters write exactly that). The only reliable discriminator is the size
# arithmetic — 84 + 50·ntriangles — so that's what we test, and the ASCII path is
# the fallback.
function stl_is_binary(bytes::Vector{UInt8})
    length(bytes) < 84 && return false
    ntri = reinterpret(UInt32, view(bytes, 81:84))[1]
    return length(bytes) == 84 + 50 * Int(ntri)
end

function parse_stl_binary(bytes::Vector{UInt8})
    ntri = Int(reinterpret(UInt32, view(bytes, 81:84))[1])
    positions = Vector{Float32}(undef, 9 * ntri)
    indices   = Vector{UInt32}(undef, 3 * ntri)
    for t in 0:(ntri - 1)
        # 50-byte record: normal (3 f32, ignored — we recompute), 3 vertices
        # (3 f32 each), then a 2-byte attribute count.
        off = 84 + 50 * t + 12
        for v in 0:2
            src = off + 12 * v
            for c in 0:2
                positions[9t + 3v + c + 1] =
                    reinterpret(Float32, view(bytes, (src + 4c + 1):(src + 4c + 4)))[1]
            end
        end
        indices[3t + 1] = UInt32(3t)
        indices[3t + 2] = UInt32(3t + 1)
        indices[3t + 3] = UInt32(3t + 2)
    end
    return MeshData(positions, indices)
end

function parse_stl_ascii(io::IO)
    positions = Float32[]
    indices   = UInt32[]
    for line in eachline(io)
        s = strip(line)
        startswith(s, "vertex") || continue
        f = split(s)
        length(f) >= 4 || throw(MeshParseError("STL: malformed vertex line: $(s)"))
        push!(positions, parse(Float32, f[2]), parse(Float32, f[3]), parse(Float32, f[4]))
    end
    n = length(positions) ÷ 3
    n % 3 == 0 || throw(MeshParseError("STL: $(n) vertices is not a whole number of triangles"))
    append!(indices, UInt32.(0:(n - 1)))
    return MeshData(positions, indices)
end

parse_stl(bytes::Vector{UInt8}) =
    stl_is_binary(bytes) ? parse_stl_binary(bytes) : parse_stl_ascii(IOBuffer(bytes))

# ── PLY ─────────────────────────────────────────────────────────────────────
# ASCII and both binary byte orders. The header declares elements in order, each
# with typed properties; we read every element in sequence (skipping the ones we
# don't care about, which is why the non-vertex/face properties still have to be
# SIZED correctly) and pick x/y/z off `vertex` and the index list off `face`.

const PLY_TYPE_SIZES = Dict(
    "char" => 1, "int8" => 1, "uchar" => 1, "uint8" => 1,
    "short" => 2, "int16" => 2, "ushort" => 2, "uint16" => 2,
    "int" => 4, "int32" => 4, "uint" => 4, "uint32" => 4,
    "float" => 4, "float32" => 4, "double" => 8, "float64" => 8)

ply_is_float(t) = t in ("float", "float32", "double", "float64")
ply_is_signed(t) = t in ("char", "int8", "short", "int16", "int", "int32")

# One scalar of declared PLY type `t` from `bytes` at 1-based `pos`.
function ply_read_scalar(bytes::Vector{UInt8}, pos::Int, t::AbstractString, swap::Bool)
    sz = get(PLY_TYPE_SIZES, t, 0)
    sz == 0 && throw(MeshParseError("PLY: unknown property type '$(t)'"))
    pos + sz - 1 <= length(bytes) || throw(MeshParseError("PLY: file ends mid-element"))
    raw = bytes[pos:(pos + sz - 1)]
    swap && reverse!(raw)
    val = if ply_is_float(t)
        sz == 4 ? Float64(reinterpret(Float32, raw)[1]) : reinterpret(Float64, raw)[1]
    elseif ply_is_signed(t)
        Float64(sz == 1 ? reinterpret(Int8, raw)[1] :
                sz == 2 ? reinterpret(Int16, raw)[1] : reinterpret(Int32, raw)[1])
    else
        Float64(sz == 1 ? raw[1] :
                sz == 2 ? reinterpret(UInt16, raw)[1] : reinterpret(UInt32, raw)[1])
    end
    return (val, pos + sz)
end

struct PlyProperty
    name::String
    type::String            # scalar type, or the VALUE type for a list
    islist::Bool
    counttype::String       # list length's type ("" for scalars)
end

struct PlyElement
    name::String
    count::Int
    props::Vector{PlyProperty}
end

# Index of the first byte of `needle` in `hay`, or 0. Byte-level on purpose:
# the payload after a binary PLY header is not valid UTF-8, so string search
# over the whole file is not an option.
function find_bytes(hay::Vector{UInt8}, needle::Vector{UInt8})
    n = length(needle)
    (n == 0 || length(hay) < n) && return 0
    @inbounds for i in 1:(length(hay) - n + 1)
        ok = true
        for j in 1:n
            hay[i + j - 1] == needle[j] || (ok = false; break)
        end
        ok && return i
    end
    return 0
end

# Parse the header and return (elements, format, header_byte_length). The header
# is always ASCII, even in binary files, and always ends with `end_header\n`.
function parse_ply_header(bytes::Vector{UInt8})
    at = find_bytes(bytes, Vector{UInt8}(codeunits("end_header")))
    at == 0 && throw(MeshParseError("PLY: no end_header found"))
    stop = at + length("end_header") - 1
    nl = findnext(==(UInt8('\n')), bytes, stop)
    nl === nothing && throw(MeshParseError("PLY: truncated header"))
    header = String(bytes[1:stop])
    format = "ascii"
    elements = PlyElement[]
    for line in eachsplit(header, '\n')
        f = split(strip(line))
        isempty(f) && continue
        if f[1] == "format" && length(f) >= 2
            format = String(f[2])
        elseif f[1] == "element" && length(f) >= 3
            push!(elements, PlyElement(String(f[2]), parse(Int, f[3]), PlyProperty[]))
        elseif f[1] == "property" && !isempty(elements)
            if f[2] == "list"
                length(f) >= 5 || throw(MeshParseError("PLY: malformed list property: $(line)"))
                push!(elements[end].props,
                      PlyProperty(String(f[5]), String(f[4]), true, String(f[3])))
            else
                length(f) >= 3 || throw(MeshParseError("PLY: malformed property: $(line)"))
                push!(elements[end].props, PlyProperty(String(f[3]), String(f[2]), false, ""))
            end
        end
    end
    return (elements, format, nl)
end

function parse_ply(bytes::Vector{UInt8})
    elements, format, header_end = parse_ply_header(bytes)
    format in ("ascii", "binary_little_endian", "binary_big_endian") ||
        throw(MeshParseError("PLY: unsupported format '$(format)'"))
    ascii = format == "ascii"
    # A binary_big_endian file needs byte-swapping on our (universally
    # little-endian) hosts; ENDIAN_BOM keeps that honest rather than assumed.
    swap = format == "binary_big_endian" ? (ENDIAN_BOM == 0x04030201) :
           format == "binary_little_endian" ? (ENDIAN_BOM == 0x01020304) : false

    positions = Float32[]
    indices   = UInt32[]
    corners   = Int[]
    pos = header_end + 1
    tokens = ascii ? eachsplit(String(@view bytes[(header_end + 1):end])) : nothing
    state  = ascii ? iterate(tokens) : nothing
    next_token!() = begin
        state === nothing && throw(MeshParseError("PLY: file ends mid-element"))
        tok, st = state
        state = iterate(tokens, st)
        tok
    end

    for el in elements
        isvertex = el.name == "vertex"
        isface   = el.name == "face"
        xi = findfirst(p -> p.name == "x", el.props)
        yi = findfirst(p -> p.name == "y", el.props)
        zi = findfirst(p -> p.name == "z", el.props)
        isvertex && (xi === nothing || yi === nothing || zi === nothing) &&
            throw(MeshParseError("PLY: vertex element without x/y/z properties"))
        isvertex && sizehint!(positions, 3 * el.count)
        # Indexed BY PROPERTY SLOT, not by "the scalars we happened to read":
        # x/y/z are found by their position in `el.props`, and a list-valued
        # property (legal, if meaningless, on a vertex) must not shift them.
        vals = fill(0.0, length(el.props))
        for _ in 1:el.count
            empty!(corners)
            for (pi, p) in enumerate(el.props)
                if p.islist
                    n = if ascii
                        round(Int, parse(Float64, next_token!()))
                    else
                        v, pos = ply_read_scalar(bytes, pos, p.counttype, swap); round(Int, v)
                    end
                    for _ in 1:n
                        v = if ascii
                            parse(Float64, next_token!())
                        else
                            x, pos = ply_read_scalar(bytes, pos, p.type, swap); x
                        end
                        (isface && p.name in ("vertex_indices", "vertex_index")) &&
                            push!(corners, round(Int, v))
                    end
                else
                    vals[pi] = if ascii
                        parse(Float64, next_token!())
                    else
                        x, pos = ply_read_scalar(bytes, pos, p.type, swap); x
                    end
                end
            end
            if isvertex
                push!(positions, Float32(vals[xi]), Float32(vals[yi]), Float32(vals[zi]))
            elseif isface
                nverts = length(positions) ÷ 3
                all(c -> 0 <= c < nverts, corners) ||
                    throw(MeshParseError("PLY: face references a vertex outside the vertex element"))
                push_polygon!(indices, corners)
            end
        end
    end
    return MeshData(positions, indices)
end

# ── OFF ─────────────────────────────────────────────────────────────────────
function parse_off(io::IO)
    # Comments and blank lines may appear anywhere; the counts line may also be
    # glued onto the `OFF` line.
    words = String[]
    for line in eachline(io)
        s = strip(line)
        (isempty(s) || s[1] == '#') && continue
        append!(words, split(s))
    end
    (isempty(words) || !startswith(uppercase(words[1]), "OFF")) &&
        throw(MeshParseError("OFF: missing OFF header"))
    start = uppercase(words[1]) == "OFF" ? 2 : 1
    length(words) >= start + 2 || throw(MeshParseError("OFF: truncated counts line"))
    nv = parse(Int, words[start]); nf = parse(Int, words[start + 1])
    p = start + 3
    positions = Float32[]
    for _ in 1:nv
        length(words) >= p + 2 || throw(MeshParseError("OFF: file ends inside the vertex list"))
        push!(positions, parse(Float32, words[p]), parse(Float32, words[p+1]), parse(Float32, words[p+2]))
        p += 3
    end
    indices = UInt32[]
    corners = Int[]
    for _ in 1:nf
        length(words) >= p || throw(MeshParseError("OFF: file ends inside the face list"))
        n = parse(Int, words[p]); p += 1
        empty!(corners)
        for k in 0:(n - 1)
            length(words) >= p + k || throw(MeshParseError("OFF: file ends inside a face"))
            push!(corners, parse(Int, words[p + k]))
        end
        p += n
        push_polygon!(indices, corners)
    end
    return MeshData(positions, indices)
end

# ── glTF 2.0 / GLB ──────────────────────────────────────────────────────────
# Geometry only: every `mesh.primitives` entry with mode TRIANGLES (or no mode,
# which defaults to TRIANGLES) contributes its POSITION accessor, transformed by
# the node it hangs off. Node transforms matter — a scene that composes one
# unit-cube mesh at ten different translations is a completely different shape
# without them.

const GLTF_COMPONENT = Dict(5120 => (Int8, 1), 5121 => (UInt8, 1), 5122 => (Int16, 2),
                            5123 => (UInt16, 2), 5125 => (UInt32, 4), 5126 => (Float32, 4))
const GLTF_NCOMPONENTS = Dict("SCALAR" => 1, "VEC2" => 2, "VEC3" => 3, "VEC4" => 4,
                              "MAT2" => 4, "MAT3" => 9, "MAT4" => 16)

# Split a .glb container into (json, binary chunk). GLB is a 12-byte header
# (magic "glTF", version, total length) followed by length-prefixed chunks.
function split_glb(bytes::Vector{UInt8})
    length(bytes) >= 12 && String(bytes[1:4]) == "glTF" ||
        throw(MeshParseError("GLB: bad magic (not a binary glTF file)"))
    ver = reinterpret(UInt32, view(bytes, 5:8))[1]
    ver == 2 || throw(MeshParseError("GLB: unsupported container version $(ver) (need 2)"))
    json_bytes = UInt8[]
    bin = UInt8[]
    pos = 13
    while pos + 7 <= length(bytes)
        clen = Int(reinterpret(UInt32, view(bytes, pos:(pos + 3)))[1])
        ctype = reinterpret(UInt32, view(bytes, (pos + 4):(pos + 7)))[1]
        data_start = pos + 8
        data_stop = data_start + clen - 1
        data_stop <= length(bytes) || throw(MeshParseError("GLB: truncated chunk"))
        chunk = bytes[data_start:data_stop]
        ctype == 0x4E4F534A && (json_bytes = chunk)     # 'JSON'
        ctype == 0x004E4942 && (bin = chunk)            # 'BIN\0'
        pos = data_stop + 1
    end
    isempty(json_bytes) && throw(MeshParseError("GLB: no JSON chunk"))
    return (JSON.parse(String(json_bytes)), bin)
end

# Resolve a glTF buffer to bytes. `uri` may be absent (the GLB binary chunk), a
# `data:` URI, or a relative path to a sibling file — `read_sibling` is how the
# caller supplies that file's bytes (it lives on the worker, so the file viewer
# passes a fetch closure rather than a plain `read`).
function gltf_buffer_bytes(buf::AbstractDict, glb_bin::Vector{UInt8}, read_sibling)
    uri = get(buf, "uri", nothing)
    uri === nothing && return glb_bin
    u = String(uri)
    if startswith(u, "data:")
        comma = findfirst(==(','), u)
        comma === nothing && throw(MeshParseError("glTF: malformed data: URI"))
        occursin("base64", u[1:comma]) ||
            throw(MeshParseError("glTF: only base64 data: URIs are supported"))
        return base64decode(u[(comma + 1):end])
    end
    startswith(u, "http://") || startswith(u, "https://") ||
        return read_sibling(HTTP.URIs.unescapeuri(u))
    throw(MeshParseError("glTF: refusing to fetch an external buffer over the network ($(u))"))
end

# Read accessor `ai` as a flat Float64 vector (`length = count * ncomponents`),
# honouring bufferView byteStride. Sparse accessors are rejected rather than
# silently mis-read.
function gltf_read_accessor(gltf::AbstractDict, ai::Integer, buffers::Vector{Vector{UInt8}})
    accessors = get(gltf, "accessors", [])
    (0 <= ai < length(accessors)) || throw(MeshParseError("glTF: accessor $(ai) out of range"))
    acc = accessors[ai + 1]
    haskey(acc, "sparse") && throw(MeshParseError("glTF: sparse accessors are not supported"))
    ctype = Int(acc["componentType"])
    haskey(GLTF_COMPONENT, ctype) ||
        throw(MeshParseError("glTF: unknown componentType $(ctype)"))
    T, tsize = GLTF_COMPONENT[ctype]
    ncomp = get(GLTF_NCOMPONENTS, String(acc["type"]), 0)
    ncomp == 0 && throw(MeshParseError("glTF: unknown accessor type '$(acc["type"])'"))
    count = Int(acc["count"])
    out = Vector{Float64}(undef, count * ncomp)
    bvi = get(acc, "bufferView", nothing)
    if bvi === nothing
        fill!(out, 0.0)                    # spec: no bufferView ⇒ all zeros
        return (out, ncomp, count)
    end
    bv = gltf["bufferViews"][Int(bvi) + 1]
    buf = buffers[Int(bv["buffer"]) + 1]
    base = Int(get(bv, "byteOffset", 0)) + Int(get(acc, "byteOffset", 0))
    stride = Int(get(bv, "byteStride", 0))
    stride == 0 && (stride = ncomp * tsize)
    # `T` comes from a runtime table lookup, so the read loop can't specialise
    # here — every element would box. Hand it to a method parameterised on `T`
    # (a function barrier) and the loop compiles to a typed load. This is the
    # innermost loop of the whole mesh path: at the 4M-triangle cap it runs tens
    # of millions of times.
    gltf_fill_accessor!(out, buf, T, base, stride, tsize, ncomp, count)
    return (out, ncomp, count)
end

function gltf_fill_accessor!(out::Vector{Float64}, buf::Vector{UInt8}, ::Type{T},
                             base::Int, stride::Int, tsize::Int,
                             ncomp::Int, count::Int) where {T}
    for i in 0:(count - 1)
        off = base + i * stride
        for c in 0:(ncomp - 1)
            lo = off + c * tsize + 1
            hi = lo + tsize - 1
            hi <= length(buf) || throw(MeshParseError("glTF: accessor reads past the end of its buffer"))
            # A view, never `buf[lo:hi]` — that would copy a 1-4 byte array per
            # component. glTF buffers are little-endian, same as every platform
            # this runs on, so `reinterpret` is the whole conversion.
            out[i * ncomp + c + 1] = Float64(only(reinterpret(T, @view buf[lo:hi])))
        end
    end
    return out
end

# Column-major 4x4 multiply on plain 16-element vectors (glTF's matrix layout).
function mat4_mul(a::Vector{Float64}, b::Vector{Float64})
    o = zeros(Float64, 16)
    for c in 0:3, r in 0:3
        s = 0.0
        for k in 0:3
            s += a[k * 4 + r + 1] * b[c * 4 + k + 1]
        end
        o[c * 4 + r + 1] = s
    end
    return o
end

const MAT4_IDENTITY = Float64[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]

# A node's local transform: an explicit `matrix`, else T·R·S from the separate
# translation/rotation/scale fields (rotation is a xyzw quaternion).
function gltf_node_matrix(node::AbstractDict)
    haskey(node, "matrix") && return Float64[Float64(v) for v in node["matrix"]]
    t = get(node, "translation", [0.0, 0.0, 0.0])
    r = get(node, "rotation", [0.0, 0.0, 0.0, 1.0])
    s = get(node, "scale", [1.0, 1.0, 1.0])
    x, y, z, w = Float64(r[1]), Float64(r[2]), Float64(r[3]), Float64(r[4])
    rot = Float64[
        1 - 2 * (y * y + z * z), 2 * (x * y + z * w),     2 * (x * z - y * w),     0,
        2 * (x * y - z * w),     1 - 2 * (x * x + z * z), 2 * (y * z + x * w),     0,
        2 * (x * z + y * w),     2 * (y * z - x * w),     1 - 2 * (x * x + y * y), 0,
        0, 0, 0, 1]
    scl = Float64[Float64(s[1]),0,0,0, 0,Float64(s[2]),0,0, 0,0,Float64(s[3]),0, 0,0,0,1]
    tr  = Float64[1,0,0,0, 0,1,0,0, 0,0,1,0, Float64(t[1]),Float64(t[2]),Float64(t[3]),1]
    return mat4_mul(tr, mat4_mul(rot, scl))
end

function parse_gltf(gltf::AbstractDict, glb_bin::Vector{UInt8}, read_sibling)
    buffers = Vector{UInt8}[gltf_buffer_bytes(b, glb_bin, read_sibling)
                            for b in get(gltf, "buffers", [])]
    positions = Float32[]
    indices   = UInt32[]

    add_primitive!(prim, M) = begin
        Int(get(prim, "mode", 4)) == 4 || return    # geometry preview: triangles only
        attrs = get(prim, "attributes", Dict{String,Any}())
        haskey(attrs, "POSITION") || return
        pos, ncomp, count = gltf_read_accessor(gltf, Int(attrs["POSITION"]), buffers)
        ncomp == 3 || throw(MeshParseError("glTF: POSITION accessor is not VEC3"))
        base = length(positions) ÷ 3
        for i in 0:(count - 1)
            x, y, z = pos[3i + 1], pos[3i + 2], pos[3i + 3]
            push!(positions,
                Float32(M[1] * x + M[5] * y + M[9]  * z + M[13]),
                Float32(M[2] * x + M[6] * y + M[10] * z + M[14]),
                Float32(M[3] * x + M[7] * y + M[11] * z + M[15]))
        end
        if haskey(prim, "indices")
            idx, _, icount = gltf_read_accessor(gltf, Int(prim["indices"]), buffers)
            icount % 3 == 0 ||
                throw(MeshParseError("glTF: index count $(icount) is not a multiple of 3"))
            for v in idx
                push!(indices, UInt32(base + round(Int, v)))
            end
        else
            # Non-indexed primitive: vertices are consecutive triangles.
            count % 3 == 0 ||
                throw(MeshParseError("glTF: non-indexed primitive with $(count) vertices"))
            append!(indices, UInt32.(base:(base + count - 1)))
        end
    end

    meshes = get(gltf, "meshes", [])
    nodes  = get(gltf, "nodes", [])
    visited = Set{Int}()
    walk(ni, parent) = begin
        (0 <= ni < length(nodes)) || return
        # Guard against a malformed file whose node graph has a cycle: without
        # this we'd recurse until the stack dies.
        ni in visited && return
        push!(visited, ni)
        node = nodes[ni + 1]
        M = mat4_mul(parent, gltf_node_matrix(node))
        if haskey(node, "mesh")
            mi = Int(node["mesh"])
            (0 <= mi < length(meshes)) &&
                foreach(p -> add_primitive!(p, M), get(meshes[mi + 1], "primitives", []))
        end
        foreach(c -> walk(Int(c), M), get(node, "children", []))
        delete!(visited, ni)
    end

    scenes = get(gltf, "scenes", [])
    roots = if !isempty(scenes)
        si = Int(get(gltf, "scene", 0))
        (0 <= si < length(scenes)) ? get(scenes[si + 1], "nodes", []) : get(scenes[1], "nodes", [])
    else
        []
    end
    if isempty(roots) && isempty(nodes)
        # Buffer-only glTF with meshes but no scene graph — draw them untransformed
        # rather than reporting an empty file.
        for m in meshes
            foreach(p -> add_primitive!(p, MAT4_IDENTITY), get(m, "primitives", []))
        end
    else
        isempty(roots) && (roots = collect(0:(length(nodes) - 1)))
        foreach(n -> walk(Int(n), MAT4_IDENTITY), roots)
    end
    return MeshData(positions, indices)
end

"""
    parse_mesh(path; read_sibling) -> MeshData

Read a geometry file into one triangle soup. Dispatches on the extension:
`.obj`, `.stl` (ASCII + binary), `.ply` (ASCII + both binary orders), `.off`,
`.glb`, `.gltf`.

`read_sibling(name) -> Vector{UInt8}` supplies files a `.gltf` references
relatively (its `.bin` buffers). The default reads them next to `path`, which is
right for a local file; the file viewer passes a closure that fetches them from
the worker instead. Throws [`MeshParseError`](@ref) with a user-facing message
for anything we can't read.
"""
function parse_mesh(path::AbstractString;
                    read_sibling = name -> read(joinpath(dirname(String(path)), name)))
    ext = lowercase(splitext(path)[2])
    if ext == ".obj"
        return open(parse_obj, path, "r")
    elseif ext == ".stl"
        return parse_stl(read(path))
    elseif ext == ".ply"
        return parse_ply(read(path))
    elseif ext == ".off"
        return open(parse_off, path, "r")
    elseif ext == ".glb"
        gltf, bin = split_glb(read(path))
        return parse_gltf(gltf, bin, read_sibling)
    elseif ext == ".gltf"
        return parse_gltf(JSON.parse(read(path, String)), UInt8[], read_sibling)
    end
    throw(MeshParseError("no geometry reader for '$(ext)' files"))
end

# ── Wire format ─────────────────────────────────────────────────────────────
# `assets/meshview.js :: parseBlob` is the other half of this; keep them in step.
const MESH_BLOB_MAGIC = "BTMESH1\0"

function write_mesh_blob(io::IO, m::MeshData)
    write(io, MESH_BLOB_MAGIC)
    write(io, UInt32(nvertices(m)), UInt32(ntriangles(m)))
    write(io, m.positions)
    write(io, m.normals)
    write(io, m.indices)
    return io
end

"""
    mesh_blob_path(dir, source_path, m) -> String

Write `m` as a BTMESH1 blob under `dir` and return the file path, ready to hand
to `Bonito.Asset`. The name is derived from the source path + geometry size, so
re-opening the same unchanged file reuses one blob instead of accumulating a
copy per open, while a re-exported model (different triangle count) gets a
distinct name and therefore a distinct asset url.
"""
function mesh_blob_path(dir::AbstractString, source_path::AbstractString, m::MeshData)
    key = bytes2hex(sha1(string(source_path, ':', nvertices(m), ':', ntriangles(m))))[1:16]
    mkpath(dir)
    dst = joinpath(dir, "$(key).btmesh")
    isfile(dst) && return dst
    # Two tabs opening the same model at once would otherwise interleave in one
    # shared `<dst>.partial` and hand the browser a torn blob. A per-write temp
    # name plus the atomic rename means the losers just overwrite an identical
    # file — the same trick the file mirror uses for transfers.
    tmp = "$(dst).$(getpid()).$(objectid(m)).partial"
    try
        open(io -> write_mesh_blob(io, m), tmp, "w")
        mv(tmp, dst; force = true)
    catch
        rm(tmp; force = true)   # never leave a torso behind for the next reader
        rethrow()
    end
    return dst
end
