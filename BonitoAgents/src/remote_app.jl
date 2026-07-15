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
#                     `delegate` (render an app subsession → init bundle),
#                     `asset_read` (lazy range fetch), `close` (a subsession),
#                     and the worker→host `asset_add`/`asset_remove` push.

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
    # Per-bridge host-side wiring. FIELDS, not module-global `BRIDGE_ATTACHED` /
    # `MOUNTS` Dicts keyed by this bridge's prefix: this state belongs to ONE
    # bridge and dies with it (`clear_bridge_wiring!` just empties these).
    attached_roots::Set{String}          # root.id of every tab this bridge is wired to (attach-once guard)
    mounts::Dict{String,String}          # "root.id|app_id" => current worker sub_id (supersede bookkeeping)
    wire_lock::ReentrantLock             # guards attached_roots + mounts
end

# Reconnects compare prefix (== BRIDGE[].parent.id on the worker): same prefix
# means same BRIDGE[] / same routes, swap WS; different prefix means worker
# restart, hard-replace. `ws === nothing` ⇒ disconnected, awaiting redial.
make_eval_bridge(prefix::AbstractString, ws, host) = EvalBridge(
    String(prefix), ws, ReentrantLock(), host,
    Dict{Int,Channel{Any}}(), ReentrantLock(),
    Threads.Atomic{Int}(0), Base.RefValue{Any}(nothing),
    Set{String}(), Dict{String,String}(), ReentrantLock())

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

# A control request that expects a reply (delegate / asset_read). The dial-back
# relay loop resolves it via `pending`; this runs on a DIFFERENT task (a chat
# command or an HTTP asset handler), so the wait can't deadlock the relay.
function call_ctrl(eb::EvalBridge, op::AbstractString; timeout = 30.0, kw...)
    # Disconnected window (WS dropped, worker redialing): fail fast instead of
    # sending into the void and waiting out the full timeout. The worker's
    # dial_loop reconnects within its backoff; the caller can retry/re-render.
    eb.ws === nothing && error("eval bridge disconnected (worker redialing); '$op' not sent")
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
            # One-shot log on the FIRST drop of a run (T12): the old condition
            # `just_failed && (…; just_failed = true)` was inverted — it only
            # logged once `just_failed` was ALREADY true, so the promised
            # "frame dropped" line never fired on the first drop. Log when NOT
            # already in a failed run, then latch.
            just_failed || (@info "eval relay: no browser connection — frame dropped" prefix = eb.prefix)
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
            @warn "eval relay: browser write failed (frame dropped)" exception = (e, catch_backtrace()) bytes = length(payload) prefix = eb.prefix
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
    # delivers control REPLIES (delegate / asset_read), so a slow or CPU-bound
    # browser (WGLMakie, or headless software-WebGL) that drains its socket slowly
    # would otherwise block the loop on `write(rc, …)` and starve those replies →
    # 30s `call_ctrl` timeouts ("delegate timed out" / stuck "loading…"). Data
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
# and per-mount subsession bookkeeping — so a later bridge (same tab) re-attaches
# cleanly instead of short-circuiting on a stale attach tag. The wiring lives on
# the bridge now, so this just empties it. (The mounted subs are already dead once
# the worker session is gone, so we just drop the entries.)
function clear_bridge_wiring!(eb::EvalBridge)
    lock(eb.wire_lock) do
        empty!(eb.attached_roots)
        empty!(eb.mounts)
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
                rid = get(d, "request_id", nothing)
                rid isa AbstractString && !isempty(rid) &&
                    deliver_rpc_response!(state, String(rid), Dict{String,Any}(d))
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

# Host-side renderable: embeds the worker fragment and drives the worker
# session's `init_session` in the browser via on_document_load.
struct RemoteWorkerApp
    html::String
    init_url::String
    session_id::String          # sub.id — passed to `Bonito.init_session(…)` so the browser
                                # bootstraps this exact subsession's queued messages.
    bridge_prefix::String       # `id_prefix(connection(sub))` — the namespace the worker stamps
                                # onto every cache_key / dom-jscall-id / sub-session-id it puts
                                # into the browser's three global namespaces. Used by the host's
                                # `route_to_remote` to forward inbound frames back to the worker,
                                # and exposed via `data-bonito-remote` so callers driving the
                                # embed from JS know what prefix to construct cache keys with.
    compression::Bool
end

