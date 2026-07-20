module RemoteProxy

# Worker-side bridge for proxying a Bonito.App's session through to the BonitoAgents
# server, which fronts the browser.
#
# This is the REMOTE driver for Bonito's transport-agnostic proxy framework (see
# Bonito/src/connection/proxy.jl + asset-serving/proxy.jl). The worker session is
# a stock `Bonito.ProxyConnection` whose driver — `BridgeDriver` here — relays the
# proxy verbs over ONE dial-back websocket, RAW (no Malt on this socket):
#   * `proxy_send`         → a Bonito frame, tagged `D` (worker → browser)
#   * `proxy_asset_add/remove` → an `asset_add`/`asset_remove` control frame (`C`)
# Inbound (browser→worker) `D` frames go straight onto `parent.inbox`, where
# Bonito's stock inbox-reader runs the normal decompress + unpack + dispatch.
#
# `C` (control) frames are the few request/response ops that aren't a plain Bonito
# frame: `asset_read` (lazy range fetch), `asset_url` (expose a worker-disk file
# as a streamable proxied asset), `close` a subsession. The worker reuses Bonito's
# `ProxyAssetServer` — none of that is re-implemented here.
#
# Bootstrapping (include this module, build the bridge, start the dial) happens
# over BonitoMCP's OWN Malt link to its worker — Malt stays there, never on this
# socket / in the per-frame path.

import Bonito
using Bonito.HTTP.WebSockets: WebSockets

const TAG_DATA = UInt8('D')
const TAG_CTRL = UInt8('C')

# ── Worker-side proxy driver: relays Bonito's proxy verbs onto the dial-back ws ──
# Cap on frames buffered while disconnected (below) — a backstop against a worker
# that builds a bridge but never dials (the queue would otherwise grow unbounded).
# Generous: an eval result's init bundle is a handful of frames; a flood this large
# means something is wrong, so we drop + warn rather than OOM the worker.
const MAX_PENDING_FRAMES = 4096

mutable struct BridgeDriver
    ws::Ref{Any}            # current dial-back websocket (set by serve_bridge); nothing ⇒ disconnected
    wlock::ReentrantLock    # serialize concurrent frame sends + the connect/flush transition
    pending::Vector{Vector{UInt8}}   # tagged frames produced while disconnected; flushed in order on connect
end
BridgeDriver() = BridgeDriver(Ref{Any}(nothing), ReentrantLock(), Vector{Vector{UInt8}}())

# Low-level: write one already-tagged frame to the live socket (caller holds wlock).
function write_frame(ws, buf::Vector{UInt8})
    try
        WebSockets.send(ws, buf)
    catch e
        # A send racing socket teardown/reconnect is the expected failure mode
        # (worker redials via dial_loop). Anything else is real signal we don't
        # want to lose — `@debug` is silent at default level, so `@warn`.
        @warn "RemoteProxy: frame send failed" exception = (e, catch_backtrace()) bytes = length(buf)
    end
end

function send_frame(d::BridgeDriver, tag::UInt8, payload::AbstractVector{UInt8})
    buf = Vector{UInt8}(undef, length(payload) + 1)
    @inbounds buf[1] = tag
    copyto!(buf, 2, payload, firstindex(payload), length(payload))
    lock(d.wlock) do
        ws = d.ws[]
        if ws === nothing
            # Not dialed yet. A result rendered at eval-time (its `proxy_asset_add`
            # for the init bundle, say) fires BEFORE the dial-back connects — drop
            # it and the host never learns `/assets/<key>` is proxied, so the
            # browser's later fetch isn't forwarded to the worker. Accumulate and
            # flush in order when `serve_bridge` attaches the socket.
            if length(d.pending) >= MAX_PENDING_FRAMES
                @warn "RemoteProxy: pending frame buffer full before dial-back; dropping frame" cap = MAX_PENDING_FRAMES
            else
                push!(d.pending, buf)
            end
        else
            write_frame(ws, buf)
        end
    end
    return nothing
end
send_control(d::BridgeDriver, dict) = send_frame(d, TAG_CTRL, Bonito.MsgPack.pack(dict))

