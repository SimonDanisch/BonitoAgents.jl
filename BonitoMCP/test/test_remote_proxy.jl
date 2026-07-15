# Headless unit test for the WORKER side of the remote-app bridge (RemoteProxy.jl)
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
# refactor would touch: the connection's write→frame path, render_embed's
# namespaced subsession + init bundle, the ProxyAssetServer asset push, and the
# control plane (delegate / register / close).

using Test
import Bonito
using Bonito: Session, App, DOM, Observable, on, onjs, @js_str, process_message,
              connection, get_session, root_session, MsgPack
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

    @testset "render_embed: namespaced subsession + init bundle on the asset server" begin
        b, cap = fresh_bridge!()
        prefix = b.parent.id
        o = Observable(0)
        RP.register_app!("app1", App(s -> (onjs(s, o, js"(x)=>{}"); DOM.div(DOM.span(o)))))

        sub_id, html, init_url = RP.render_embed(b, "app1")
        @test startswith(sub_id, prefix * "/")        # subsession id namespaced under the bridge
        @test !isempty(html)
        @test occursin(prefix, html)                  # fragment carries the bridge namespace
        @test !isempty(init_url)
        @test get_session(b.parent, sub_id) !== nothing

        # The init bundle registered on the bridge's ProxyAssetServer, which pushed
        # an `asset_add` control frame down the (captured) socket.
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
        RP.register_app!("rt", app)
        sub_id, _, _ = RP.render_embed(b, "rt")
        sub = get_session(b.parent, sub_id)

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

    @testset "control plane: register → delegate → close" begin
        b, cap = fresh_bridge!()
        prefix = b.parent.id

        # register: ship app source, worker include_strings + registers it.
        RP.handle_control(b, Dict{String,Any}("op"=>"register","id"=>1,"app"=>"reg1",
            "code"=>"using Bonito; Bonito.App(s -> Bonito.DOM.div(\"hi\"))"))
        reg_reply = only(filter(d -> get(d,"op","")=="reply" && get(d,"id",0)==1, ctrl_frames(cap)))
        @test reg_reply["val"] == "reg1"

        # delegate: render it into a subsession, reply (sub_id, html, init_url).
        RP.handle_control(b, Dict{String,Any}("op"=>"delegate","id"=>2,"app"=>"reg1"))
        del_reply = only(filter(d -> get(d,"op","")=="reply" && get(d,"id",0)==2, ctrl_frames(cap)))
        @test !haskey(del_reply, "err")
        sub_id = String(del_reply["val"][1])
        @test startswith(sub_id, prefix * "/")
        @test get_session(b.parent, sub_id) !== nothing

        # close: tears the subsession down.
        RP.handle_control(b, Dict{String,Any}("op"=>"close","sub"=>sub_id))
        @test timedwait(() -> get_session(b.parent, sub_id) === nothing, 5.0) === :ok

        # A delegate for an unknown app must reply with an `err` (so the host's
        # call_ctrl fails fast instead of a 30s hang) BEFORE rethrowing — the
        # rethrow is by design (serve_bridge's @async wrapper logs the trace), so
        # here we swallow it and assert the err reply went out first.
        try
            RP.handle_control(b, Dict{String,Any}("op"=>"delegate","id"=>3,"app"=>"does-not-exist"))
        catch
        end
        err_reply = only(filter(d -> get(d,"op","")=="reply" && get(d,"id",0)==3, ctrl_frames(cap)))
        @test haskey(err_reply, "err")
    end

    @testset "bridge + routes survive a socket drop and redial" begin
        b, _ = fresh_bridge!()
        b.driver.ws[] = nothing                       # pre-dial: no socket
        RP.register_app!("survivor", App(s -> DOM.div("x")))

        # Dial 1: serve on a socket, then drop it. serve_bridge owns the ws for the
        # socket's lifetime and clears it on exit — it does NOT tear the bridge down.
        cap1 = CapWS()
        t1 = @async RP.serve_bridge(cap1)
        @test timedwait(() -> b.driver.ws[] === cap1, 3.0) === :ok
        close(cap1)
        @test timedwait(() -> istaskdone(t1), 3.0) === :ok
        @test b.driver.ws[] === nothing               # socket cleared, BRIDGE intact

        # Dial 2 (same BRIDGE[], no rebuild): the registered app + routes survived
        # the drop, so it still renders on the new socket. This is the invariant the
        # dial_loop reconnect relies on (host swaps the WS, routes intact).
        cap2 = CapWS()
        t2 = @async RP.serve_bridge(cap2)
        @test timedwait(() -> b.driver.ws[] === cap2, 3.0) === :ok
        sub_id, _, _ = RP.render_embed(b, "survivor")
        @test startswith(sub_id, b.parent.id * "/")
        close(cap2); wait(t2)
    end

    @testset "page change resets the dedup cache (reload -> self-contained bundle)" begin
        # Regression: the bridge parent is a long-lived ROOT session, and
        # Bonito's serialization dedups against its `session_objects`, sending
        # bare TrackingOnly references for anything already shipped. That
        # assumption holds per browser PAGE, not per bridge: after a reload the
        # page's global object cache is empty, so a re-mounted embed got
        # references to objects it never received — DOM up, observables alive,
        # but every cached payload missing (the eternal-spinner WGLMakie embed).
        # `delegate` now names the page and `switch_page!` resets the cache on
        # a page change, making the first bundle per page self-contained.
        b, cap = fresh_bridge!()
        marker = "PAGE_CACHE_MARKER_" * "x"^64
        payload = Observable(marker)
        RP.register_app!("pg", App(s -> (onjs(s, payload, js"(x)=>{}");
                                         DOM.div(DOM.span("app")))))

        bundle_bytes(init_url) = begin
            key = first(split(last(split(init_url, '/')), '?'))
            Bonito.read_proxy_asset(b.parent.asset_server.registry, String(key))
        end
        has_marker(bytes) = occursin(marker, String(copy(bytes)))

        # Page 1, first mount: the bundle carries the observable's VALUE.
        _, _, url1 = RP.render_embed(b, "pg", "page-1")
        @test has_marker(bundle_bytes(url1))
        # Page 1, second mount: dedup is correct within a page — no re-ship.
        _, _, url2 = RP.render_embed(b, "pg", "page-1")
        @test !has_marker(bundle_bytes(url2))
        # Page 2 = a reload: the bundle must be self-contained again (this is
        # exactly the assertion that failed before switch_page!).
        _, _, url3 = RP.render_embed(b, "pg", "page-2")
        @test has_marker(bundle_bytes(url3))
        @test b.page == "page-2"
        # A prerendered bundle from the old page must never be served across a
        # page switch: it was built against the old cache state.
        RP.prerender_app("pg")                      # built for page-2's cache
        _, _, url4 = RP.render_embed(b, "pg", "page-3")
        @test has_marker(bundle_bytes(url4))
        # No page named (old host) -> no reset, dedup persists (back-compat).
        _, _, url5 = RP.render_embed(b, "pg")
        @test !has_marker(bundle_bytes(url5))

        # JS module emission: every embed fragment must be SELF-CONTAINED —
        # the <script type=module> tag has to ride along wherever the
        # fragment mounts. The original failure mode was a WGLMakie embed
        # whose module script was omitted after a reload because pre-#406
        # Bonito deduped emission against `root.imports` "for the page's
        # lifetime" while the bridge root outlived the page (module never
        # loads, scene never builds, spinner forever, no error anywhere).
        # Bonito#406 changed the model — subs re-emit their own imports and
        # never union into the root — so we assert per-page self-containment
        # only, NOT same-page dedup (version-dependent, and duplicate module
        # tags are idempotent in the browser's module registry anyway).
        js_file = joinpath(mktempdir(), "probemod.js")
        write(js_file, "export function probe() { return 42; }\n")
        probemod = Bonito.ES6Module(js_file)
        RP.register_app!("imp", App(s -> DOM.div(Bonito.jsrender(s,
            js"\$(probemod).then(m => m.probe())"))))
        _, html1, _ = RP.render_embed(b, "imp", "page-4")
        @test occursin("probemod", html1)             # first page ships the module
        _, html3, _ = RP.render_embed(b, "imp", "page-5")
        @test occursin("probemod", html3)             # a NEW page ships it too

        # Root METADATA is page-lifetime state too: integrations keep counters
        # there that mirror module-level JS state, which a reload resets.
        # WGLMakie's `get_order!` is the canonical case: it increments
        # `:wglmakie_scene_order` on the root, and the JS `orderedExecutor`
        # (fresh per page, nextExpected = 1) queues every scene init until the
        # counter it expects arrives. A remount shipping order N>1 to a fresh
        # page therefore waits forever — `setup_scene_init` never runs, the
        # canvas is never measured, no scene is ever requested: a black canvas
        # with zero errors anywhere. A page switch must drop root metadata so
        # per-page counters restart in lockstep with the page's JS.
        Bonito.set_metadata!(b.parent, :wglmakie_scene_order, 7)
        RP.render_embed(b, "imp", "page-6")
        @test Bonito.get_metadata(b.parent, :wglmakie_scene_order, 1) == 1
        # Same page: metadata persists (in-page renders must keep counting up).
        Bonito.set_metadata!(b.parent, :wglmakie_scene_order, 3)
        RP.render_embed(b, "imp", "page-6")
        @test Bonito.get_metadata(b.parent, :wglmakie_scene_order, 1) == 3
    end
end
