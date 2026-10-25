# A worker file piece (`read_file_range`) arrives as a msgpack bin and stays a
# `Vector{UInt8}`. It used to be an array of numbers, one per byte, which
# `normalize_wire` widened into a `Vector{Any}` of Int64: 49 ms and 4.5 MB of
# garbage per 256 KiB piece, on the reader every reply of that worker waits
# behind. A page with 20 photos kept the server busy for seconds.
@testitem "unit:file_piece_wire" tags = [:unit] begin
    using Test
    using BonitoAgents
    const BT = BonitoAgents
    import BonitoWorker
    const MP = BT.MsgPack

    data = rand(UInt8, 256 * 1024)
    frame = MP.pack(Dict{String,Any}("type" => "read_file_range_response", "request_id" => "r1",
                                     "data" => BonitoWorker.WireBytes(data)))
    @test length(frame) < length(data) + 100
    reply = BT.decode_control(frame)
    @test reply["data"] isa Vector{UInt8}
    @test BT.ctrl_bytes(reply["data"]) === reply["data"]
    @test reply["data"] == data
    @test @allocated(BT.decode_control(frame)) < 2 * length(data)

    # A worker from before `WireBytes` sends a list of numbers until it updates.
    old = MP.pack(Dict{String,Any}("data" => Any[data...]))
    @test BT.ctrl_bytes(BT.decode_control(old)["data"]) == data
    # An eval process has Bonito loaded: bytes come as an extension.
    ext = MP.pack(Dict{String,Any}("data" => data))
    @test BT.ctrl_bytes(BT.decode_control(ext)["data"]) == data
end
