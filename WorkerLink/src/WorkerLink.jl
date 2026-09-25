"""
    WorkerLink

One connection between a worker and the server, carrying any number of
channels. Each channel behaves like a websocket (messages, text or binary, clean
close or abort) and has its own flow control, so a slow reader stalls only its
own channel. The writer sends by channel priority in ≤64 KiB pieces, so control
traffic is never stuck behind a file transfer. A dropped connection detaches the
link instead of ending it: reconnecting within the grace period resumes every
channel where it was, without losing or repeating a message.
"""
module WorkerLink

using HTTP: WebSockets

include("frames.jl")
include("transport.jl")
include("link.jl")
include("channel.jl")
include("handshake.jl")

export Link, LinkChannel, open_channel, control_channel, abort, disconnect!, kill!,
       connect!, read_hello, welcome!, refuse, Hello,
       Transport, WebSocketTransport, MemoryTransport, memory_pair,
       LinkDead, LinkRefused, ProtocolError

end # module WorkerLink
