# Embed an interactive Bonito App that lives in a worker eval process into a host
# browser Session by piping the Bonito protocol RAW over the worker's dial-back
# websocket. The worker renders + owns the observables; the BonitoAgents server is a
# byte relay between that socket and the browser, plus the one server-side asset
# mirror (the browser fetches assets over HTTP). There is NO Malt on the frame
# path — every Bonito frame is just bytes on the websocket, both directions. Malt
# (via BonitoMCP's own link to its workers) is used ONLY to bootstrap the worker:
# include RemoteProxy, build the bridge, start the dial. See BonitoMCP/RemoteProxy.jl.
#
# Wire format on the dial-back WS: `[tag][payload]`.
#   * `D` (data)    — a Bonito frame, piped verbatim (worker→browser and back).
#   * `C` (control) — a small msgpack dict for the few request/response ops:
#                     `asset_read` (lazy range fetch), `asset_url` (expose a
#                     worker-disk file as a streamable asset), `close` (a
#                     subsession), and the worker→host `asset_add`/`asset_remove` push.

const Malt = BonitoMCP.Malt   # only the BonitoMCP-side bootstrap touches Malt

const TAG_DATA = UInt8('D')
const TAG_CTRL = UInt8('C')

# One per worker process (keyed by project). Owns the dial-back socket, the stable
# per-worker asset registry (a `ChildAssetServer` of the dashboard's one
# `HTTPAssetServer`, so proxied assets outlive any transient render session), the
# pending control-request table, and the current browser root connection that
# worker→browser frames relay onto.
mutable struct EvalBridge
    prefix::String                       # bridge parent.id == route_to_remote namespace
    ws::Any                              # dial-back websocket; swapped on reconnect under wlock
    wlock::ReentrantLock                 # serialize frame sends to the worker AND ws-swap
    asset_host::Bonito.ChildAssetServer
    pending::Dict{Int, Channel{Any}}     # control req-id → reply channel
    pending_lock::ReentrantLock
    reqid::Threads.Atomic{Int}
    root_conn::Base.RefValue{Any}        # current browser root connection (worker→browser target)
    # Worker→browser frames that arrived while NO browser connection was
    # attached (the dial-back → first-mount window, or a tab-switch gap).
    # Dropping them silently was the root cause of the "plot spinner never
    # finishes" hang: glyph batches at eval time, session init bundles — all
    # gone with no retry. Parked frames flush IN ORDER on the next attach /
    # reconnect (`flush_parked!`); the byte-cap keeps a never-mounted chat from
    # holding unbounded memory (overflow drops OLDEST first, with a warn —
    # the subsession pull/re-mount paths recover from that).
    parked::Vector{Vector{UInt8}}
    parked_bytes::Int
    parked_lock::ReentrantLock
    # Per-bridge host-side wiring. FIELDS, not module-global state keyed by
    # this bridge's prefix: it belongs to ONE bridge and dies with it
    # (`clear_bridge_wiring!` empties it).
    attached_roots::Set{String}          # root.id of every tab this bridge is wired to (attach-once guard)
    wire_lock::ReentrantLock             # guards attached_roots
end

const PARKED_BYTE_CAP = 64 * 1024 * 1024  # 64 MB per bridge

# Reconnects compare prefix (== BRIDGE[].parent.id on the worker): same prefix
# means same BRIDGE[] / same routes, swap WS; different prefix means worker
# restart, hard-replace. `ws === nothing` ⇒ disconnected, awaiting redial.
make_eval_bridge(prefix::AbstractString, ws, host) = EvalBridge(
    String(prefix), ws, ReentrantLock(), host,
    Dict{Int,Channel{Any}}(), ReentrantLock(),
    Threads.Atomic{Int}(0), Base.RefValue{Any}(nothing),
    Vector{Vector{UInt8}}(), 0, ReentrantLock(),
    Set{String}(), ReentrantLock())

# Park a worker→browser frame until a browser connection attaches. Overflow
# drops the OLDEST frames: the newest ones are the likeliest to matter (the
# most recent snapshot/bundle), and the pull/re-mount paths heal older losses.
function park_frame!(eb::EvalBridge, payload::Vector{UInt8})
    lock(eb.parked_lock) do
        push!(eb.parked, payload)
        eb.parked_bytes += length(payload)
        dropped = 0
        while eb.parked_bytes > PARKED_BYTE_CAP && length(eb.parked) > 1
            old = popfirst!(eb.parked)
            eb.parked_bytes -= length(old)
            dropped += 1
        end
        dropped == 0 ||
            @warn "eval relay: parked-frame cap hit; dropped oldest frames" dropped prefix = eb.prefix maxlog = 5
    end
    return
end

