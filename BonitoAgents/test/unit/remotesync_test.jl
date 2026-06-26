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
        try close(server) catch end
        try rm(src) catch end
        try rm(dst) catch end
    end
end
