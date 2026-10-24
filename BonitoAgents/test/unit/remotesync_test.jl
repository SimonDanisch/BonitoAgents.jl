# RemoteSync over real HTTP.WebSockets: stream a file through send_file /
# receive_file and compare bytes (sha256). Headless integration — no Electron.
# Ported from test/electron/test_remotesync.jl.
#
# NOTE: the client waits for the receiver to finish (`take!(done)`) BEFORE the
# `open do…end` block closes the WS. Closing immediately after `send_file`
# returns races the final FILE_END frame's drain to the socket (HTTP.WebSockets
# close no longer drains pending writes) and loses it → EOF on the receiver.
# Production keeps the transfer-ws open, so this mirrors real usage.
@testitem "unit:remotesync" tags = [:unit] begin
    using HTTP, RemoteSync, SHA

    port = 19000 + rand(1:999)
    dst = tempname() * ".bin"
    done = Channel{Any}(1)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        try
            io = RemoteSync.WebSocketIO(ws)
            n, _ = RemoteSync.receive_file(dst, io)
            put!(done, (:ok, n))
        catch e
            put!(done, (:err, e))
        end
    end

    src = tempname() * ".bin"
    payload = vcat(rand(UInt8, 1024 * 64),
                   codeunits("RemoteSync end-to-end test marker"),
                   rand(UInt8, 1024 * 64))
    write(src, payload)
    src_sha = bytes2hex(sha256(payload))
    result = Ref{Any}(nothing)

    try
        HTTP.WebSockets.open("ws://127.0.0.1:$port/transfer-ws") do ws
            io = RemoteSync.WebSocketIO(ws)
            sent = RemoteSync.send_file(src, io)
            @test Int(sent) == length(payload)
            result[] = take!(done)   # let the receiver finish before we close
        end

        @test result[][1] === :ok
        result[][1] === :ok && @test Int(result[][2]) == length(payload)
        @test isfile(dst)
        if isfile(dst)
            dst_bytes = read(dst)
            @test length(dst_bytes) == length(payload)
            @test bytes2hex(sha256(dst_bytes)) == src_sha
            @test occursin("RemoteSync end-to-end test marker", String(dst_bytes))
        end
    finally
        close(server)   # idempotent
        rm(src; force = true)
        rm(dst; force = true)
    end
end

# librsync reads the basis through a Julia callback, which cannot throw across C:
# it returned librsync's IO error and the reason was gone ("patch job failed: IO
# error"). The callback now keeps the exception and `apply_patch` throws it.
@testitem "unit:remotesync_patch_basis_error" tags = [:unit] begin
    import BonitoAgents
    using Test
    const RS = BonitoAgents.RemoteSync

    struct VanishedBasis <: IO end
    Base.seek(::VanishedBasis, ::Integer) = error("the basis went away")
    Base.eof(::VanishedBasis) = false

    basis = rand(UInt8, 200_000)
    sig = IOBuffer()
    RS.compute_signature(IOBuffer(basis), sig)
    changed = vcat(basis[1:100_000], rand(UInt8, 5_000))
    delta = IOBuffer()
    RS.compute_delta(seekstart(sig), IOBuffer(changed), delta)

    err = try
        RS.apply_patch(VanishedBasis(), seekstart(delta), IOBuffer())
        nothing
    catch e
        e
    end
    @test err isa CapturedException
    @test occursin("the basis went away", sprint(showerror, err))

    # The working path is unchanged.
    rebuilt = IOBuffer()
    RS.apply_patch(IOBuffer(basis), seekstart(delta), rebuilt)
    @test take!(rebuilt) == changed
end