# Flush parked frames IN ORDER to `rc`. Failures re-park the remainder (the
# connection died mid-flush; the next attach retries).
function flush_parked!(eb::EvalBridge, rc)
    rc === nothing && return
    lock(eb.parked_lock) do
        isempty(eb.parked) && return
        n = length(eb.parked)
        while !isempty(eb.parked)
            payload = eb.parked[1]
            try
                write(rc, payload)
            catch e
                @warn "eval relay: parked-frame flush failed; keeping remainder for next attach" exception = (e,) remaining = length(eb.parked) prefix = eb.prefix
                return
            end
            popfirst!(eb.parked)
            eb.parked_bytes -= length(payload)
        end
        @info "eval relay: flushed parked frames to browser" frames = n prefix = eb.prefix
    end
    return
end

# Read an eval bridge for `project_id` under `state.lock` (T11). Writers
# (`handle_eval_ws`, `teardown_eval_bridge!`) mutate `state.eval_workers` under the
# same lock, so UI tasks that just `get(state.eval_workers, …)` raced a concurrent
# insert/delete (Dict rehash). All reads go through here.
eval_bridge_for(state::ServerState, project_id::AbstractString) =
    lock(state.lock) do
        get(state.eval_workers, String(project_id), nothing)
    end

# ── Raw frame transport to the worker ───────────────────────────────────────
function send_tagged(eb::EvalBridge, tag::UInt8, payload::AbstractVector{UInt8})
    buf = Vector{UInt8}(undef, length(payload) + 1)
    @inbounds buf[1] = tag
    copyto!(buf, 2, payload, firstindex(payload), length(payload))
    lock(eb.wlock) do
        ws = eb.ws
        # Bridge torn down (worker session ended / restart!): `ws === nothing` — a
        # late browser→worker frame has nowhere to go. Drop it silently; without
        # this guard `send(::Nothing, …)` throws a MethodError that the catch turns
        # into a scary "frame send failed" warning on every teardown frame.
        ws === nothing && return
        try
            HTTP.WebSockets.send(ws, buf)
        catch e
            # The expected failure here is a send racing the dial-back socket
            # dropping/swapping. Anything else is real signal — `@debug` would
            # silently hide it (default log level Info), so `@warn` so the
            # actual exception type/message is visible during diagnosis.
            @warn "eval bridge: frame send failed" exception = (e, catch_backtrace()) tag = Char(tag) bytes = length(buf) prefix = eb.prefix
        end
    end
    return nothing
end
send_data(eb::EvalBridge, bytes::AbstractVector{UInt8}) = send_tagged(eb, TAG_DATA, bytes)
send_ctrl(eb::EvalBridge, dict)                         = send_tagged(eb, TAG_CTRL, Bonito.MsgPack.pack(dict))

# EvalBridge is the host-side proxy driver for Bonito's proxy framework: Bonito
# routes browser→worker frames through `proxy_forward`, and serves proxied asset
# byte ranges through `proxy_fetch`. We re-pack the DECODED frame as plain
# (uncompressed) msgpack so the worker's bridge — which runs uncompressed —
# handles it regardless of the browser connection's compression. `proxy_fetch`
# runs on the HTTP asset-handler task (not the relay loop), so its `call_ctrl`
# round-trip can't deadlock the relay.
Bonito.proxy_forward(eb::EvalBridge, data) = send_data(eb, Bonito.MsgPack.pack(data))
Bonito.proxy_fetch(eb::EvalBridge, key, start, stop) =
    ctrl_bytes(call_ctrl(eb, "asset_read"; key = key, start = start, stop = stop))

# Expose a worker-disk file to the browser as a streamable proxied asset and
# return its host-relative `/assets/<key>` url. Range reads are proxied on demand
# (no whole-file copy to the host), so a `<video src=…>` scrubs by pulling only
# the bytes it needs. Media wants a streamable url, not a Bonito session — so this
# is a plain url for a plain <img>/<video>, no App/subsession.
worker_asset_url(eb::EvalBridge, path::AbstractString) =
    String(call_ctrl(eb, "asset_url"; path = String(path)))

