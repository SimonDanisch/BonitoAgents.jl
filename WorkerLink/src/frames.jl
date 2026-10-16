# ── Frames ──────────────────────────────────────────────────────────────────
# Every websocket message on a link is exactly one frame:
#
#     [kind u8][flags u8][channel u32][seq u64][payload]      (little endian)
#
# SEQUENCED frames (kind < 0x10) are numbered per direction, kept until the
# peer acknowledges them, and replayed after a reconnect — that is what lets a
# channel survive a dropped connection without losing or repeating anything.
# CONNECTION frames belong to one transport and die with it.

const F_OPEN   = 0x01   # payload: [priority u8][opener's header bytes]
const F_DATA   = 0x02   # payload: message bytes (a whole message or a piece of one)
const F_CLOSE  = 0x03   # the sender is done with the channel
const F_ABORT  = 0x04   # payload: reason (UTF-8); the channel is dead both ways
const F_CREDIT = 0x05   # payload: u64 bytes the receiver will accept on top

const F_ACK  = 0x10     # seq field: highest sequenced frame received in order
const F_PING = 0x11
const F_PONG = 0x12

is_sequenced(kind::UInt8) = kind < 0x10

# DATA flags
const FLAG_EOM  = 0x01  # last piece of a message
const FLAG_TEXT = 0x02  # the message is text (receive returns a String)

const HEADER_BYTES = 14

struct Frame
    kind::UInt8
    flags::UInt8
    channel::UInt32
    seq::UInt64
    payload::Vector{UInt8}
end

Frame(kind::UInt8, channel::Integer; flags::UInt8 = 0x00, seq::Integer = 0,
      payload::Vector{UInt8} = UInt8[]) =
    Frame(kind, flags, UInt32(channel), UInt64(seq), payload)

"Protocol violations: a bug on one side, never a network condition."
struct ProtocolError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ProtocolError) = print(io, "WorkerLink protocol error: ", e.msg)

function encode(f::Frame)
    out = Vector{UInt8}(undef, HEADER_BYTES + length(f.payload))
    out[1] = f.kind
    out[2] = f.flags
    copyto!(out, 3, reinterpret(UInt8, [htol(f.channel)]), 1, 4)
    copyto!(out, 7, reinterpret(UInt8, [htol(f.seq)]), 1, 8)
    copyto!(out, HEADER_BYTES + 1, f.payload, 1, length(f.payload))
    return out
end

function decode(bytes::AbstractVector{UInt8})
    length(bytes) >= HEADER_BYTES ||
        throw(ProtocolError("frame of $(length(bytes)) bytes is shorter than the header"))
    channel = ltoh(reinterpret(UInt32, bytes[3:6])[1])
    seq     = ltoh(reinterpret(UInt64, bytes[7:14])[1])
    return Frame(bytes[1], bytes[2], channel, seq, bytes[(HEADER_BYTES + 1):end])
end

u64_bytes(n::Integer) = collect(reinterpret(UInt8, [htol(UInt64(n))]))

function read_u64(bytes::AbstractVector{UInt8}, at::Int = 1)
    length(bytes) >= at + 7 || throw(ProtocolError("truncated u64"))
    return ltoh(reinterpret(UInt64, bytes[at:(at + 7)])[1])
end
