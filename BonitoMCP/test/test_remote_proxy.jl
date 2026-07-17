# Headless unit test for the WORKER side of the remote bridge (RemoteProxy.jl)
# in isolation — no real eval worker, no Malt, no dial-back socket, no browser.
#
# The dial-back websocket is replaced by `CapWS`, a fake that records every frame
# the worker sends (so we can assert on worker→browser traffic) and can be fed
# inbound frames. Inbound browser→worker frames are driven straight through
# `process_message` on the bridge's session (exactly how Bonito's own proxy.jl
# test and BonitoAgents's test_real_e2e drive the host side), so we exercise the
# real render + observable round-trip without standing up the whole stack.
#
# This guards the pieces a "reuse Bonito's ProxyConnection / render_proxied"
# refactor would touch: `render_eval_html`'s namespaced subsession + init bundle,
# the connection's write→frame path, the ProxyAssetServer asset push, and the
# control plane (asset_read / asset_url / close). The bt_julia_eval RESULT render
# (`render_eval_html`) is the only render path on the bridge now — there is no
# app registry / delegate.

using Test
import Bonito
using Bonito: Session, App, DOM, Observable, on, onjs, @js_str, process_message,
              connection, get_session, root_session, MsgPack, show_html
using Bonito.HTTP.WebSockets: WebSockets

include(joinpath(@__DIR__, "..", "src", "RemoteProxy.jl"))
const RP = RemoteProxy

# ── A fake dial-back websocket: captures sent frames, can deliver inbound ones ──
mutable struct CapWS
    sent::Vector{Vector{UInt8}}
    inbound::Channel{Vector{UInt8}}
    closed::Bool
end
CapWS() = CapWS(Vector{UInt8}[], Channel{Vector{UInt8}}(256), false)
WebSockets.send(ws::CapWS, buf) = (push!(ws.sent, collect(buf)); nothing)
WebSockets.isclosed(ws::CapWS) = ws.closed
Base.close(ws::CapWS) = (ws.closed = true; close(ws.inbound); nothing)
# `for msg in ws` in serve_bridge: yield inbound frames until closed+drained.
function Base.iterate(ws::CapWS, st = nothing)
    try
        return (take!(ws.inbound), nothing)
    catch
        return nothing      # channel closed → end the loop
    end
end

# Split a captured worker frame into (tag, payload).
untag(frame) = (frame[1], @view frame[2:end])
# Control dicts the worker sent (tag 'C') — plain msgpack, not SerializedMessages.
ctrl_frames(ws::CapWS) = [MsgPack.unpack(collect(p)) for (t, p) in untag.(ws.sent) if t == RP.TAG_CTRL]

# Worker→browser data frames are SerializedMessages: EXT → [session, status, cache,
# dataExt], dataExt wrapping the message dict. Decode like the JS side does
# (mirrors decode_sm/collect_updates in Bonito's own proxy.jl test).
const EXT_BIN_TAG = Int8(0x12)
function decode_sm(x)
    ext = x isa MsgPack.Extension ? x : MsgPack.unpack(x)
    ext isa MsgPack.Extension || return ext
    inner = MsgPack.unpack(ext.data)
    de = inner[4]
    return (de isa MsgPack.Extension && de.type == EXT_BIN_TAG) ? MsgPack.unpack(de.data) : de
end
# Every UpdateObservable (id => payload) in the captured data frames, flattening
# FusedMessage bundles.
function updates(ws::CapWS)
    out = Pair{String,Any}[]
    for (t, p) in untag.(ws.sent)
        t == RP.TAG_DATA || continue
        d = decode_sm(collect(p))
        d isa AbstractDict || continue
        if d["msg_type"] == "9"
            for s in get(d, "payload", [])
                m = decode_sm(s)
                m isa AbstractDict && m["msg_type"] == "0" && push!(out, m["id"] => m["payload"])
            end
        elseif d["msg_type"] == "0"
            push!(out, d["id"] => d["payload"])
        end
    end
    out
end

# Render an App(value) as a subsession of the bridge parent — exactly what
# `render_eval_html` does — and hand back the live subsession so the test can
# drive the browser→worker round-trip against it. `render_eval_html` itself only
# returns the HTML string; we re-create its parent + the freshly-rendered sub
# here so we can reach the Session object.
function render_app_sub(b, app)
    sub, dom = Bonito.render_subsession(b.parent, app; init = false)
    return sub, dom
end

# Fresh bridge + capture ws for each testset (BRIDGE[] is a process singleton).
function fresh_bridge!()
    RP.BRIDGE[] = nothing
    RP.ensure_bridge!()
    b = RP.BRIDGE[]
    cap = CapWS()
    b.driver.ws[] = cap            # outbound frames now captured
    return b, cap