# A control request that expects a reply (asset_read / asset_url). The dial-back
# relay loop resolves it via `pending`; this runs on a DIFFERENT task (a chat
# command or an HTTP asset handler), so the wait can't deadlock the relay.
function call_ctrl(eb::EvalBridge, op::AbstractString; timeout = 30.0, redial_grace = 10.0, kw...)
    # Disconnected window (WS dropped, worker redialing): the worker's
    # dial_loop reconnects within a couple of seconds, so WAIT that window out
    # instead of failing instantly — an instant failure here was what left
    # fragments without their JS module (asset fetch during a redial → module
    # never loads → permanent spinner). Only error once the grace runs out.
    # `redial_grace = 0` restores fail-fast (tests, callers with own retry).
    if eb.ws === nothing
        deadline = time() + redial_grace
        while eb.ws === nothing && time() < deadline
            sleep(0.1)
        end
        eb.ws === nothing &&
            error("eval bridge disconnected (worker did not redial within $(redial_grace)s); '$op' not sent")
    end
    id = Threads.atomic_add!(eb.reqid, 1)
    ch = Channel{Any}(1)
    lock(eb.pending_lock) do; eb.pending[id] = ch; end
    send_ctrl(eb, Dict{String,Any}("op" => op, "id" => id,
                                   (String(k) => v for (k, v) in kw)...))
    try
        Base.timedwait(() -> isready(ch), timeout) === :ok || error("remote control '$op' timed out")
        result = take!(ch)
        # Worker-side handle_control sends back an `err` field on exception;
        # handle_worker_control wrapped it as an Exception. Rethrow so the
        # caller sees the failure right away rather than a malformed value.
        result isa Exception && throw(result)
        return result
    finally
        lock(eb.pending_lock) do; delete!(eb.pending, id); end
    end
end

# Bonito's MsgPack packs a `Vector{UInt8}` as a binary Extension, so byte payloads
# sent over the control channel come back wrapped — unwrap them.
ctrl_bytes(x) = x === nothing ? nothing :
                x isa Bonito.MsgPack.Extension ? Vector{UInt8}(x.data) : Vector{UInt8}(x)

# Worker→host control frame (runs on the relay loop task).
function handle_worker_control(eb::EvalBridge, msg::AbstractDict)
    op = msg["op"]
    if op == "reply"
        # `pop!` (not `get`) under the lock so exactly ONE side owns the channel
        # (T9). With a `get`, a concurrent `fail_pending!` could fill the
        # capacity-1 channel first and this `put!` would then block the relay
        # loop forever. Popping means whichever of {reply, fail_pending!} gets
        # the entry first is the sole writer; the other finds it gone.
        ch = lock(eb.pending_lock) do
            id = Int(msg["id"])
            haskey(eb.pending, id) ? pop!(eb.pending, id) : nothing
        end
        # Worker can reply with `err` (string showerror) instead of `val` when
        # `handle_control` raised. Surface as an Exception so `call_ctrl` throws
        # immediately — no 30 s timedwait, no swallowed failures. The `put!` is
        # safe (we own the channel) but the caller may have already given up
        # (closed it) on timeout — that's not an error.
        if ch !== nothing
            try
                put!(ch,
                    haskey(msg, "err") ? ErrorException(String(msg["err"])) :
                                         get(msg, "val", nothing))
            catch e
                e isa InvalidStateException || rethrow()
            end
        end
    elseif op == "asset_add"
        k = String(msg["key"])
        cached = ctrl_bytes(msg["cached"])
        # Non-eager assets are fetched lazily via `proxy_fetch(eb, …)` on the HTTP
        # asset-handler task (never this relay loop), so no deadlock.
        Bonito.register_proxy_asset!(eb.asset_host,
            Bonito.RemoteAsset(k, String(msg["mime"]), Int(msg["total"]), cached, eb))
    elseif op == "asset_remove"
        Bonito.release_proxy_asset!(eb.asset_host, String(msg["key"]))
    end
    return
end

# Fail every in-flight `call_ctrl` waiting on this bridge with a clean error —
# called when the WS drops, so callers don't sit on a 30 s timeout for replies
# that physically can't come back over the dead socket.
function fail_pending!(eb::EvalBridge, why::AbstractString)
    drained = lock(eb.pending_lock) do
        pp = collect(values(eb.pending))
        empty!(eb.pending)
        pp
    end
    err = ErrorException(why)
    for ch in drained
        isready(ch) || put!(ch, err)
    end
    return nothing
end

# `/eval-ws` handler. Handshake is "secret project_id prefix"; after that the
# socket is a raw Bonito frame pipe. This task IS the worker→browser relay (and
# the worker→host control reader) for the bridge's whole lifetime.
# Process one inbound frame from the worker: DATA → queue for the browser (so a
# slow browser can't block the relay loop); CTRL → handle inline (reply routing +
# asset register, all fast). Extracted so the decoupling is unit-testable.
function relay_frame!(eb::EvalBridge, outbound::Channel{Vector{UInt8}}, data::AbstractVector{UInt8})
    isempty(data) && return nothing
    tag = @inbounds data[1]
    payload = @view data[2:end]
    if tag == TAG_DATA
        isopen(outbound) && put!(outbound, Vector{UInt8}(payload))
    elseif tag == TAG_CTRL
        handle_worker_control(eb, Bonito.MsgPack.unpack(Vector{UInt8}(payload)))
    end
    return nothing
