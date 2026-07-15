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
# frame: `delegate` an app (render a subsession, return its init bundle),
# `asset_read` (lazy range fetch), `register` (eval + register an app), `close` a
# subsession. The worker reuses Bonito's `render_subsession` / `get_messages!` /
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
mutable struct BridgeDriver
    ws::Ref{Any}            # current dial-back websocket (set by serve_bridge); nothing ⇒ disconnected
    wlock::ReentrantLock    # serialize concurrent frame sends
end
BridgeDriver() = BridgeDriver(Ref{Any}(nothing), ReentrantLock())

function send_frame(d::BridgeDriver, tag::UInt8, payload::AbstractVector{UInt8})
    ws = d.ws[]
    ws === nothing && return nothing
    buf = Vector{UInt8}(undef, length(payload) + 1)
    @inbounds buf[1] = tag
    copyto!(buf, 2, payload, firstindex(payload), length(payload))
    lock(d.wlock) do
        try
            WebSockets.send(ws, buf)
        catch e
            # A send racing socket teardown/reconnect is the expected failure
            # mode (worker is supposed to redial via dial_loop). Anything else
            # is real signal we don't want to lose — `@debug` would be silent
            # at default log level, so use `@warn` so the actual exception
            # type/message is visible during diagnosis.
            @warn "RemoteProxy: frame send failed" exception = (e, catch_backtrace()) tag = Char(tag) bytes = length(buf)
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

# ── The bridge: one long-lived proxied root session + an app route table ─────
mutable struct RemoteBridge
    parent::Bonito.Session
    driver::BridgeDriver
    routes::Bonito.Routes
    # The browser PAGE (the host's root-session id) that `parent`'s
    # serialization cache currently reflects — see `switch_page!`. "" until
    # the first delegate names one.
    page::String
end

const BRIDGE = Ref{Union{Nothing, RemoteBridge}}(nothing)

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
    return RemoteBridge(parent, driver, Bonito.Routes(), "")
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
        # Log every (re)build with the prefix — a rebuild discards prior
        # `register_app!` routes, which is otherwise invisible.
        @info "RemoteProxy: BRIDGE built" prefix = BRIDGE[].parent.id
    end
    return BRIDGE[].parent.id
end

