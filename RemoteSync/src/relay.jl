# Copy one logical frame without assembling its entire payload. In particular,
# an old peer's whole-file DELTA may arrive across hundreds of WS messages.
function relay_frame(source::IO, destination::IO, buffer::Vector{UInt8})
    tag = read(source, UInt8)
    size = Int(ltoh(read(source, UInt32)))
    size <= MAX_FRAME_BYTES || error("RemoteSync: oversized relayed frame")
    write(destination, tag)
    write(destination, htol(UInt32(size)))
    remaining = size
    while remaining > 0
        n = min(remaining, length(buffer))
        readbytes!(source, buffer, n) == n || throw(EOFError())
        write(destination, view(buffer, 1:n))
        flush(destination)
        remaining -= n
    end
    flush(destination)
    return tag
end

"""
    relay_directory(source, destination; on_progress = nothing)

Relay a directory sync between two bidirectional streams without a disk mirror.
The destination's manifest plan reaches the source directly, so deltas use the
actual destination as their basis. Payload buffering is bounded to one chunk.
Returns `(files, bytes, written, deleted, skipped)`; the destination controls
deletions. Legacy receivers have no final acknowledgement: callers must also
wait for their successful transport close before reporting success.
"""
function relay_directory(source::IO, destination::IO; on_progress = nothing)
    tag, payload = read_frame(source)
    tag == TAG_MANIFEST || error("RemoteSync relay: expected MANIFEST")
    manifest, sender_streaming = decode_manifest(payload; with_features = true)
    write_frame(destination, tag, payload)
    notify_progress(on_progress, :manifest_received, (count = length(manifest),))

    tag, payload = read_frame(destination)
    tag == TAG_PLAN || error("RemoteSync relay: expected PLAN")
    plan, receiver_streaming = decode_plan(payload; with_features = true)
    streaming = sender_streaming && receiver_streaming
    write_frame(source, tag, payload)
    work = count(p -> p.action == ACTION_FULL || p.action == ACTION_PATCH, plan)
    notify_progress(on_progress, :plan_received, (planned = length(plan), work))
    buffer = Vector{UInt8}(undef, DIRECTORY_CHUNK_BYTES)
    if streaming
        while true
            tag = relay_frame(source, destination, buffer)
            tag == TAG_DONE && break
            tag in (TAG_LITERAL, TAG_STREAM, TAG_DATA, TAG_END) ||
                error("RemoteSync relay: unexpected streaming frame $tag")
        end
        tag, payload = read_frame(destination)
        tag == TAG_OK || error("RemoteSync relay: missing final acknowledgement")
        write_frame(source, tag, payload)
    else
        for _ in 1:work
            relay_frame(source, destination, buffer) == TAG_DELTA ||
                error("RemoteSync relay: expected DELTA")
            tag, payload = read_frame(destination)
            tag == TAG_OK || error("RemoteSync relay: missing file acknowledgement")
            write_frame(source, tag, payload)
        end
        relay_frame(source, destination, buffer) == TAG_DONE ||
            error("RemoteSync relay: expected DONE")
    end
    # Worker destinations are additive. The plan may name extraneous files but
    # the worker never deletes them, so do not count ACTION_DELETE as deletion.
    result = (files = length(manifest), bytes = sum(e.size for e in manifest; init = UInt64(0)),
              written = work, deleted = 0, skipped = count(p -> p.action == ACTION_SKIP, plan))
    notify_progress(on_progress, :transfer_done, result)
    return result
end