end

# Drain queued worker→browser frames to the current root connection, IN ORDER, on
# a dedicated task — so a slow `write` stalls only this writer, never the relay
# loop's control-frame handling.
#
# A `write(rc, payload)` failure means a worker→browser frame is dropped — and
# dropping frames mid-render is exactly what produces "the plot loaded the
# initial bundle but live updates never arrive" symptoms (the worker side sees
# clean sends, the browser-side console sees nothing, and nothing's logged
# because the original code only `@debug`'d the failure). Promote to `@warn`
# so the actual exception is visible AND emit a one-shot info as soon as the
# first frame after a failure DOES go through, so the recovery (tab reload,
# WS swap, etc.) is also visible.
function relay_writer(eb::EvalBridge, outbound::Channel{Vector{UInt8}})
    just_failed = false
    for payload in outbound
        rc = eb.root_conn[]
        if rc === nothing
            # No browser connection attached (dial-back → first-mount window,
            # tab switch, reload). PARK the frame — dropping here was the root
            # cause of the permanent plot spinner (lost init bundles / glyph
            # batches with no retry). `flush_parked!` delivers them in order on
            # the next attach/reconnect.
            just_failed || (@info "eval relay: no browser connection — frame parked" prefix = eb.prefix)
            just_failed = true
            park_frame!(eb, payload)
            continue
        end
        # Ordering: anything parked must go out before this frame. If the flush
        # couldn't complete (connection died mid-flush), park this frame behind
        # the remainder instead of overtaking it.
        flush_parked!(eb, rc)
        if lock(() -> !isempty(eb.parked), eb.parked_lock)
            park_frame!(eb, payload)
            just_failed = true
            continue
        end
        try
            write(rc, payload)
            if just_failed
                @info "eval relay: browser write recovered" prefix = eb.prefix
                just_failed = false
            end
        catch e
            # The connection died under us: park this frame too — the next
            # attach (re-mount, reconnect) delivers it instead of losing it.
            @warn "eval relay: browser write failed (frame parked for next attach)" exception = (e, catch_backtrace()) bytes = length(payload) prefix = eb.prefix
            park_frame!(eb, payload)
            just_failed = true
        end
    end
    return nothing
end

# A short, non-reversible fingerprint of a secret — lets two log lines be
# compared ("worker sent <x>, server expects <y>") without ever printing the
# secret itself. Matches the sha8 form the diagnosing agent expected.
secret_fingerprint(s::AbstractString) = isempty(s) ? "<empty>" : bytes2hex(SHA.sha256(s))[1:8]

