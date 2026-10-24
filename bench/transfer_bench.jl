# Run through julia_eval in an existing environment with RemoteSync/WorkerLink.
# start_receiver binds only the supplied address and writes only under a fresh
# temporary directory. close(receiver) stops every benchmark listener.
# Example (receiver): r = TransferBench.start_receiver("192.168.178.59");
#                    TransferBench.addresses(r)
# Example (sender): TransferBench.transfer(url, token, dataset;
#                    transport=:link, mode=:directory)
# Use a fresh destination id for a full copy; reuse id for an unchanged sync.
# Warm each mode before taking repeated measurements. Data is written through
# the OS page cache (no fsync). WebSocket setup and SHA verification are untimed;
# HTTP timing includes request setup but also excludes SHA verification.
module TransferBench

using RemoteSync, WorkerLink, SHA, Random, Statistics
const HTTP = RemoteSync.HTTP
const WS = HTTP.WebSockets
const CHUNK = 1024 * 1024

function make_dataset(root, name, files, bytes; seed = 42)
    dst = joinpath(root, name)
    ispath(dst) && error("benchmark destination already exists: $dst")
    mkpath(dst)
    block = rand(MersenneTwister(seed), UInt8, min(bytes, CHUNK))
    for i in 1:files
        open(joinpath(dst, "file-$(lpad(i, 4, '0')).bin"), "w") do io
            remaining = bytes
            while remaining > 0
                n = min(remaining, length(block))
                write(io, view(block, 1:n))
                remaining -= n
            end
        end
    end
    return dst
end

function tree_hash(root)
    io = IOBuffer()
    for e in RemoteSync.walk_directory(root)
        write(io, e.rel, '\0', open(sha256, joinpath(root, e.rel)))
    end
    return bytes2hex(sha256(take!(io)))
end

function receive_transfer(ch, header, root, token)
    fields = split(header, '|')
    length(fields) == 4 || error("invalid benchmark header")
    key, mode, id, amount = fields
    key == token || error("invalid benchmark token")
    occursin(r"^[a-zA-Z0-9_-]+$", id) || error("invalid benchmark id")
    dst = mkpath(joinpath(root, id))
    if mode == "directory"
        RemoteSync.receive_directory(dst, RemoteSync.WebSocketIO(ch))
    elseif mode == "bulk"
        remaining = parse(Int, amount)
        0 <= remaining <= 128CHUNK || error("benchmark size limit")
        open(joinpath(dst, "file-0001.bin"), "w") do io
            while remaining > 0
                bytes = WS.receive(ch)
                length(bytes) <= remaining || error("oversized benchmark message")
                write(io, bytes)
                remaining -= length(bytes)
            end
        end
    else
        error("unknown benchmark mode")
    end
    WS.send(ch, "done")
    # Verification is deliberately outside the timed interval.
    WS.send(ch, tree_hash(dst))
    String(WS.receive(ch)) == "verified" || error("missing verification acknowledgement")
    WS.send(ch, "verified")
    return nothing
end

struct Receiver
    host::String
    root::String
    token::String
    raw::Any
    link::Any
    http::Any
    links::Vector{WorkerLink.Link}
end

function start_receiver(host; window = WorkerLink.DEFAULT_WINDOW)
    root = mktempdir(; prefix = "bonito-transfer-receiver-")
    token = randstring(32)
    links = WorkerLink.Link[]
    raw = WS.listen!(host, 0; listenany = true) do ws
        receive_transfer(ws, String(WS.receive(ws)), root, token)
    end
    link = WS.listen!(host, 0; listenany = true) do ws
        t = WorkerLink.WebSocketTransport(ws)
        hello = WorkerLink.read_hello(t)
        hello.app == Vector{UInt8}(token) || error("invalid benchmark token")
        server = WorkerLink.Link(:server; id = hello.link_id, window,
            on_open = ch -> receive_transfer(ch, String(copy(WorkerLink.header(ch))), root, token))
        push!(links, server)
        WorkerLink.welcome!(server, t, hello, UInt8[]; resumed = false)
        wait(t)
    end
    http = HTTP.serve!(host, 0; listenany = true, max_body_bytes = 128CHUNK) do req
        req.target == "/$token" || return HTTP.Response(404)
        file = joinpath(root, "http-upload.bin")
        if req.method == "GET"
            return HTTP.Response(200, bytes2hex(open(sha256, file)))
        end
        req.method == "PUT" || return HTTP.Response(405)
        bytes = req.body.data # serve! has already buffered the request body
        write(file, bytes)
        HTTP.Response(200, string(length(bytes)))
    end
    return Receiver(String(host), root, token, raw, link, http, links)
end

function addresses(r::Receiver)
    # HTTP 2.8's WS.server_addr reports loopback even when bound to a LAN IP.
    address(s) = r.host * ":" * last(split(WS.server_addr(s), ':'))
    return (raw = "ws://" * address(r.raw),
            link = "ws://" * address(r.link),
            http = "http://" * HTTP.server_addr(r.http), token = r.token)
end

function Base.close(r::Receiver)
    foreach(l -> WorkerLink.kill!(l, "benchmark finished"), r.links)
    close(r.raw); close(r.link); close(r.http)
end

function transfer(url, token, src; transport = :raw, mode = :directory,
                  id = randstring(12), window = WorkerLink.DEFAULT_WINDOW,
                  streaming = true)
    expected = tree_hash(src)
    bytes = sum(e.size for e in RemoteSync.walk_directory(src); init = UInt64(0))
    header = "$token|$mode|$id|$bytes"
    ws = WS.open(url)
    link = nothing
    try
        ch = if transport === :link
            link = WorkerLink.Link(:client; window)
            WorkerLink.connect!(link, WorkerLink.WebSocketTransport(ws), Vector{UInt8}(token))
            WorkerLink.open_channel(link, Vector{UInt8}(header); priority = 3)
        else
            WS.send(ws, header)
            ws
        end
        # Connection establishment is excluded for these transport microbenchmarks.
        measurement = @timed begin
            if mode === :directory
                RemoteSync.send_directory(src, RemoteSync.WebSocketIO(ch); streaming)
            else
                open(joinpath(src, "file-0001.bin"), "r") do io
                    while !eof(io)
                        WS.send(ch, read(io, CHUNK))
                    end
                end
            end
            String(WS.receive(ch)) == "done" || error("missing completion")
        end
        String(WS.receive(ch)) == expected || error("checksum mismatch")
        WS.send(ch, "verified")
        String(WS.receive(ch)) == "verified" || error("receiver did not finish verification")
        return (seconds = measurement.time, mib_s = bytes / 2.0^20 / measurement.time,
                allocated_mib = measurement.bytes / 2.0^20, gc_seconds = measurement.gctime,
                verified = true)
    finally
        link === nothing ? close(ws) : WorkerLink.kill!(link, "benchmark finished")
    end
end

function http_upload(url, token, src)
    file = joinpath(src, "file-0001.bin")
    expected = bytes2hex(open(sha256, file))
    m = @timed open(file, "r") do io
        HTTP.request("PUT", "$url/$token", ["Content-Length" => string(filesize(file))], io; retry = false)
    end
    String(m.value.body) == string(filesize(file)) || error("HTTP byte count mismatch")
    # As with WS transfers, checksum verification is outside the timed upload.
    verification = HTTP.get("$url/$token"; retry = false)
    String(verification.body) == expected || error("HTTP checksum mismatch")
    return (seconds = m.time, mib_s = filesize(file) / 2.0^20 / m.time, verified = true)
end

end
