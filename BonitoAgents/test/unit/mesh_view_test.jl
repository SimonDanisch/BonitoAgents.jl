@testitem "unit:mesh_view" tags = [:unit] begin

# Geometry-file parsing for the file viewer's 3D preview. This is where the
# format zoo's bugs live, so it's tested HERE (headless, exact) rather than
# through a browser: OBJ's negative indices and n-gons, binary vs ASCII STL,
# PLY's typed property table, OFF, and glTF's accessors + node transforms.
#
# Each case asserts the actual triangle soup — counts AND positions — because
# "it parsed without throwing" is exactly the bar a mesh viewer fails at
# silently (wrong winding, off-by-one indices, ignored transforms all still
# "work").

using Test
using BonitoAgents
using BonitoAgents: parse_obj, parse_stl, parse_ply, parse_off, parse_gltf,
                    split_glb, stl_is_binary, parse_mesh, MeshData, MeshParseError,
                    nvertices, ntriangles, write_mesh_blob, mesh_blob_path,
                    vertex_normals
const BT = BonitoAgents
const JSON = BonitoAgents.JSON

# A unit square as two triangles, in every format below.
const SQUARE_TRIS = UInt32[0,1,2, 0,2,3]

@testset "OBJ" begin
    m = parse_obj(IOBuffer("""
    # a comment
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0
    vt 0 0
    f 1 2 3 4
    """))
    @test nvertices(m) == 4
    # An n-gon fan-triangulates; a quad is exactly two triangles.
    @test ntriangles(m) == 2
    @test m.indices == SQUARE_TRIS
    # Flat in z ⇒ every normal is ±z.
    @test all(abs(m.normals[i]) ≈ 1 for i in 3:3:length(m.normals))

    @testset "face index forms" begin
        # v/vt/vn triplets: only the position slot counts.
        m2 = parse_obj(IOBuffer("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1/1/1 2/2/2 3/3/3\n"))
        @test m2.indices == UInt32[0,1,2]
        # NEGATIVE indices address backwards from the current vertex count.
        m3 = parse_obj(IOBuffer("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\n"))
        @test m3.indices == UInt32[0,1,2]
        # Tab-separated writers exist and must not be skipped.
        m4 = parse_obj(IOBuffer("v\t0\t0\t0\nv\t1\t0\t0\nv\t0\t1\t0\nf\t1\t2\t3\n"))
        @test nvertices(m4) == 3 && ntriangles(m4) == 1
    end

    @testset "malformed input reports, never guesses" begin
        # A face pointing at a vertex that was never defined is a corrupt file,
        # not something to silently clamp — clamping draws a wrong shape.
        @test_throws MeshParseError parse_obj(IOBuffer("v 0 0 0\nf 1 2 3\n"))
        @test_throws MeshParseError parse_obj(IOBuffer("v 0 0\n"))
        # No triangles at all is also an error (an empty canvas explains nothing).
        @test_throws MeshParseError parse_obj(IOBuffer("v 0 0 0\n"))
    end
end

@testset "STL" begin
    tri = Float32[0,0,0, 1,0,0, 0,1,0]

    @testset "binary" begin
        io = IOBuffer()
        write(io, zeros(UInt8, 80)); write(io, UInt32(1))
        write(io, Float32[0,0,1])                       # facet normal (recomputed)
        write(io, tri)
        write(io, UInt16(0))                            # attribute byte count
        bytes = take!(io)
        @test stl_is_binary(bytes)
        m = parse_stl(bytes)
        @test nvertices(m) == 3 && ntriangles(m) == 1
        @test m.positions == tri
    end

    @testset "ASCII" begin
        bytes = Vector{UInt8}(codeunits("""
        solid s
        facet normal 0 0 1
          outer loop
            vertex 0 0 0
            vertex 1 0 0
            vertex 0 1 0
          endloop
        endfacet
        endsolid s
        """))
        @test !stl_is_binary(bytes)
        m = parse_stl(bytes)
        @test nvertices(m) == 3 && ntriangles(m) == 1
        @test m.positions == tri
    end

    # The classic trap: a BINARY stl whose 80-byte header begins with the word
    # "solid" (several exporters write exactly that). Only the size arithmetic
    # tells the two apart, so that's what `stl_is_binary` uses.
    @testset "binary file whose header says 'solid'" begin
        io = IOBuffer()
        hdr = zeros(UInt8, 80); hdr[1:5] = Vector{UInt8}(codeunits("solid"))
        write(io, hdr); write(io, UInt32(1))
        write(io, Float32[0,0,1]); write(io, tri); write(io, UInt16(0))
        bytes = take!(io)
        @test stl_is_binary(bytes)
        @test ntriangles(parse_stl(bytes)) == 1
    end