function handle_eval_ws(state::ServerState, ws)
    line = try; String(HTTP.WebSockets.receive(ws)); catch e
        @warn "eval dial-back rejected: handshake never arrived" exception=e; return
    end
    parts = split(strip(line), ' '; limit = 3)
    # Self-diagnosing: split the lumped "bad handshake" into the real reason so a
    # rejection is one log line, not a detective hunt. Expected: "secret project_id prefix".
    if length(parts) != 3
        @warn "eval dial-back rejected: malformed handshake (expected 3 fields 'secret project_id prefix')" got_fields=length(parts) project_id=(length(parts) ≥ 2 ? String(parts[2]) : "") has_prefix=(length(parts) ≥ 3 && !isempty(parts[3]))
        return
    end
    if parts[1] != state.worker_secret
        @warn "eval dial-back rejected: secret MISMATCH — worker dialed with a different secret than the server expects (stale env / server restarted with a new secret / port reused)" worker_secret=secret_fingerprint(parts[1]) server_secret=secret_fingerprint(state.worker_secret) project_id=String(parts[2])
        return
    end
    project_id = String(parts[2]); prefix = String(parts[3])
    if isempty(prefix)
        @warn "eval dial-back rejected: empty bridge prefix (worker RemoteProxy bridge setup failed)" project_id
        return
    end
    if state.srv === nothing
        @warn "eval dial-back with no live server — cannot proxy assets"; return
    end

    # Existing dial for this project? Decide reconnect vs. replace by comparing
    # `prefix` against `BRIDGE[].parent.id` on the worker side. Same prefix ⇒
    # same `BRIDGE[]` (routes intact) ⇒ swap WS into the existing EvalBridge.
    # Different prefix ⇒ worker restarted ⇒ stale routes, hard-replace.
    #
    # The get-and-install is done under `state.lock` so it's atomic w.r.t.
    # `teardown_eval_bridge!` (which mutates state.eval_workers under the same lock) —
    # otherwise a concurrent teardown could delete the entry between our read and
    # write. The heavy cleanup (fail_pending, asset-host close, wiring clear) is
    # disjoint by prefix from the fresh bridge, so we do it AFTER releasing the
    # lock rather than holding it across those other locks.
    eb, to_fail, to_retire = lock(state.lock) do
        existing = get(state.eval_workers, project_id, nothing)
        if existing !== nothing && existing.prefix == prefix
            @info "eval worker reconnected" project_id prefix
            lock(existing.wlock) do; existing.ws = ws; end
            (existing, existing, nothing)          # fail its orphaned pending below
        else
            fresh = make_eval_bridge(prefix, ws, Bonito.HTTPAssetServer(state.srv))
            state.eval_workers[project_id] = fresh
            @info "eval worker dialed back (ws) — raw bridge installed" project_id prefix
            (fresh, nothing, existing)             # retire the old (different-prefix) bridge below
        end
    end
    to_fail === nothing ||
        fail_pending!(to_fail, "eval bridge reconnected; in-flight request dropped")
    if to_retire !== nothing
        @info "eval worker replaced (new prefix; worker restarted?)" project_id old_prefix = to_retire.prefix new_prefix = prefix
        # Old bridge is a dead worker process — fail orphans, drop its asset host,
        # and clear its host-side wiring so the fresh bridge re-attaches cleanly.
        fail_pending!(to_retire, "eval bridge replaced by a new worker; in-flight request dropped")
        try
            close(to_retire.asset_host)
        catch e
            @warn "eval bridge: asset_host close failed during worker-replace" exception = (e, catch_backtrace()) prefix = to_retire.prefix
        end
        clear_bridge_wiring!(to_retire)
    end

    # Worker→browser writes are DECOUPLED from this relay loop. The loop also
    # delivers control REPLIES (asset_read / asset_url), so a slow or CPU-bound
    # browser (WGLMakie, or headless software-WebGL) that drains its socket slowly
    # would otherwise block the loop on `write(rc, …)` and starve those replies →
    # 30s `call_ctrl` timeouts ("asset_read timed out" / stuck "loading…"). Data
    # frames go onto a bounded queue drained by a dedicated `relay_writer`; the
    # loop stays responsive to control frames regardless of browser speed. The
    # bound also back-pressures a runaway stream (a full queue blocks the loop —
    # degrading to the old behavior, never worse) so it can't grow without bound.
    outbound = Channel{Vector{UInt8}}(2048)
    writer = Base.errormonitor(@async relay_writer(eb, outbound))
    try
        for msg in ws
            # Per-frame guard: a single malformed/raising frame must NOT tear down
            # the whole relay (which would strand every pending control reply).
            try
                data = msg isa AbstractVector{UInt8} ? msg : Vector{UInt8}(codeunits(String(msg)))
                relay_frame!(eb, outbound, data)
            catch e
                @warn "eval dial-back: dropping bad frame" exception = (e, catch_backtrace())
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError || e isa Base.IOError || e isa EOFError ||
            @warn "eval dial-back relay loop ended" exception = (e, catch_backtrace())
    finally
        close(outbound)   # stop the writer task
        # WS dropped. Fail in-flight requests (no reply can arrive over a dead
        # socket) and mark the bridge disconnected so `call_ctrl` fails fast
        # instead of hanging the full timeout. We DON'T tear the bridge down here:
        # its lifetime is the eval worker's Julia session, not this socket. The
        # worker's `dial_loop` redials (same prefix → the reconnect branch swaps
        # the WS back in, routes + registered apps intact). Teardown happens only
        # with the worker session — see `teardown_eval_bridge!`. The identity
        # guard avoids clobbering a WS a concurrent reconnect already swapped in.
        fail_pending!(eb, "eval bridge WS dropped; awaiting redial")
        lock(eb.wlock) do
            eb.ws === ws && (eb.ws = nothing)
        end
    end
    return
end

# Clear a bridge's host-side wiring: its `attach_bridge_host!` attach-once guard
# — so a later bridge (same tab) re-attaches cleanly instead of
# short-circuiting on a stale attach tag.
function clear_bridge_wiring!(eb::EvalBridge)
    lock(eb.wire_lock) do
        empty!(eb.attached_roots)
    end
    # A retired bridge's parked frames belong to a dead worker session — drop them.
    lock(eb.parked_lock) do
        empty!(eb.parked)
        eb.parked_bytes = 0
    end
    return nothing
end

