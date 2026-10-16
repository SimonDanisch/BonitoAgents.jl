# Length-prefixed framing on top of a single bidirectional IO. All multi-byte
# integers are little-endian. We never use Julia's stdlib Serialization because
# both ends might run different Julia versions and the format is fragile;
# instead each frame type has a hand-rolled, version-tolerant decoder.

# Frame layout: [tag::UInt8] [length::UInt32 LE] [payload::length bytes]
#
# Tags (one byte, free room to grow):
const TAG_MANIFEST    = 0x01    # sender → receiver: list of source files
const TAG_PLAN        = 0x02    # receiver → sender: per-file action + signature
const TAG_DELTA       = 0x03    # sender → receiver: delta payload for one file
const TAG_DONE        = 0x04    # sender → receiver: end-of-stream
const TAG_OK          = 0x05    # receiver → sender: file applied OK
const TAG_PROGRESS    = 0x06    # either direction: human-readable status string
const TAG_LITERAL     = 0x07    # small new file: rel + literal bytes
const TAG_STREAM      = 0x08    # streamed file starts: rel (action comes from plan)
const TAG_DATA        = 0x09    # bounded literal / librsync delta chunk
const TAG_END         = 0x0a    # streamed file ends

# Old decoders stop after the declared entry count, so a trailer negotiates an
# extension without making old peers parse a new message type. A new sender
# uses streaming ONLY when the receiver echoes this capability in its plan.
const STREAM_FEATURE = UInt32(0x31535242)

function has_stream_feature(io::IOBuffer)
    bytesavailable(io) == sizeof(UInt32) || return false
    return ltoh(read(io, UInt32)) == STREAM_FEATURE
end
# Single-file streaming protocol (used by send_file/receive_file). Independent
# of the manifest/delta protocol so a transport carries either one transfer or
# the other, never mixed.
const TAG_FILE_HEADER = 0x10    # payload: [size::UInt64][mtime::Float64]
const TAG_FILE_CHUNK  = 0x11    # payload: chunk bytes
const TAG_FILE_END    = 0x12    # payload: empty

# Action codes inside a Plan entry:
const ACTION_SKIP   = 0x00   # file matches, do nothing
const ACTION_FULL   = 0x01   # receiver has nothing — send literal contents
const ACTION_PATCH  = 0x02   # receiver sent a signature, send a delta against it
const ACTION_DELETE = 0x03   # receiver should delete this file

# Hard cap on a single frame's payload (R3). A hostile or garbled peer can put
# any 32-bit length in the prefix; without a cap, `read(io, len)` would try to
# allocate up to 4 GiB on the spot. 256 MiB comfortably exceeds our largest
# real frame (a 1 MiB file chunk, or a manifest/plan for a big tree) while
# making a length-prefix DoS impossible. Sub-lengths inside a payload
# (manifest/plan rel-lengths, signature lengths) are equally untrusted, so the
# decoders validate each against the bytes actually remaining.
const MAX_FRAME_BYTES = 256 * 1024 * 1024

# ── Low-level frame IO ─────────────────────────────────────────────────────
function write_frame(io::IO, tag::UInt8, payload::AbstractVector{UInt8})
    length(payload) > MAX_FRAME_BYTES &&
        error("RemoteSync: frame payload too large ($(length(payload)) bytes > $(MAX_FRAME_BYTES) cap)")
    write(io, tag)
    write(io, htol(UInt32(length(payload))))
    isempty(payload) || write(io, payload)
    flush(io)
    return nothing
end

write_frame(io::IO, tag::UInt8) = write_frame(io, tag, UInt8[])

# Returns (tag, payload). Throws EOFError on clean EOF mid-frame, or an error if
# the peer announces a payload larger than `MAX_FRAME_BYTES` (R3) — we refuse to
# allocate it.
function read_frame(io::IO)
    tag = read(io, UInt8)
    len = Int(ltoh(read(io, UInt32)))
    len > MAX_FRAME_BYTES &&
        error("RemoteSync: peer announced oversized frame ($(len) bytes > $(MAX_FRAME_BYTES) cap)")
    payload = len == 0 ? UInt8[] : read(io, len)
    length(payload) == len ||
        throw(EOFError())
    return (tag, payload)
end

