# A framed chunk fits in one WebSocketIO message and one WorkerLink window.
# No whole-file delta or literal is buffered in this protocol.
const DIRECTORY_CHUNK_BYTES = 1024 * 1024 - 5
const SMALL_FILE_BYTES = 64 * 1024

mutable struct DeltaWriter{T<:IO} <: IO
    transport::T
    buffer::IOBuffer
end
DeltaWriter(io::IO) = DeltaWriter(io, IOBuffer())

function Base.flush(io::DeltaWriter)
    position(io.buffer) == 0 || write_frame(io.transport, TAG_DATA, take!(io.buffer))
    return nothing
end

function Base.unsafe_write(io::DeltaWriter, p::Ptr{UInt8}, n::UInt)
    offset = UInt(0)
    while offset < n
        count = min(n - offset, UInt(DIRECTORY_CHUNK_BYTES - position(io.buffer)))
        unsafe_write(io.buffer, p + offset, count)
        offset += count
        position(io.buffer) == DIRECTORY_CHUNK_BYTES && flush(io)
    end
    return n
end
Base.write(io::DeltaWriter, byte::UInt8) =
    (write(io.buffer, byte); position(io.buffer) == DIRECTORY_CHUNK_BYTES && flush(io); 1)

mutable struct DeltaReader{T<:IO} <: IO
    transport::T
    buffer::Vector{UInt8}
    pos::Int
    ended::Bool
end
DeltaReader(io::IO) = DeltaReader(io, UInt8[], 1, false)

# Unlike legacy read_frame, refuse an oversized data frame BEFORE allocating
# its payload. Metadata retains the separate, existing frame limit.
function read_chunk(io::IO)
    tag = read(io, UInt8)
    size = Int(ltoh(read(io, UInt32)))
    if tag == TAG_END
        size == 0 || error("RemoteSync: END must be empty")
    elseif tag == TAG_DATA
        0 < size <= DIRECTORY_CHUNK_BYTES || error("RemoteSync: invalid data chunk size $size")
    else
        error("RemoteSync: expected DATA or END, got $tag")
    end
    data = read(io, size)
    length(data) == size || throw(EOFError())
    return tag, data
end

function Base.eof(io::DeltaReader)
    io.pos <= length(io.buffer) && return false
    io.ended && return true
    tag, data = read_chunk(io.transport)
    io.buffer = data
    io.pos = 1
    io.ended = tag == TAG_END
    return io.ended
end

function Base.readbytes!(io::DeltaReader, dst::Vector{UInt8}, n::Integer = length(dst))
    length(dst) < n && resize!(dst, n)
    copied = 0
    while copied < n && !eof(io)
        count = min(n - copied, length(io.buffer) - io.pos + 1)
        copyto!(dst, copied + 1, io.buffer, io.pos, count)
        io.pos += count
        copied += count
    end
    return copied
end

function send_streamed_directory(root, transport, manifest, work; on_progress)
    sizes = Dict(e.rel => e.size for e in manifest)
    # Reused across all full files, including small files. Allocating a 1 MiB
    # work buffer per 4 KiB file would defeat the small-file fast path.
    buffer = isempty(work) ? UInt8[] : Vector{UInt8}(undef, DIRECTORY_CHUNK_BYTES)
    for (i, p) in pairs(work)
        rel = safe_rel(root, p.rel)
        rel === nothing && error("RemoteSync sender: unsafe plan path $(repr(p.rel))")
        haskey(sizes, rel) || error("RemoteSync sender: plan names a file outside the manifest")
        file = joinpath(root, rel)
        UInt64(filesize(file)) == sizes[rel] || error("RemoteSync: source changed during sync: $rel")
        notify_progress(on_progress, :file_start,
                        (rel, idx = i, total = length(work), action = p.action == ACTION_FULL ? :full : :patch))
        if p.action == ACTION_FULL && sizes[rel] <= SMALL_FILE_BYTES
            n = open(io -> readbytes!(io, buffer, Int(sizes[rel])), file)
            n == sizes[rel] || error("RemoteSync: source truncated during sync: $rel")
            write_frame(transport, TAG_LITERAL, encode_delta_frame(rel, view(buffer, 1:n)))
        else
            write_frame(transport, TAG_STREAM, Vector{UInt8}(codeunits(rel)))
            if p.action == ACTION_FULL
                sent = UInt64(0)
                open(file) do io
                    while sent < sizes[rel]
                        n = readbytes!(io, buffer, Int(min(sizes[rel] - sent, DIRECTORY_CHUNK_BYTES)))
                        n > 0 || error("RemoteSync: source truncated during sync: $rel")
                        write_frame(transport, TAG_DATA, view(buffer, 1:n))
                        sent += n
                    end
                    eof(io) || error("RemoteSync: source grew during sync: $rel")
                end
            else
                out = DeltaWriter(transport)
                open(file) do io
                    compute_delta(IOBuffer(p.sig), io, out)
                end
                flush(out)
            end
            write_frame(transport, TAG_END)
        end
        notify_progress(on_progress, :file_done, (rel, idx = i, total = length(work)))
    end
    write_frame(transport, TAG_DONE)
    tag, payload = read_frame(transport)
    tag == TAG_OK && isempty(payload) || error("RemoteSync: missing final transfer acknowledgement")
    notify_progress(on_progress, :transfer_done, (files = length(manifest),))
    return nothing
end

function receive_streamed_entry(root, transport, p::PlanEntry, entry::ManifestEntry)
    tag = read(transport, UInt8)
    size = Int(ltoh(read(transport, UInt32)))
    # STREAM is only a path; LITERAL has a path plus at most one small file.
    # A peer cannot smuggle a whole-file allocation into either message.
    0 <= size <= SMALL_FILE_BYTES + sizeof(UInt32) + ncodeunits(p.rel) ||
        error("RemoteSync: oversized file header")
    payload = read(transport, size)
    length(payload) == size || throw(EOFError())
    literal = UInt8[]
    rel = if tag == TAG_LITERAL
        p.action == ACTION_FULL || error("RemoteSync: literal received for a patch")
        path, data = decode_delta_frame(payload)
        length(data) == entry.size || error("RemoteSync: literal size mismatch")
        literal = data
        path
    elseif tag == TAG_STREAM
        String(payload)
    else
        error("RemoteSync: expected LITERAL or STREAM, got $tag")
    end
    rel == p.rel || error("RemoteSync: file order mismatch")
    sr = safe_rel(root, rel)
    sr === nothing && error("RemoteSync: unsafe file path")
    dst = joinpath(root, sr)
    mkpath(dirname(dst))
    partial = dst * ".partial"
    try
        open(partial, "w") do out
            if tag == TAG_LITERAL
                write(out, literal)
            elseif p.action == ACTION_FULL
                received = UInt64(0)
                while true
                    part, data = read_chunk(transport)
                    part == TAG_END && break
                    received += length(data)
                    received <= entry.size || error("RemoteSync: streamed file exceeds manifest size")
                    write(out, data)
                end
            else
                delta = DeltaReader(transport)
                open(dst) do basis
                    apply_patch(basis, delta, out)
                end
                eof(delta) || error("RemoteSync: trailing delta bytes")
            end
            position(out) == entry.size || error("RemoteSync: streamed file size mismatch")
        end
        mv(partial, dst; force = true)
    catch
        # Cleanup only our incomplete output; the previous destination survives.
        isfile(partial) && rm(partial; force = true)
        rethrow()
    end
    touch_mtime(dst, entry.mtime)
    return nothing
end