end

@testset "PLY" begin
    @testset "ASCII" begin
        m = parse_ply(Vector{UInt8}(codeunits("""ply
        format ascii 1.0
        element vertex 4
        property float x
        property float y
        property float z
        element face 2
        property list uchar int vertex_indices
        end_header
        0 0 0
        1 0 0
        1 1 0
        0 1 0
        3 0 1 2
        3 0 2 3
        """)))
        @test nvertices(m) == 4 && ntriangles(m) == 2
        @test m.indices == SQUARE_TRIS
    end

    # Binary, WITH a trailing non-coordinate property: x/y/z are located by their
    # slot in the property table, so an extra `uchar red` must not shift them.
    @testset "binary_little_endian with extra properties" begin
        io = IOBuffer()
        write(io, """ply
        format binary_little_endian 1.0
        element vertex 4
        property float x
        property float y
        property float z
        property uchar red
        element face 2
        property list uchar int vertex_indices
        end_header
        """)
        for (x, y, z) in ((0,0,0), (1,0,0), (1,1,0), (0,1,0))
            write(io, Float32(x), Float32(y), Float32(z), UInt8(200))
        end
        write(io, UInt8(3), Int32(0), Int32(1), Int32(2))
        write(io, UInt8(3), Int32(0), Int32(2), Int32(3))
        m = parse_ply(take!(io))
        @test nvertices(m) == 4 && ntriangles(m) == 2
        @test m.positions[1:6] == Float32[0,0,0, 1,0,0]
        @test m.indices == SQUARE_TRIS
    end

    @testset "rejects what it can't read" begin
        @test_throws MeshParseError parse_ply(Vector{UInt8}(codeunits("not a ply at all")))
        @test_throws MeshParseError parse_ply(Vector{UInt8}(codeunits(
            "ply\nformat something_else 1.0\nelement vertex 0\nend_header\n")))
    end
end

@testset "OFF" begin
    m = parse_off(IOBuffer("""OFF
    # comment
    4 2 0
    0 0 0
    1 0 0
    1 1 0
    0 1 0
    3 0 1 2
    3 0 2 3
    """))
    @test nvertices(m) == 4 && ntriangles(m) == 2
    @test m.indices == SQUARE_TRIS
end

# One triangle mesh, referenced from a node that TRANSLATES it. A viewer that
# ignores node transforms draws a completely different scene, so the assertion
# is on the transformed coordinates, not just the counts.
function build_glb(; translation = [10.0, 0.0, 0.0])
    verts = Float32[0,0,0, 1,0,0, 0,1,0]
    idxs  = UInt16[0,1,2]
    bin = vcat(reinterpret(UInt8, verts), reinterpret(UInt8, idxs))
    bin = vcat(bin, zeros(UInt8, mod(-length(bin), 4)))
    gltf = Dict(
        "asset" => Dict("version" => "2.0"),
        "scene" => 0, "scenes" => [Dict("nodes" => [0])],
        "nodes" => [Dict("mesh" => 0, "translation" => translation)],
        "meshes" => [Dict("primitives" => [Dict("attributes" => Dict("POSITION" => 0),
                                                "indices" => 1)])],
        "accessors" => [Dict("bufferView" => 0, "componentType" => 5126, "count" => 3, "type" => "VEC3"),
                        Dict("bufferView" => 1, "componentType" => 5123, "count" => 3, "type" => "SCALAR")],
        "bufferViews" => [Dict("buffer" => 0, "byteOffset" => 0,  "byteLength" => 36),
                          Dict("buffer" => 0, "byteOffset" => 36, "byteLength" => 6)],
        "buffers" => [Dict("byteLength" => length(bin))])
    jsonb = Vector{UInt8}(codeunits(JSON.json(gltf)))
    append!(jsonb, fill(UInt8(' '), mod(-length(jsonb), 4)))
    io = IOBuffer()
    write(io, "glTF", UInt32(2), UInt32(12 + 8 + length(jsonb) + 8 + length(bin)))
    write(io, UInt32(length(jsonb)), UInt32(0x4E4F534A)); write(io, jsonb)
    write(io, UInt32(length(bin)),   UInt32(0x004E4942)); write(io, bin)
    return take!(io)