"""
    dial_loop(wsurl, handshake; min_backoff=0.5, max_backoff=8.0)

Run the dial-and-serve loop until BRIDGE[] goes away. Each iteration opens a
fresh websocket to `wsurl`, sends the `handshake` line, and runs `serve_bridge`.
When the socket dies (clean EOF, network drop, host restart), we sleep with
exponential backoff and dial again — so a transient WS drop doesn't leave the
bridge silently disconnected. `BRIDGE[].routes` survives the drop, so
already-registered apps keep working on the new socket (the host recognises the
dial-back as a *reconnect* by `prefix` and swaps the WS rather than rebuilding).
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
    d.ws[] = ws
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
        d.ws[] = nothing
    end
    return
end

# Control request/response (the only ops that aren't a plain frame).
#
# The request-shaped ops (`delegate`, `asset_read`, `register`) carry an `id` the
# host waits on. Any exception below MUST come back as a reply with an `err` field
# — otherwise the host's `call_ctrl` only learns about the failure after a 30s
# timeout, freezing the chat tool-render path. Notifications (`close`) carry no id.
function handle_control(b::RemoteBridge, msg::AbstractDict)
    op = msg["op"]
    d = b.driver
    id = get(msg, "id", nothing)
    try
        if op == "delegate"
            # `page` = the host's root session id (absent from old hosts → "",
            # which keeps today's single-page behavior).
            sub_id, html, init_url = render_embed(b, String(msg["app"]),
                                                  String(get(msg, "page", "")))
            send_control(d, Dict("op" => "reply", "id" => id,
                                 "val" => Any[sub_id, html, init_url]))
        elseif op == "asset_read"
            bytes = Bonito.read_proxy_asset(b.parent.asset_server.registry,
                        String(msg["key"]), Int(msg["start"]), Int(msg["stop"]))
            send_control(d, Dict("op" => "reply", "id" => id, "val" => bytes))
        elseif op == "register"
            app = Base.include_string(Main, String(msg["code"]))
            register_app!(String(msg["app"]), app)
            send_control(d, Dict("op" => "reply", "id" => id, "val" => String(msg["app"])))
        elseif op == "asset_url"
            # Expose a worker-disk file to the browser through the NORMAL proxy
            # asset path: `url` registers a `Bonito.Asset` on the bridge's asset
            # server and fires `asset_add`, so the host builds the matching
            # `RemoteAsset` and serves `/assets/<key>` with on-demand range reads.
            # Returns that host-relative url to drop into a plain <img>/<video>
            # src — no App/subsession needed for media.
            url = Bonito.url(b.parent.asset_server, Bonito.Asset(abspath(String(msg["path"]))))
            send_control(d, Dict("op" => "reply", "id" => id, "val" => url))
        elseif op == "close"
            s = Bonito.get_session(b.parent, String(msg["sub"]))
            s === nothing || close(s)
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

# ── App registration + per-embed render ──────────────────────────────────────
register_app!(id::AbstractString, app::Bonito.App) =
    (Bonito.HTTPServer.route!(BRIDGE[], String(id) => app); nothing)

Bonito.HTTPServer.route!(b::RemoteBridge, p::Pair{String, <:Bonito.App}) =
    (b.routes[p.first] = p.second; nothing)

# Cache of (sub_id, html, init_url) bundles rendered at `bt_show_app` time,
# keyed by app id. The first `delegate` returns the cached bundle verbatim;
# subsequent delegates (re-expand, new tab) render fresh.
#
# Lifecycle / messages: `render_and_pack` drains `sub.message_queue` into the
# bundle, but the sub stays alive in `b.parent.children`. Any messages emitted
# AFTER the drain (Observable updates, plots that hand the session a Channel,
# etc.) sit in the post-drain queue. When the browser mounts the bundle and
# fires `JSDoneLoading`, the parent's protocol dispatcher routes it to this
# sub, which invokes the default `on_connection_ready = init_session` —
# `connection_ready` flips, `OPEN` is set, the post-drain queue flushes over
# the dial-back. No need for the worker to keep a stash and drain later: the
# queue-then-flush contract handles the entire window between render and
# JSDoneLoading naturally.
const PRERENDERED = Dict{String, Tuple{String,String,String}}()

# Render an app into a fresh subsession and pack its init bundle. Re-raises
# any init/render error recorded on `sub.init_error[]` (by Bonito's
# `handle_render_error`) so a broken `App`/`jsrender` body propagates to the
# agent at `bt_show_app` time rather than only painting into the browser.
# Drains messages here — late messages flow through Bonito's flush-on-open
# (`JSDoneLoading` → `init_session(sub)`).
function render_and_pack(b::RemoteBridge, app_id::AbstractString)
    app = b.routes.routes[String(app_id)]
    sub, dom = Bonito.render_subsession(b.parent, app; init = false)
    err = sub.init_error[]
    if err !== nothing
        try; close(sub); catch; end
        throw(err)
    end
    html     = sprint(io -> show(io, dom))
    msgs     = Bonito.get_messages!(sub)
    init_url = Bonito.url(sub, Bonito.BinaryAsset(sub, msgs))
    return String(sub.id), html, init_url
end

# Called by `bt_show_app` right after `register_app!`. Renders once, caches the
# bundle for the first display. A throwing App body re-raises here, so the
# agent's tool errors propagate at bt_show_app time instead of being a silent
# "broken bubble appears later".
function prerender_app(id::AbstractString)
    b = BRIDGE[]
    b === nothing && error("RemoteProxy bridge not installed")
    PRERENDERED[String(id)] = render_and_pack(b, String(id))
    return nothing
end

"""
    switch_page!(b, page) -> Bool

