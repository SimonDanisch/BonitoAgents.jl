module RemoteSync

# Streaming, transport-agnostic rsync over librsync's job API. Three layers:
#
#   librsync.jl     — ccall bindings + the rs_job_iter drive loop
#   primitives.jl   — IO-based compute_signature / compute_delta / apply_patch
#   wire.jl         — length-prefixed frame format for the directory protocol
#   sync.jl         — send_directory / receive_directory orchestration
#   websocketio.jl  — IO-like adapter over HTTP.WebSocket (registered lazily)
#
# All functions are designed to compose with arbitrary IO objects so the same
# code path is exercised by unit tests (IOBuffer pipes) and production
# (WebSocketIO over a Bonito /transfer-ws route).

include("librsync.jl")
include("primitives.jl")
include("wire.jl")
include("sync.jl")
include("streaming.jl")
include("relay.jl")
include("websocketio.jl")

export compute_signature, compute_delta, apply_patch, full_signature_bytes,
       send_directory, receive_directory, relay_directory, walk_directory,
       send_file, receive_file,
       WebSocketIO, wait_peer_close, LibrsyncError
# `ManifestEntry` and `PlanEntry` are accessed as `RemoteSync.ManifestEntry`
# etc. — kept unexported to avoid clashing with AgentClientProtocol.PlanEntry.

function __init__()
    _init_basis_copy_cb()
    return nothing
end

end # module RemoteSync