end

@testset "RemoteProxy worker bridge (headless)" begin

    @testset "render_eval_html: namespaced subsession + init bundle on the asset server" begin
        b, cap = fresh_bridge!()
        prefix = b.parent.id
        o = Observable(0)
        app = App(s -> (onjs(s, o, js"(x)=>{}"); DOM.div(DOM.span(o))))

        # `render_eval_html` renders App(value) as a subsession of the bridge
        # parent and returns its HTML fragment — the only render path now.
        html = RP.render_eval_html(app)
        @test !isempty(html)
        @test occursin(prefix, html)                  # fragment carries the bridge namespace

        # Rendering a subsession registers its init bundle on the bridge's
        # ProxyAssetServer, which pushes an `asset_add` control frame down the
        # (captured) socket.
        adds = filter(d -> get(d, "op", "") == "asset_add", ctrl_frames(cap))
        @test !isempty(adds)
    end

    @testset "round trip: browser update → worker observable reacts → relayed back" begin
        b, cap = fresh_bridge!()
        prefix = b.parent.id
        clicks  = Observable(0)
        doubled = Observable(0)
        app = App() do s
            on(s, clicks) do c; doubled[] = 2c; end
            onjs(s, clicks,  js"(x)=>{}")
            onjs(s, doubled, js"(x)=>{}")
            DOM.div(DOM.span(doubled))
        end
        sub, _ = render_app_sub(b, app)
        sub_id = sub.id
        @test startswith(sub_id, prefix * "/")        # subsession id namespaced under the bridge

        # Browser says the subsession finished loading → it goes ready + flushes.
        process_message(b.parent, Dict{String,Any}("msg_type"=>"8","session"=>sub_id,"exception"=>"nothing"))
        @test timedwait(() -> isready(sub; throw=false), 5.0) === :ok
        empty!(cap.sent)                              # isolate the update relay

        # Browser → worker: update `clicks` by its namespaced id.
        process_message(b.parent, Dict{String,Any}("msg_type"=>"0","id"=>"$prefix/$(clicks.id)","payload"=>5))
        @test clicks[]  == 5                          # reached the real worker observable
        @test doubled[] == 10                         # worker-side reaction fired

        # Worker → browser: the derived update relayed with the namespaced id.
        want = "$prefix/$(doubled.id)" => 10
        @test timedwait(() -> want in updates(cap), 5.0) === :ok
    end

    @testset "control plane: asset_url + close" begin
        b, cap = fresh_bridge!()
        prefix = b.parent.id

        # asset_url: expose a worker-disk file as a proxied asset, reply its url.
        tmp = tempname() * ".txt"
        write(tmp, "hello bridge")
        RP.handle_control(b, Dict{String,Any}("op"=>"asset_url","id"=>1,"path"=>tmp))
        url_reply = only(filter(d -> get(d,"op","")=="reply" && get(d,"id",0)==1, ctrl_frames(cap)))
        @test !haskey(url_reply, "err")
        @test occursin("/assets/", String(url_reply["val"]))

        # Registering the asset pushed an `asset_add` control frame.
        @test !isempty(filter(d -> get(d, "op", "") == "asset_add", ctrl_frames(cap)))

        # close: tears a subsession down. Render one first to have a sub to close.
        sub, _ = render_app_sub(b, App(s -> DOM.div("x")))
        sub_id = sub.id
        @test get_session(b.parent, sub_id) !== nothing
        RP.handle_control(b, Dict{String,Any}("op"=>"close","sub"=>sub_id))
        @test timedwait(() -> get_session(b.parent, sub_id) === nothing, 5.0) === :ok

        # An unknown asset key is GRACEFUL: `read_proxy_asset` returns empty bytes,
        # so the reply carries `val` (empty), never `err` — and never a 30s hang.
        RP.handle_control(b, Dict{String,Any}("op"=>"asset_read","id"=>3,
            "key"=>"does-not-exist","start"=>0,"stop"=>1))
        ok_reply = only(filter(d -> get(d,"op","")=="reply" && get(d,"id",0)==3, ctrl_frames(cap)))
        @test !haskey(ok_reply, "err")   # graceful: carries a (here empty) `val`, not an error
        @test haskey(ok_reply, "val")

        # A genuinely malformed control request (here: missing `key`) MUST reply with
        # an `err` (so the host's call_ctrl fails fast instead of a 30s hang) BEFORE
        # rethrowing — the rethrow is by design (serve_bridge's @async wrapper logs
        # the trace), so here we swallow it and assert the err reply went out first.
        try
            RP.handle_control(b, Dict{String,Any}("op"=>"asset_read","id"=>4,
                "start"=>0,"stop"=>1))
        catch
        end
        err_reply = only(filter(d -> get(d,"op","")=="reply" && get(d,"id",0)==4, ctrl_frames(cap)))
        @test haskey(err_reply, "err")
    end

    @testset "bridge survives a socket drop and redial" begin
        b, _ = fresh_bridge!()
        b.driver.ws[] = nothing                       # pre-dial: no socket

        # Dial 1: serve on a socket, then drop it. serve_bridge owns the ws for the
        # socket's lifetime and clears it on exit — it does NOT tear the bridge down.
        cap1 = CapWS()
        t1 = @async RP.serve_bridge(cap1)
        @test timedwait(() -> b.driver.ws[] === cap1, 3.0) === :ok
        close(cap1)
        @test timedwait(() -> istaskdone(t1), 3.0) === :ok
        @test b.driver.ws[] === nothing               # socket cleared, BRIDGE intact

        # Dial 2 (same BRIDGE[], no rebuild): the parent session + asset server
        # survived the drop, so a fresh result still renders on the new socket.
        # This is the invariant the dial_loop reconnect relies on (host swaps the
        # WS, bridge intact).
        cap2 = CapWS()
        t2 = @async RP.serve_bridge(cap2)
        @test timedwait(() -> b.driver.ws[] === cap2, 3.0) === :ok
        sub, _ = render_app_sub(b, App(s -> DOM.div("survivor")))
        @test startswith(sub.id, b.parent.id * "/")
        close(cap2); wait(t2)
    end

    @testset "every render is self-contained (no cross-mount dedup on the proxied root)" begin
        # The bridge parent is a long-lived ROOT session that outlives browser
        # pages (reloads, later tabs). Stock Bonito dedups serialization
        # against the root's `session_objects` and ships bare TrackingOnly
        # references for anything already sent — an assumption that holds per
        # PAGE, not per bridge: after a reload the page's object cache is
        # empty, so a re-mounted embed would reference objects the fresh page
        # never received (DOM up, observables alive, every cached payload
        # silently missing — the eternal-spinner WGLMakie embed).
        #
        # Ours resolves this at the SERIALIZATION layer instead of tracking
        # pages: proxied roots opt out of dedup entirely (dev Bonito's
        # `dedup_cached_objects(::Session{<:ProxyConnection}) = false`), so
        # EVERY mount — first, re-expand, post-reload — ships full values.
        # (Root METADATA hazards went with `get_order!`: GlyphSync ships glyph
        # batches as root evaljs and the page PULLS whatever it lacks.)
        b, cap = fresh_bridge!()
        marker = "PAGE_CACHE_MARKER_" * "x"^64
        payload = Observable(marker)
        mkapp() = App(s -> (onjs(s, payload, js"(x)=>{}");
                            DOM.div(DOM.span("app"))))

        # Self-contained ≡ the marker VALUE rides in the fragment itself or in
        # the init bundle its render registered on the proxy asset server.
        shipped_marker(html) = begin
            occursin(marker, html) && return true
            adds = filter(d -> get(d, "op", "") == "asset_add", ctrl_frames(cap))
            any(adds) do d
                bytes = Bonito.read_proxy_asset(b.parent.asset_server.registry,
                                                String(d["key"]))
                occursin(marker, String(copy(bytes)))
            end
        end

        # First mount ships the observable's value...
        @test shipped_marker(RP.render_eval_html(mkapp()))
        empty!(cap.sent)
        # ...and so does every LATER mount of the same shared observable — the
        # assertion that failed on stock dedup after a page reload.
        @test shipped_marker(RP.render_eval_html(mkapp()))

        # JS module emission: every fragment must carry its <script type=module>
        # tag wherever it mounts. Pre-Bonito#406 sub emissions were deduped
        # against `root.imports` "for the page's lifetime" — on a bridge root
        # outliving pages, a post-reload fragment omitted e.g. the WGLMakie
        # module script (module never loads, `$(WGL).then(...)` pends forever,
        # black canvas, zero errors). #406 made subs re-emit their own imports;
        # duplicate module tags are idempotent in the browser's registry.
        js_file = joinpath(mktempdir(), "probemod.js")
        write(js_file, "export function probe() { return 42; }\n")
        probemod = Bonito.ES6Module(js_file)
        impapp() = App(s -> DOM.div(Bonito.jsrender(s,
            js"$(probemod).then(m => m.probe())")))
        @test occursin("probemod", RP.render_eval_html(impapp()))
        @test occursin("probemod", RP.render_eval_html(impapp()))   # re-emitted, never deduped away
    end
end