# Tear an eval bridge down — tied to the eval worker's Julia SESSION lifecycle,
# NOT to its dial-back socket (a WS drop just awaits redial; see handle_eval_ws's
# finally). Called from the normal project/worker teardown (`stop_session!`,
# worker disconnect): releases the proxied asset host, fails in-flight control
# requests, drops host-side wiring, and evicts from state.eval_workers. Idempotent.
function teardown_eval_bridge!(state::ServerState, project_id::AbstractString)
    eb = lock(state.lock) do
        e = get(state.eval_workers, project_id, nothing)
        e === nothing || delete!(state.eval_workers, project_id)
        e
    end
    eb === nothing && return nothing
    fail_pending!(eb, "eval bridge torn down (worker session ended)")
    # Don't swallow the asset-host close failure (T12) — mirror the sibling at
    # the worker-replace path which logs it. The bridge is being retired either
    # way, so we log and continue rather than abort the teardown.
    try
        close(eb.asset_host)
    catch e
        @warn "eval bridge: asset_host close failed during teardown" exception = (e, catch_backtrace()) prefix = eb.prefix
    end
    clear_bridge_wiring!(eb)
    @info "eval bridge torn down with worker session" project_id prefix = eb.prefix
    return nothing
end

# ── MCP-process control channel (/mcp-ws) ───────────────────────────────────
# The BonitoMCP stdio server (NOT its Malt eval worker) dials this back so the
# chat can interrupt an in-flight bt_julia_eval per tool — without cancelling
# the whole agent turn. Distinct from /eval-ws on purpose: the eval worker
# runs user code and can be too busy to service a control frame; the MCP
# process never runs user code and owns the reliable `Malt.interrupt` lever.
#
# Wire (JSON per WS message):
#   server → mcp:  {"op": "interrupt_eval", "request_id", "env_path"?}
#   mcp → server:  {"type": "interrupt_result", "request_id", "interrupted": n}
# Replies route through the same `pending_rpcs` machinery as worker RPCs.

mcp_ctrl_for(state::ServerState, project_id::AbstractString) =
    lock(state.lock) do
        get(state.mcp_ctrl, String(project_id), nothing)
    end

function handle_mcp_ctrl_ws(state::ServerState, ws)
    line = try; String(HTTP.WebSockets.receive(ws)); catch; return; end
    parts = split(strip(line), ' '; limit = 2)
    if length(parts) != 2
        @warn "mcp ctrl dial-back rejected: malformed handshake (expected 2 fields 'secret project_id')" got_fields=length(parts)
        return
    end
    if parts[1] != state.worker_secret
        @warn "mcp ctrl dial-back rejected: secret MISMATCH" worker_secret=secret_fingerprint(parts[1]) server_secret=secret_fingerprint(state.worker_secret) project_id=String(parts[2])
        return
    end
    project_id = String(parts[2])
    lock(state.lock) do
        state.mcp_ctrl[project_id] = ws
    end
    @info "MCP control channel connected" project_id
    try
        for msg in ws
            # Per-frame guard — one malformed reply must not drop the channel.
            try
                d = JSON.parse(String(msg))
                if get(d, "type", "") == "eval_stream_chunk"
                    # Unsolicited live-stdout push (no request_id): route it to the
                    # matching running eval's tail. High-volume, so handled first.
                    route_eval_chunk!(state, project_id,
                        String(get(d, "route", "")), String(get(d, "chunk", "")))
                else
                    rid = get(d, "request_id", nothing)
                    rid isa AbstractString && !isempty(rid) &&
                        deliver_rpc_response!(state, String(rid), Dict{String,Any}(d))
                end
            catch e
                @warn "mcp ctrl frame error" exception = e
            end
        end
    catch e
        is_stale_session_error(e) ||
            @warn "mcp ctrl loop ended" project_id exception = (e, catch_backtrace())
    finally
        # Identity-guarded eviction: a reconnect may have swapped a fresh WS
        # in before this stale handler's finally ran.
        lock(state.lock) do
            get(state.mcp_ctrl, project_id, nothing) === ws && delete!(state.mcp_ctrl, project_id)
        end
        @info "MCP control channel closed" project_id
    end
    return
end

# Sink registry key: one live eval tail per (chat, eval session). `route` is the
# eval session's env_path as the MCP tags it (see BonitoMCP.stream_route),
# matched against the tool's normalized env_path in `eval_stream_loop!`.
eval_sink_key(project_id::AbstractString, route::AbstractString) = "$project_id\0$route"

"""
    route_eval_chunk!(state, project_id, route, chunk)

Deliver a live stdout/stderr chunk (pushed by the MCP over /mcp-ws) to the
matching running eval's tail loop. Drops silently if no tail is listening — the
live stream is a best-effort display side-channel; the agent's copy of the
output rides the MCP tool response separately.
"""
function route_eval_chunk!(state::ServerState, project_id::AbstractString,
                           route::AbstractString, chunk::AbstractString)
    isempty(chunk) && return nothing
    ch = lock(state.lock) do
        get(state.eval_stream_sinks, eval_sink_key(project_id, route), nothing)
    end
    ch === nothing && return nothing
    try
        isopen(ch) && put!(ch, chunk)
    catch
        # channel closed between the read and the put — the tail loop is gone
    end
    return nothing