Reset the bridge's serialization state when the browser PAGE changes.

The bridge parent is a long-lived ROOT session that serves many pages over
its lifetime (reloads, later tabs). Bonito's serialization dedups against the
root's `session_objects` and ships a bare `TrackingOnly` reference for
anything already sent — an assumption that holds per PAGE, not per bridge:
after a reload the browser's global object cache is empty, so a bundle built
against the old cache references objects the page never received. The DOM
still mounts (it rides in the html fragment), observables still round-trip,
but every CACHED payload — plot buffers, textures, attribute dicts — is
silently missing; a re-mounted WGLMakie embed shows an eternal spinner with
no error anywhere.

So each `delegate` names the page (the host's root session id); when it
differs from the page the cache reflects, we close the previous page's
subsessions (their browser side is gone) and drop ALL of the parent's
page-lifetime state — object cache, asset/style emission dedup, root
metadata — so the next bundle ships full values against a blank page again.

Known limitation: two pages alternating over ONE bridge reset each other's
cache and close each other's live subs — the fix for that is a per-page
parent session, which needs Bonito-side support. Before this function, a
second page never worked at all, so this is strictly an improvement.
"""
function switch_page!(b::RemoteBridge, page::AbstractString)
    (isempty(page) || page == b.page) && return false
    if isempty(b.page)
        # First page this bridge serves: the cache state (and any prerendered
        # bundle from registration time) was built FOR whichever page mounts
        # first — adopt it, don't wipe. Only a real page→page transition
        # invalidates the browser-cache assumption.
        b.page = String(page)
        return false
    end
    for (id, child) in collect(b.parent.children)
        try
            close(child)
        catch e
            @warn "RemoteProxy: closing stale page subsession failed" id exception = e
        end
    end
    root = b.parent
    lock(root.deletion_lock) do
        for key in collect(keys(root.session_objects))
            Bonito.force_delete!(root, key)
        end
        # Asset emission: pre-#406 Bonito deduped sub emissions against
        # `root.imports` "for the page's lifetime" — on a BRIDGE root that
        # outlives many pages, a new page's embed fragment then omitted e.g.
        # the WGLMakie module script (module never loads, `$(WGL).then(...)`
        # pends forever, black canvas, zero errors). Bonito#406 made subs
        # re-emit their own imports (no union into root), so these sets stay
        # empty for subs — clearing is now belt-and-suspenders for anything
        # the root itself emitted and for older Bonito semantics.
        empty!(root.imports)
        empty!(root.global_stylesheets)
        # Root metadata is page-lifetime state too: integrations persist
        # browser-mirrored counters here. WGLMakie's `get_order!` keeps
        # `:wglmakie_scene_order` on the root, mirrored by a module-level
        # `orderedExecutor.nextExpected` counter in its JS — which a reload
        # resets to 1. A remount then ships order N>1 and `execute_in_order`
        # waits forever for the N-1 slots that died with the old page:
        # `setup_scene_init` never runs, the canvas is never measured, no
        # `real_size` notify, no scene (black canvas, zero errors).
        empty!(root.metadata)
    end
    # Prerendered bundles were built against the old cache state — void now.
    empty!(PRERENDERED)
    b.page = String(page)
    return true
end

# Render-or-reuse for the host's `delegate` call: cached bundle if any
# (consumed by this delegate), otherwise render fresh. `page` identifies the
# requesting browser page; a page change resets the dedup cache first (which
# also discards prerendered bundles, so a stale one can never be served to a
# page whose object cache doesn't match it).
function render_embed(b::RemoteBridge, app_id::AbstractString, page::AbstractString = "")
    switch_page!(b, page)
    cached = pop!(PRERENDERED, String(app_id), nothing)
    return cached === nothing ? render_and_pack(b, String(app_id)) : cached
end

end # module RemoteProxy