# Bonito proxy verbs (worker side). `proxy_send` ships a serialized Bonito frame;
# the asset verbs push the host the net 0→1 / 1→0 transitions as control frames.
Bonito.proxy_send(d::BridgeDriver, bytes) = send_frame(d, TAG_DATA, bytes)
Bonito.proxy_asset_add(d::BridgeDriver, key, mime, total, cached) =
    send_control(d, Dict("op" => "asset_add", "key" => key, "mime" => mime,
                         "total" => total, "cached" => cached))
Bonito.proxy_asset_remove(d::BridgeDriver, key) =
    send_control(d, Dict("op" => "asset_remove", "key" => key))

# ── The bridge: one long-lived proxied root session over the dial-back driver ─
mutable struct RemoteBridge
    parent::Bonito.Session
    driver::BridgeDriver
end

const BRIDGE = Ref{Union{Nothing, RemoteBridge}}(nothing)

# The running `dial_loop` task, tracked so `stop_dial!` can WAIT for it to exit
# before anything re-dials — a second loop starting while the first is still
# alive would fight over `driver.ws[]` forever (see the warning in session.jl's
# ensure_eval_dialed_locked!). Set by `start_dial!`, cleared by `stop_dial!`.
const DIAL_TASK = Ref{Union{Nothing, Task}}(nothing)

"""
    RemoteBridge(; compression=false)

Build the worker-side bridge: a long-lived proxied root `Session` (a stock
`Bonito.ProxyConnection` + `ProxyAssetServer` over a shared `BridgeDriver`).
Subsessions (one per embed) inherit the connection + asset_server + compression
through Bonito's normal parent/sub path; the driver relays every frame and asset
event down the dial-back socket.
"""
function RemoteBridge(; compression::Bool = false)
    prefix = string(Bonito.uuid4())
    driver = BridgeDriver()
    conn   = Bonito.ProxyConnection(prefix, driver)
    parent = Bonito.Session(conn; id = prefix,
                            asset_server = Bonito.ProxyAssetServer(driver),
                            compression_enabled = compression)
    # The parent never gets its own `JSDoneLoading` (it's not a page), but its
    # writes reach the browser through the host relay — mark it ready so
    # `close`ing a subsession can emit `free_session` through the bridge.
    isready(parent.connection_ready) || put!(parent.connection_ready, true)
    return RemoteBridge(parent, driver)
end

"""
    ensure_bridge!(; compression=false) -> prefix::String

Create the one-and-only bridge for this worker process if absent; return its
namespace prefix. Bootstrapped over BonitoMCP's Malt link; the prefix is handed to
the dial handshake so the host knows the namespace before any frame flows.
"""
function ensure_bridge!(; compression::Bool = false)
    if BRIDGE[] === nothing
        BRIDGE[] = RemoteBridge(; compression)
        # Log every (re)build with the prefix — a rebuild starts a fresh proxied
        # parent session, which is otherwise invisible.
        @info "RemoteProxy: BRIDGE built" prefix = BRIDGE[].parent.id
    end
    return BRIDGE[].parent.id
end

"""
    get_parent_session(; compression=false) -> Bonito.Session

The worker's ONE proxied parent session — this IS the bridge: its connection is
the dial-back proxy driver and its asset_server the `ProxyAssetServer`, so every
subsession rendered against it (one per eval result) relays its frames + assets
down the dial-back socket. Built lazily on first use; `force_subsession!(true)`
makes all rendering resolve to subsessions of this parent rather than standalone
pages. This is the single entry point the render path asks for the page session.
"""
function get_parent_session(; compression::Bool = false)
    ensure_bridge!(; compression)
    Bonito.force_subsession!(true)
    return BRIDGE[].parent
end