end

"""
    interrupt_project_eval!(state, project_id; env_path=nothing, timeout=15.0) -> Int

SIGINT the in-flight `bt_julia_eval` of `project_id`'s MCP server — the
chat-side half of the per-tool ⊗ stop button. `env_path` scopes the
interrupt to one eval session; `nothing` interrupts every in-flight eval of
that chat's MCP process (it serves exactly one chat, so that's safe).
Returns how many evals were interrupted. Throws when the project has no
live control channel (agent not started, or a worker install that predates
the feature).
"""
function interrupt_project_eval!(state::ServerState, project_id::AbstractString;
                                 env_path::Union{AbstractString,Nothing} = nothing,
                                 timeout::Real = 15.0)
    ws = mcp_ctrl_for(state, project_id)
    ws === nothing && error(
        "no MCP control channel for this chat — the agent's MCP server " *
        "hasn't dialed back (not started yet, or an old worker install)")
    rid, ch = register_rpc!(state)
    resp = try
        payload = Dict{String,Any}("op" => "interrupt_eval", "request_id" => rid)
        env_path === nothing || (payload["env_path"] = String(env_path))
        HTTP.WebSockets.send(ws, JSON.json(payload))
        take_pending!(state, ch, rid, timeout, "interrupt_eval")
    finally
        unregister_rpc!(state, rid)   # T10: no leak on send failure
    end
    resp isa AbstractDict || error("interrupt_eval: unexpected response shape")
    return Int(get(resp, "interrupted", 0))
end

# Env the server injects into the BonitoMCP MCP server so its eval worker can
# dial `/eval-ws` back. The dial-back URL itself is NOT set here — the
# BonitoWorker daemon supplies `BONITOAGENTS_SERVER_URL` (the URL it dialed in
# on), and BonitoMCP derives the eval-ws path from it. That keeps the two
# dial-backs (worker-control WS + eval WS) keyed off the same proven URL
# and avoids the server having to guess its own outward-facing address.
function eval_dialback_env(state::ServerState, project_id::AbstractString)
    return Dict{String,String}(
        "BONITOAGENTS_SECRET"     => state.worker_secret,
        "BONITOAGENTS_PROJECT_ID" => String(project_id),
    )
end

# ── Host-side bridge attachment (per stable root session) ───────────────────
#
# The worker→host frame relay and the browser→worker routing are bound to the
# tab's STABLE root session (the one that owns the websocket), NOT to a transient
# `dom_in_js` subsession that the chat tears down on every tool-body re-render.
# Attached exactly once per (worker, root); torn down when the root closes. The
# attach-once guard is a per-bridge `eb.attached_roots` set of root ids (the bridge
# IS the prefix), not a module-global keyed by "prefix|root".
function attach_bridge_host!(root::Bonito.Session, eb::EvalBridge)
    # ALWAYS rebind the browser connection + flush parked frames, even for an
    # already-attached root: the attach-once guard below only covers the
    # route/listener wiring. Keeping `root_conn` from the FIRST attach was a
    # pinned hang cause — after a page ws reconnect the relay kept writing to
    # the stale connection while every later mount's attach returned early.
    eb.root_conn[] = Bonito.connection(root)
    flush_parked!(eb, eb.root_conn[])

    lock(eb.wire_lock) do
        root.id in eb.attached_roots && return false
        push!(eb.attached_roots, root.id); return true
    end || return

    # Rebind + flush on every (re)connect of this tab's websocket, so a
    # reconnect can't leave the relay pointed at the dead connection.
    Bonito.on(root.on_open) do _
        eb.root_conn[] = Bonito.connection(root)
        flush_parked!(eb, eb.root_conn[])
    end

    # browser → worker: the host decodes each inbound frame to route it
    # (route_to_remote needs the msg_type/session), then `proxy_forward(eb, data)`
    # re-packs the DECODED frame as plain (uncompressed) msgpack for the worker —
    # making the worker side compression-agnostic regardless of the browser
    # connection's compression. Routing is by the BRIDGE prefix — any sub.id /
    # object id starts with it. `eb` IS the host driver (see `proxy_forward`).
    Bonito.register_remote!(root, Bonito.RemoteSession(eb.prefix, eb))

    Bonito.on(root.on_close) do _
        Bonito.unregister_remote!(root, eb.prefix)
        eb.root_conn[] === Bonito.connection(root) && (eb.root_conn[] = nothing)
        lock(eb.wire_lock) do; delete!(eb.attached_roots, root.id); end
    end
    return