# Read a wire-supplied sub-length and reject it if it exceeds the bytes left in
# `io` (an IOBuffer over a single frame's payload). Stops a crafted inner length
# from driving a huge `read(io, n)` allocation inside the decoders (R3).
function read_sublen(io::IOBuffer)
    n = Int(ltoh(read(io, UInt32)))
    n < 0 && error("RemoteSync: negative sub-length")
    n > bytesavailable(io) &&
        error("RemoteSync: sub-length $(n) exceeds remaining frame bytes $(bytesavailable(io))")
    return n
end

# ── Manifest encoding ──────────────────────────────────────────────────────
# Manifest entries are (relpath, size, mtime). mtime is Float64 seconds since
# Unix epoch (matches stat().mtime).
struct ManifestEntry
    rel   :: String
    size  :: UInt64
    mtime :: Float64
end

function encode_manifest(entries::Vector{ManifestEntry}; streaming::Bool = false)
    io = IOBuffer()
    write(io, htol(UInt32(length(entries))))
    for e in entries
        bytes = codeunits(e.rel)
        write(io, htol(UInt32(length(bytes))))
        write(io, bytes)
        write(io, htol(e.size))
        write(io, htol(reinterpret(UInt64, e.mtime)))
    end
    streaming && write(io, htol(STREAM_FEATURE))
    return take!(io)
end

function decode_manifest(payload::AbstractVector{UInt8}; with_features::Bool = false)
    io = IOBuffer(payload)
    n = Int(ltoh(read(io, UInt32)))
    # The entry count is attacker-controlled; each entry consumes >= 4 bytes, so
    # a count larger than the remaining bytes can't be real. Refuse before
    # `Vector{}(undef, n)` over-allocates (R3).
    n > bytesavailable(io) &&
        error("RemoteSync: manifest entry count $(n) exceeds frame bytes")
    out = Vector{ManifestEntry}(undef, n)
    for i in 1:n
        rel_len = read_sublen(io)
        rel     = String(read(io, rel_len))
        size    = ltoh(read(io, UInt64))
        mtime   = reinterpret(Float64, ltoh(read(io, UInt64)))
        out[i]  = ManifestEntry(rel, size, mtime)
    end
    return with_features ? (out, has_stream_feature(io)) : out
end

# ── Plan encoding ──────────────────────────────────────────────────────────
# A Plan is the receiver's response: for each file in the manifest (and any
# extra deletes), what action does the sender need to take, and (for PATCH)
# the signature bytes the sender should compute the delta against.
struct PlanEntry
    rel    :: String
    action :: UInt8
    sig    :: Vector{UInt8}    # only populated when action == ACTION_PATCH
end

function encode_plan(entries::Vector{PlanEntry}; streaming::Bool = false)
    io = IOBuffer()
    write(io, htol(UInt32(length(entries))))
    for e in entries
        bytes = codeunits(e.rel)
        write(io, htol(UInt32(length(bytes))))
        write(io, bytes)
        write(io, e.action)
        write(io, htol(UInt32(length(e.sig))))
        isempty(e.sig) || write(io, e.sig)
    end
    streaming && write(io, htol(STREAM_FEATURE))
    return take!(io)
end

function decode_plan(payload::AbstractVector{UInt8}; with_features::Bool = false)
    io = IOBuffer(payload)
    n = Int(ltoh(read(io, UInt32)))
    n > bytesavailable(io) &&
        error("RemoteSync: plan entry count $(n) exceeds frame bytes")
    out = Vector{PlanEntry}(undef, n)
    for i in 1:n
        rel_len = read_sublen(io)
        rel     = String(read(io, rel_len))
        action  = read(io, UInt8)
        sig_len = read_sublen(io)
        sig     = sig_len == 0 ? UInt8[] : read(io, sig_len)
        out[i]  = PlanEntry(rel, action, sig)
    end
    return with_features ? (out, has_stream_feature(io)) : out
end

# ── Delta envelope ─────────────────────────────────────────────────────────
# DELTA frame = [rel_len::UInt32][rel bytes][delta bytes]. The frame's outer
# length tells us where the delta ends; the rel_len + rel give us the path.
function encode_delta_frame(rel::AbstractString, delta::AbstractVector{UInt8})
    io = IOBuffer()
    bytes = codeunits(rel)
    write(io, htol(UInt32(length(bytes))))
    write(io, bytes)
    write(io, delta)
    return take!(io)
end

function decode_delta_frame(payload::AbstractVector{UInt8})
    io = IOBuffer(payload)
    rel_len = read_sublen(io)
    rel     = String(read(io, rel_len))
    delta   = read(io)
    return (rel, delta)
end