"""
    dial_loop(wsurl, handshake; min_backoff=0.5, max_backoff=8.0)

Run the dial-and-serve loop until BRIDGE[] goes away. Each iteration opens a
fresh websocket to `wsurl`, sends the `handshake` line, and runs `serve_bridge`.
When the socket dies (clean EOF, network drop, host restart), we sleep with
exponential backoff and dial again — so a transient WS drop doesn't leave the
bridge silently disconnected. `BRIDGE[]` (the proxied parent session + its asset
server) survives the drop, so the host recognises the dial-back as a *reconnect*
by `prefix` and swaps the WS rather than rebuilding.
"""
function dial_loop(wsurl::AbstractString, handshake::AbstractString;
                   min_backoff::Float64 = 0.5, max_backoff::Float64 = 8.0)
    backoff = min_backoff
    while BRIDGE[] !== nothing
        connected = false
        try
            Bonito.HTTP.WebSockets.open(wsurl) do ws
                Bonito.HTTP.WebSockets.send(ws, handshake)
                connected = true
                serve_bridge(ws)
            end
        catch e
            @warn "RemoteProxy: dial failed; will retry" wsurl backoff exception = e
        end
        # `connected` is the right signal — `serve_bridge` returning is normal
        # (peer EOF); never getting past `open` is a real failure → grow backoff.
        backoff = connected ? min_backoff : min(backoff * 2, max_backoff)
        sleep(backoff)
    end
    @info "RemoteProxy: dial loop exiting (BRIDGE cleared)"
    return
end

"""
    start_dial!(wsurl, handshake)

Build the bridge (if needed) and spawn the self-reconnecting `dial_loop`,
remembering its task in `DIAL_TASK` so `stop_dial!` can join it. Called once per
(re)dial from the host's `ensure_eval_dialed!` bootstrap.
"""
function start_dial!(wsurl::AbstractString, handshake::AbstractString)
    ensure_bridge!()
    DIAL_TASK[] = @async try
        dial_loop(wsurl, handshake)
    catch e
        @warn "BonitoMCP eval-ws dial loop crashed" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    stop_dial!(; timeout = 10.0) -> Bool

Tear the dial-back down WITHOUT killing the worker: clear `BRIDGE[]` so the loop's
`while BRIDGE[] !== nothing` exits, close the live socket to unblock a connected
`serve_bridge`, then WAIT (bounded) for the task to finish. The warm Malt session
and its compiled state are untouched; the next eval rebuilds the bridge and dials
whatever server is current. `timeout` exceeds `dial_loop`'s `max_backoff` (8s) so
a loop caught mid-backoff still exits before we return. Returns whether the loop
actually stopped (so a caller can avoid re-dialing on top of a lingering loop).
"""
function stop_dial!(; timeout::Float64 = 10.0)
    b = BRIDGE[]
    BRIDGE[] = nothing                        # loop exits at its next `while` check
    if b !== nothing
        try
            ws = b.driver.ws[]
            ws === nothing || close(ws)        # unblock serve_bridge if connected
        catch
        end
    end
    t = DIAL_TASK[]
    DIAL_TASK[] = nothing
    t === nothing && return true
    t0 = time()
    while !istaskdone(t) && time() - t0 < timeout
        sleep(0.05)
    end
    return istaskdone(t)
end

"""
    serve_bridge(ws)