end

@testset "glTF / GLB" begin
    gltf, bin = split_glb(build_glb())
    m = parse_gltf(gltf, bin, _ -> error("no sibling buffers expected"))
    @test nvertices(m) == 3 && ntriangles(m) == 1
    # Node translation applied: the whole triangle sits at x + 10.
    @test m.positions == Float32[10,0,0, 11,0,0, 10,1,0]

    # No transform ⇒ raw coordinates, i.e. the transform code is what moved it.
    gltf2, bin2 = split_glb(build_glb(; translation = [0.0, 0.0, 0.0]))
    @test parse_gltf(gltf2, bin2, _ -> UInt8[]).positions == Float32[0,0,0, 1,0,0, 0,1,0]

    @test_throws MeshParseError split_glb(Vector{UInt8}(codeunits("not a glb")))

    # A .gltf with an EXTERNAL .bin resolves it through `read_sibling` — which is
    # how the file viewer reaches a buffer that lives on the worker.
    @testset "external buffer via read_sibling" begin
        g, b = split_glb(build_glb())
        g["buffers"][1]["uri"] = "scene.bin"
        asked = String[]
        m3 = parse_gltf(g, UInt8[], name -> (push!(asked, name); b))
        @test asked == ["scene.bin"]
        @test ntriangles(m3) == 1
    end

    # Fetching a buffer over the network from a file preview is not something we
    # do quietly — it's refused with a message.
    @testset "refuses remote buffers" begin
        g, _ = split_glb(build_glb())
        g["buffers"][1]["uri"] = "https://example.com/evil.bin"
        @test_throws MeshParseError parse_gltf(g, UInt8[], _ -> UInt8[])
    end
end

@testset "normals" begin
    # Two triangles meeting at a 90° fold share an edge; the shared vertices get
    # the average of both faces, the corner vertices keep their own face normal.
    pos = Float32[0,0,0, 1,0,0, 1,1,0, 1,0,1]
    idx = UInt32[0,1,2, 1,3,2]
    n = vertex_normals(pos, idx)
    @test length(n) == length(pos)
    for i in 1:3:length(n)
        @test sqrt(n[i]^2 + n[i+1]^2 + n[i+2]^2) ≈ 1 atol = 1e-5
    end
end

@testset "dispatch by extension + the BTMESH1 blob" begin
    dir = mktempdir()
    obj = joinpath(dir, "square.obj")
    write(obj, "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
    m = parse_mesh(obj)
    @test ntriangles(m) == 2
    @test_throws MeshParseError parse_mesh(joinpath(dir, "thing.xyz"))

    # The blob layout is a contract with assets/meshview.js — magic, counts, then
    # positions, normals, indices. Decode it back here so a layout change can't
    # land without this failing.
    blob = mesh_blob_path(joinpath(dir, "blobs"), obj, m)
    bytes = read(blob)
    @test String(bytes[1:8]) == "BTMESH1\0"
    nv, nt = reinterpret(UInt32, bytes[9:16])
    @test nv == nvertices(m) && nt == ntriangles(m)
    off = 16
    pos = reinterpret(Float32, bytes[(off + 1):(off + 12 * Int(nv))]); off += 12 * Int(nv)
    nrm = reinterpret(Float32, bytes[(off + 1):(off + 12 * Int(nv))]); off += 12 * Int(nv)
    idx = reinterpret(UInt32,  bytes[(off + 1):(off + 12 * Int(nt))])
    @test pos == m.positions
    @test nrm == m.normals
    @test idx == m.indices
    @test off + 12 * Int(nt) == length(bytes)     # nothing trailing, nothing missing

    # Same file + same geometry ⇒ same blob (one file, not one per open).
    @test mesh_blob_path(joinpath(dir, "blobs"), obj, m) == blob
end

end