end

# Close a proxied worker subsession (best-effort): a `close` control frame. The
# worker's `close_subsession` releases its asset (1→0 → `asset_remove`) and emits
# `free_session(sub_id)` back through the bridge, dropping the browser-side
# objects/listeners a removed mount left on shared observables.
close_remote_sub!(eb::EvalBridge, sub_id::AbstractString) =
    (send_ctrl(eb, Dict("op" => "close", "sub" => String(sub_id))); nothing)

# ── RemoteRef: a worker-held eval RESULT as a composable value ───────────────
# (spec: docs/superpowers/specs/2026-07-15-remote-ref-design.md)
#
# The worker PARKS the result value in a page-invisible holder session
# (`RemoteProxy.remote_ref`) and the chat receives only its id. Rendering is
# serialize-on-mount: `jsrender` asks the worker (the "mount" control op) to
# render the held App into a FRESH, disposable render-subsession targeted at
# our placeholder node — delivered as one atomic `UpdateSession` through the
# relay (the page polls for the node, so the reply racing the DOM mount is
# fine). Static-first: the placeholder shows `snapshot` (or a not-live note)
# immediately and the UpdateSession REPLACES it — a dead bridge, an evicted
# holder, a slow worker, or a lost reply all degrade to the same visible
# static state. Nothing can hang.
#
# Ownership: each mount's LOCAL session owns its OWN render-sub — collapse
# discards the local `dom_in_js` sub, its `on_close` closes the render-sub on
# the worker (Julia-first deletion, so the page frees via `free_session`).
# The holder is never touched by mount lifecycles, so collapse → re-expand
# (fresh local session → fresh mount → fresh render-sub) can never be killed
# by a stale close, and the page GC collecting an unmounted render-sub is
# correct behavior.
struct RemoteRef
    bridge::Union{Nothing, EvalBridge}   # THIS worker incarnation; the id's prefix pins validity
    session_id::String                   # worker-side holder session id ("prefix/uuid")
    snapshot::String                     # static html fallback; "" = none yet
end

function Bonito.jsrender(session::Bonito.Session, r::RemoteRef)
    body = isempty(r.snapshot) ?
        Bonito.DOM.div("(result not live — worker gone and no snapshot)"; class = "bt-tool-empty") :
        HTML(r.snapshot)
    node = Bonito.DOM.div(body; class = "bt-remote-ref")
    eb = r.bridge
    if eb === nothing || eb.ws === nothing
        return Bonito.jsrender(session, node)
    end
    node_id = Bonito.uuid(session, node)
    # Routing must live on the ROOT (owns the tab's websocket); `session` is the
    # transient `dom_in_js` sub the tool body renders in.
    attach_bridge_host!(Bonito.root_session(session), eb)
    Base.errormonitor(@async try
        render_sub = String(call_ctrl(eb, "mount"; sub = r.session_id, node = node_id))
        Bonito.on(session, session.on_close) do _
            close_remote_sub!(eb, render_sub)
        end
        # The local session may have closed while the round trip was in flight
        # (fast collapse): the listener above will never fire, close directly.
        Bonito.isclosed(session) && close_remote_sub!(eb, render_sub)
    catch e
        # The placeholder keeps showing the static state; a re-expand retries
        # with a fresh mount.
        @warn "RemoteRef mount failed (static fallback stays)" exception = (e,) session_id = r.session_id
    end)
    return Bonito.jsrender(session, node)
end

# Exact decode of the worker's result descriptor json — the ONE place the
# eval wire format is recognized (`{"remote_ref": "prefix/uuid", "errored":
# bool}`; the `errored` field marks a parked CapturedException). Returns
# nothing for anything else: the block is then plain output text. This is
# boundary decoding of our own versioned format, not content sniffing.
function result_descriptor(payload::AbstractString)
    s = String(payload)
    startswith(s, "{") || return nothing
    d = try
        JSON.parse(s)
    catch
        return nothing
    end
    d isa AbstractDict || return nothing
    ref = get(d, "remote_ref", nothing)
    ref isa AbstractString || return nothing
    return (ref = String(ref), errored = get(d, "errored", false) === true)
end

# Build the RemoteRef from the persisted result payload (the final content
# block). Current payloads are the JSON descriptor (see `result_descriptor`);
# pre-RemoteRef history persisted the rendered html itself — which is exactly
# a static snapshot, so it maps onto the same value with no live bridge.
function remote_result(state::ServerState, payload::AbstractString, project_id::AbstractString)
    desc = result_descriptor(payload)
    desc === nothing && return RemoteRef(nothing, "", String(payload))
    return RemoteRef(eval_bridge_for(state, project_id), desc.ref, "")
end