function Bonito.jsrender(session::Bonito.Session, app::RemoteWorkerApp)
    # `Base.HTML{String}` is the first-class raw-HTML primitive: Bonito's
    # `RAW_HTML_TAG` msgpack rule (serialization/msgpack.jl) ships the bytes
    # through the dynamic `dom_in_js` path binary-safe — no string-escaping,
    # no JS-literal newline pitfalls.
    node = Bonito.DOM.div(Base.HTML{String}(app.html); dataBonitoRemote = app.bridge_prefix)
    Bonito.onload(session, node, js"""(el) => {
        Bonito.init_session($(app.session_id), Bonito.fetch_binary($(app.init_url)), "sub", $(app.compression));
    }""")
    return Bonito.jsrender(session, node)
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
    lock(eb.wire_lock) do
        root.id in eb.attached_roots && return false
        push!(eb.attached_roots, root.id); return true
    end || return

    # worker → browser frames are written to this connection by the dial-back
    # relay loop (`handle_eval_ws`); point it at this tab's socket.
    eb.root_conn[] = Bonito.connection(root)

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
        # Close any worker subsessions still mounted for this tab so they don't
        # outlive the page.
        for sid in take_mounts!(root, eb); close_remote_sub!(eb, sid); end
        lock(eb.wire_lock) do; delete!(eb.attached_roots, root.id); end
    end
    return
end

# ── Per-mount subsession bookkeeping ────────────────────────────────────────
#
# `Collapsable` discards a tool body with `innerHTML=''` and re-renders via a
# FRESH `dom_in_js` on the next expand — and that DOM removal does NOT close the
# proxied worker subsession (Bonito's delete-observer doesn't reliably collect
# proxied subs; the reference `embed_app` likewise tears down explicitly on
# `host.on_close`). So we track the current worker sub per (tab, app) and close
# the previous one when a new mount supersedes it, mirroring `embed_app`. Closing
# the worker sub releases its asset (1→0) AND — because the bridge parent is
# marked ready — emits `Bonito.free_session(sub_id)` to the browser, dropping the
# stale listeners a removed mount left on shared observables.
# Mount bookkeeping lives on the bridge (`eb.mounts`), so the key drops the prefix
# (the bridge IS the prefix): "root.id|app_id" => current sub_id.
mount_key(root, app_id) = string(root.id, '|', app_id)

# Record `sub_id` as the live mount for (root, app); return the superseded one (or nothing).
function swap_mount!(root, eb, app_id, sub_id)
    lock(eb.wire_lock) do
        k = mount_key(root, app_id)
        old = get(eb.mounts, k, nothing); eb.mounts[k] = sub_id; old
    end
end

# Drop + return every mounted sub_id for this (root, bridge) — used on tab close.
function take_mounts!(root, eb)
    lock(eb.wire_lock) do
        pre = string(root.id, '|')
        ks = filter(k -> startswith(k, pre), collect(keys(eb.mounts)))
        sids = String[eb.mounts[k] for k in ks]; foreach(k -> delete!(eb.mounts, k), ks); sids
    end
end

# Close a proxied worker subsession (best-effort): a `close` control frame. The
# worker's `close_subsession` releases its asset (1→0 → `asset_remove`) and emits
# `free_session(sub_id)` back through the bridge, dropping the browser-side
# objects/listeners a removed mount left on shared observables.
close_remote_sub!(eb::EvalBridge, sub_id::AbstractString) =
    (send_ctrl(eb, Dict("op" => "close", "sub" => String(sub_id))); nothing)

"""
    embed_remote_app(host::Session, eb::EvalBridge, app_id::AbstractString) -> RemoteWorkerApp

Embed a Bonito.App registered on the eval worker's `RemoteProxy` bridge (by
`bt_show_app` / `show_remote_app!`) into `host`'s browser page.

Bridge host-side wiring (the worker→browser frame relay in `handle_eval_ws`, the
browser→worker routing, and the per-worker asset registry) is attached ONCE to
the tab's stable root session — see `attach_bridge_host!`. This call sends a
`delegate` control frame; the worker renders a FRESH subsession of the bridge
parent, packs its init bundle as a `BinaryAsset` (pushing `asset_add` control
frames the relay registers on `eb.asset_host`), and replies `(sub_id, html,
init_url)`. We wait until the init bundle is serveable before returning so the
browser's `fetch(init_url)` can't race ahead to a 404.

Because a `Collapsable` tool body is re-rendered on every expand (and the old
DOM is dropped with `innerHTML=''`, which does NOT close the proxied sub), we
explicitly close the previously-mounted worker sub for this (tab, app) — that
releases its asset and frees its browser-side listeners (see `close_remote_sub!`).
"""
function embed_remote_app(host::Bonito.Session, eb::EvalBridge, app_id::AbstractString)
    root = Bonito.root_session(host)
    attach_bridge_host!(root, eb)
    # One control round-trip: the worker renders a fresh subsession, packs its init
    # bundle as a BinaryAsset (which fires `asset_add` control frames the relay loop
    # registers on `eb.asset_host`), and replies with (sub_id, html, init_url).
    # `page` names THIS browser page (its root session id): the worker resets its
    # serialization dedup cache when the page changes, so a bundle built for a
    # previous page (whose browser object cache is gone — reload, new tab) is
    # never assumed to be resolvable here (RemoteProxy.switch_page!).
    sub_id, html, init_url = call_ctrl(eb, "delegate"; app = String(app_id),
                                       page = root.id)
    sub_id = String(sub_id); html = String(html); init_url = String(init_url)
    # The worker sends `asset_add` BEFORE the delegate reply (same socket, in order),
    # so the init bundle is normally already registered; this is just a safety net.
    if Base.timedwait(() -> haskey(eb.asset_host.parent.files, init_url), 10.0) !== :ok
        @warn "embed_remote_app: init asset not registered in time" init_url
    end
    # Supersede the previous mount of this app in this tab: close its worker sub.
    prev = swap_mount!(root, eb, String(app_id), sub_id)
    prev === nothing || prev == sub_id || close_remote_sub!(eb, prev)
    # The bridge runs uncompressed, so the proxied subsession does too.
    return RemoteWorkerApp(html, init_url, sub_id, eb.prefix, false)