Run the bridge's frame loop on the dial-back websocket `ws`. Points the driver at
the socket, then pumps inbound frames: `D` → `parent.inbox` (stock dispatch),
`C` → control. Clears the driver's socket on exit; does NOT tear the bridge down
(its lifetime is the worker's Julia session, not this socket).
"""
function serve_bridge(ws)
    b = BRIDGE[]
    b === nothing && error("RemoteProxy: bridge not built before serve_bridge")
    d = b.driver
    # Attach the socket AND flush anything buffered while disconnected, atomically
    # under wlock: a concurrent `send_frame` either ran before (its frame is in
    # `pending`, so the flush below sends it) or after (it sees `ws` set and sends
    # directly) — never lost, never out of order.
    lock(d.wlock) do
        d.ws[] = ws
        if !isempty(d.pending)
            n = length(d.pending)
            for buf in d.pending
                write_frame(ws, buf)
            end
            empty!(d.pending)
            @info "RemoteProxy: flushed buffered frames on dial-back connect" frames = n
        end
    end
    try
        for msg in ws
            data = msg isa AbstractVector{UInt8} ? msg :
                   Vector{UInt8}(codeunits(String(msg)))
            isempty(data) && continue
            tag = @inbounds data[1]
            payload = Vector{UInt8}(@view data[2:end])
            if tag == TAG_DATA
                # Inbound Bonito frame → stock inbox dispatch (kept in order).
                isopen(b.parent.inbox) && put!(b.parent.inbox, payload)
            elseif tag == TAG_CTRL
                # Control can render (slow) or read assets — run it OFF the receive
                # loop so it never starves inbound frames; guard so one bad control
                # frame can't kill the bridge.
                @async try
                    handle_control(b, Bonito.MsgPack.unpack(payload))
                catch e
                    @warn "RemoteProxy: control frame failed" exception = (e, catch_backtrace())
                end
            end
        end
    catch e
        e isa WebSockets.WebSocketError || e isa EOFError || e isa Base.IOError ||
            @warn "RemoteProxy.serve_bridge loop ended" exception = (e, catch_backtrace())
    finally
        lock(d.wlock) do
            d.ws[] = nothing
        end
    end
    return
end

# Control request/response (the only ops that aren't a plain frame).
#
# The request-shaped ops (`asset_read`, `asset_url`) carry an `id` the host waits
# on. Any exception below MUST come back as a reply with an `err` field — otherwise
# the host's `call_ctrl` only learns about the failure after a 30s timeout,
# freezing the chat tool-render path. Notifications (`close`) carry no id.
# ── RemoteRef: page-invisible value holder + serialize-on-mount ─────────────
# (spec: BonitoAgents/docs/superpowers/specs/2026-07-15-remote-ref-design.md)
#
# An eval result is PARKED, not rendered: a subsession of the bridge parent
# holds `App(value)` in `current_app` and is never shipped to any page (so the
# page-side session GC can't touch it; it dies with the worker). The session
# tree is the registry — `get_session` finds it by id. Rendering happens per
# MOUNT via the "mount" control op below: `update_session_dom!` creates a
# fresh, disposable render-subsession and delivers html + init messages as one
# atomic UpdateSession through the relay. Each mount is independent, so
# collapse/re-expand loops and page reloads can never race each other.
function remote_ref(@nospecialize(value))
    parent = get_parent_session()
    holder = Bonito.Session(parent)
    holder.current_app[] = Bonito.App(display_value(bound_for_render(value)))
    return holder.id
end

function handle_control(b::RemoteBridge, msg::AbstractDict)
    op = msg["op"]
    d = b.driver
    id = get(msg, "id", nothing)
    try
        if op == "asset_read"
            bytes = Bonito.read_proxy_asset(b.parent.asset_server.registry,
                        String(msg["key"]), Int(msg["start"]), Int(msg["stop"]))
            send_control(d, Dict("op" => "reply", "id" => id, "val" => bytes))
        elseif op == "asset_url"
            # Expose a worker-disk file to the browser through the NORMAL proxy
            # asset path: `url` registers a `Bonito.Asset` on the bridge's asset
            # server and fires `asset_add`, so the host builds the matching
            # `RemoteAsset` and serves `/assets/<key>` with on-demand range reads.
            # Returns that host-relative url to drop into a plain <img>/<video>
            # src — no App/subsession needed for media.
            # Append ?v=<mtime> so the browser treats each file version as a
            # distinct URL (cache-bust). The HTTP handler strips the query string
            # before the asset lookup, so the server always finds the asset.
            path_str = abspath(String(msg["path"]))
            url = Bonito.url(b.parent.asset_server, Bonito.Asset(path_str))
            mt  = isfile(path_str) ? round(Int, mtime(path_str)) : 0
            send_control(d, Dict("op" => "reply", "id" => id, "val" => url * "?v=" * string(mt)))
        elseif op == "close"
            s = Bonito.get_session(b.parent, String(msg["sub"]))
            s === nothing || close(s)
        elseif op == "mount"
            holder = Bonito.get_session(b.parent, String(msg["sub"]))
            holder === nothing &&
                error("result session $(msg["sub"]) not found (worker restarted or result evicted)")
            app = holder.current_app[]
            app === nothing && error("result session $(msg["sub"]) holds no app")
            Bonito.force_subsession!(true)
            sub = Bonito.update_session_dom!(holder, String(msg["node"]), app)
            send_control(d, Dict("op" => "reply", "id" => id, "val" => sub.id))
        end
    catch e
        # Surface the failure to the host so its 30s timedwait turns into a fast,
        # informative error. Then rethrow so serve_bridge's @warn keeps the
        # worker-side stacktrace for diagnosis.
        if id !== nothing
            try
                send_control(d, Dict("op" => "reply", "id" => id,
                                     "err" => sprint(showerror, e)))
            catch
            end
        end
        rethrow()
    end
    return
end

# ── Rendering an eval RESULT value into a chat-mountable HTML fragment ────────
# `bt_julia_eval` ships its result to the chat as ONE self-contained HTML string,
# rendered as a SUBSESSION of the bridge's per-page `parent`. Because the parent
# carries the PROXIED connection + asset server, the fragment's asset/observable
# URLs point at the host proxy and that traffic rides the dial-back ws — exactly
# like Bonito serving a page to a browser, only proxied. There's no app registry
# and no `shown_app:` token: the HTML string IS the result (and a persistable one
# — the server can save it and re-mount it later, a static snapshot when the
# worker is gone).
#
# `App(value)` is the WHOLE renderer: per-type rendering is `Bonito.jsrender`'s
# job at render time (a type that wants a richer display adds a
# `jsrender(::Session, ::MyType)` method — never isa-sniff here). No `NoSplat`
# wrapper is needed: `App(value)` routes through `jsrender(value)`, which renders
# an array/matrix/vector-of-nodes via its text repr; Hyperscript's child-splat
# (`DOM.div(array...)`) only bites the `DOM.div(value)` container path, which we
# never take. `force_subsession!(true)` makes nested jsrender resolve to
# subsessions of the parent too.
# Caps so a huge RETURN value can't balloon the chat message / hang the browser.
# Containers (arrays/dicts/dataframes) are already row/elem-truncated by `:limit`
# in the render io_context, and images ship their bytes via the asset proxy (the
# html only carries a URL) — so neither balloons. A bare `String`/`Symbol` is the
# main offender (rendered verbatim, not `:limit`-truncated); cap it up front. The
# final byte cap is a backstop for any other type whose `show` ignores `:limit`.
const MAX_RENDER_STRING = 100_000     # chars kept from a huge string value
const MAX_RENDER_BYTES  = 1_000_000   # cap on the rendered fragment

function bound_for_render(s::AbstractString)
    length(s) <= MAX_RENDER_STRING && return s
    cut = thisind(s, min(MAX_RENDER_STRING, lastindex(s)))
    return SubString(s, firstindex(s), cut) *
        "\n[… truncated: string was $(length(s)) characters]"
end
bound_for_render(@nospecialize x) = x

# A returned String renders through Bonito's plain-text child path
# (`jsrender(::Session, ::String)` returns the string as-is), which never hits
# the `render_mime` ANSI handling — so a result string carrying ANSI codes
# (e.g. from `sprint` with color) would show raw escapes while the SAME text on
# stdout renders as a colored terminal block. Route ANSI strings through
# `RichText` so both paths display alike.
display_value(@nospecialize x) = x
display_value(s::AbstractString) =
    Bonito.has_ansi_codes(String(s)) ? Bonito.RichText(String(s)) : s
# Callables would be swallowed by `App`'s handler constructor (`App(sqrt)`
# reads as "sqrt IS the app" and rejects its signature) — show them as the
# REPL would instead. Matches `App`'s handler dispatch surface exactly
# (functions AND types are callable).
display_value(f::Union{Function, Type}) =
    Bonito.RichText(sprint(show, MIME"text/plain"(), f; context = :color => true))

function render_eval_html(value)
    parent = get_parent_session()
    render1(v) = (io = IOBuffer();
                  Bonito.show_html(io, Bonito.App(v); parent = parent);
                  String(take!(io)))
    html = render1(display_value(bound_for_render(value)))
    if ncodeunits(html) > MAX_RENDER_BYTES
        html = render1(string(typeof(value), ": rendered output too large (",
                              ncodeunits(html), " bytes) — display suppressed"))
    end
    return html
end

end # module RemoteProxy