end

# ── Chat integration: a live worker app as a chat tool bubble ────────────────
#
# A `bonito_app` ToolMsg in the chat renders its body lazily via
# `render_tool_body` → a `RemoteAppPlaceholder`, whose `jsrender` runs
# `embed_remote_app` against the live per-tab `Bonito.Session` (mounted by the
# existing `ToolRenderCommand` → `dom_in_js` path). Each placeholder carries
# the project's `EvalBridge` + the app id under which the worker registered the
# app on its `RemoteProxy` bridge (the ToolMsg only carries that id, like
# `bt_show` carries a path).
struct RemoteAppPlaceholder
    bridge::Union{Nothing, EvalBridge}   # nothing if eval session not connected yet
    app_id::String                       # registered with RemoteProxy.register_app! on the worker
end

# Each mount embeds a FRESH worker subsession (its own sub_id / init bundle), so
# repeated tool-body renders (auto-expand can fire more than once, and `dom_in_js`
# makes a new subsession each time) never collide on a shared id — the obsolete
# mounts self-clean when their DOM is removed (browser → `CloseSession` → worker).
# The bridge's expensive host wiring (frame relay, routing, asset registry) is
# attached once and shared, so a fresh mount is cheap.
function Bonito.jsrender(session::Bonito.Session, p::RemoteAppPlaceholder)
    p.bridge === nothing &&
        return Bonito.jsrender(session, Bonito.DOM.div("(live app unavailable — eval session not connected)"))
    return Bonito.jsrender(session, embed_remote_app(session, p.bridge, p.app_id))
end

# Build the placeholder for a `bonito_app` tool. `app_id` is the id the worker
# registered the app under on its RemoteProxy bridge (via `RemoteProxy.register_app!`,
# either through `bt_show_app` or `show_remote_app!`).
function remote_app_placeholder(state::ServerState, tool_id::AbstractString,
                                project_id::AbstractString, app_id::AbstractString)
    eb = eval_bridge_for(state, project_id)   # read under state.lock (T11)
    return RemoteAppPlaceholder(eb, String(app_id))
end

# `shown_app: <id>` reference left by the bt_show_app MCP tool, in tool content.
function find_app_reference(content)
    for c in content
        if c isa AgentClientProtocol.TextContent
            m = match(r"shown_app:\s*(\S+)", c.text)
            m === nothing || return String(m.captures[1])
        end
    end
    return nothing
end

"""
    show_remote_app!(model::ChatModel, eb::EvalBridge, code::AbstractString; title=...) -> id

Add a live interactive worker app to `model`'s chat as an auto-expanded tool
bubble. `code` is Julia source that evaluates to a `Bonito.App`; it's shipped to
the worker over a `register` control frame, `include_string`-d there, and
registered via `RemoteProxy.register_app!`. Each browser tab embeds its own
subsession of the bridge parent on expand. (The primary path is the `bt_show_app`
MCP tool, which registers over BonitoMCP's own Malt link; this is the
BonitoAgents-side convenience over the raw bridge.)
"""
function show_remote_app!(model::ChatModel, eb::EvalBridge, code::AbstractString; title::AbstractString="Interactive app")
    id = string(Bonito.uuid4())
    call_ctrl(eb, "register"; app = id, code = String(code))
    # The app is registered under `id`, which is also this message's id — so the
    # typed `BonitoAppMsg` carries its app id intrinsically (app_id = id).
    send!(model, BonitoAppMsg(id, "bonito_app", String(title), "completed",
                              "live app", time(), time(), "", id, nothing))
    # auto-open the body (JS expands → ToolRenderCommand → render_tool_body)
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => id,
        "status" => "completed", "title" => title, "summary" => "live app", "expand" => true))
    return id
end

"""
    show_remote_app_for_project!(model, code; title=...) -> id

Like `show_remote_app!`, but uses the eval bridge that dialed back for this
model's project.
"""
function show_remote_app_for_project!(model::ChatModel, code::AbstractString; title::AbstractString="Interactive app")
    eb = eval_bridge_for(model.state, model.project_id)   # read under state.lock (T11)
    eb === nothing && error("show_remote_app: no eval bridge dialed back for project $(model.project_id)")
    return show_remote_app!(model, eb, code; title)
end
