# REAL end-to-end, headless: a live dev_server() + the actual bt_show_app MCP
# tool handler. The handler spawns a real eval Malt.Worker, which dials back over
# the real /eval-ws WebSocket route, evaluates the app, and the server embeds it
# into a chat with a full browser-driven round-trip. The only parts simulated are
# the LLM deciding to call bt_show_app and the agent→ACP→ToolMsg relay (BonitoAgents's
# existing, tested machinery) — and the browser pixels. No Electron.
using Test
import BonitoAgents, BonitoMCP
const BT = BonitoAgents; const Malt = BonitoAgents.Malt
const ACP = BonitoAgents.AgentClientProtocol
import Bonito
using Bonito: Session, connection, process_message
const ROOT = "/sim/Programmieren/ClaudeExperiments"

# The EvalBridge no longer holds a Malt handle — the dial-back is raw Bonito frames,
# not Malt. To introspect the worker's globals/bridge in tests we reach it through
# BonitoMCP's OWN Malt link (the eval worker IS a BonitoMCP worker).
function root_worker()
    for s in values(BonitoMCP.manager().sessions)
        s.env_path == ROOT && BonitoMCP.is_alive(s) && return s.worker
    end
    error("no live ROOT eval worker")
end

mutable struct CapConn <: Bonito.FrontendConnection; frames::Vector{Vector{UInt8}}; end
CapConn() = CapConn(Vector{UInt8}[])
Base.write(c::CapConn, b::AbstractVector{UInt8}) = (push!(c.frames, collect(b)); nothing)
Base.isopen(::CapConn) = true
Base.close(::CapConn) = nothing
Bonito.setup_connection(::Session{CapConn}) = nothing
const EXT_BIN = Int8(0x12)
function decode_sm(x)
    ext = x isa Bonito.MsgPack.Extension ? x : Bonito.MsgPack.unpack(x)
    ext isa Bonito.MsgPack.Extension || return ext
    inner = Bonito.MsgPack.unpack(ext.data); de = inner[4]
    (de isa Bonito.MsgPack.Extension && de.type == EXT_BIN) ? Bonito.MsgPack.unpack(de.data) : de
end
updates_in(frames) = begin
    out = Pair{String,Any}[]
    for f in frames; d=decode_sm(f); d isa AbstractDict || continue
        if d["msg_type"]=="9"; for s in get(d,"payload",[]); m=decode_sm(s); m isa AbstractDict && m["msg_type"]=="0" && push!(out,m["id"]=>m["payload"]); end
        elseif d["msg_type"]=="0"; push!(out,d["id"]=>d["payload"]); end
    end; out
end

const APPCODE = """
using Bonito
global E2E_COUNT = Bonito.Observable(0)
global E2E_DOUBLED = Bonito.Observable(0)
Bonito.App() do s
    Bonito.on(s, E2E_COUNT) do c; E2E_DOUBLED[] = 2c; end
    Bonito.onjs(s, E2E_COUNT, Bonito.@js_str("(x)=>{}"))
    Bonito.onjs(s, E2E_DOUBLED, Bonito.@js_str("(x)=>{}"))
    Bonito.DOM.div("counter = ", Bonito.DOM.span(E2E_DOUBLED; id="result"))
end
"""

@testset "REAL e2e: dev_server + bt_show_app + dial-back + embed" begin
    h = BT.dev_server()
    try
        pid = "e2e-" * string(rand(UInt16))
        env = BT.eval_dialback_env(h.state, pid)
        for (k,v) in env; ENV[k] = v; end           # the server normally injects these into BonitoMCP
        # In production this is set by the BonitoWorker daemon. Here we plug it
        # in from the local dev server's URL so BonitoMCP can derive `/eval-ws`.
        ENV["BONITOAGENTS_SERVER_URL"] = Bonito.online_url(h.state.srv, "")
        @test startswith(ENV["BONITOAGENTS_SERVER_URL"], "http://")
        # Drop any eval worker from a previous test — its `__BT_DIALED` is true
        # against the OLD dev_server's WS that's long gone, so without a fresh
        # worker it won't dial THIS dev_server's `/eval-ws`.
        BonitoMCP.restart!(BonitoMCP.manager(), ROOT)

        # === the ACTUAL bt_show_app tool handler (what the agent invokes) ===
        res = BonitoMCP.julia_show_app_handler(Dict("code"=>APPCODE, "env_path"=>ROOT))
        text = res["content"][1]["text"]
        println("bt_show_app returned: ", text)
        @test res["isError"] == false
        @test startswith(text, "shown_app: ")
        appid = String(strip(replace(text, "shown_app:"=>"")))

        # the eval worker dialed the dev_server's /eval-ws and is driveable
        @test timedwait(()->haskey(BT.EVAL_WORKERS, pid), 30.0) === :ok
        eb = BT.EVAL_WORKERS[pid]                       # EvalBridge (raw-frame bridge)
        iow = root_worker()                              # worker introspection via BonitoMCP's link
        @test Malt.remote_eval_fetch(iow, :(1+1)) == 2

        # === server side: the shown_app ToolMsg → render_tool_body → embed ===
        model = BT.ChatModel(h.state, mktempdir(); project_id=pid, transport=BT.MockTransport((o,i)->nothing))
        toolid = string(Bonito.uuid4())
        tc = ACP.GenericTool(toolid, "mcp", "bt_show_app", "completed",
                              ACP.ToolContent[ACP.TextContent("shown_app: $appid")], Channel{ACP.ToolCall}(1))
        BT.persist_tool_content!(model.chat_dir, tc)
        tm = BT.GenericToolMsg(toolid, "mcp", "bt_show_app", "completed", "",
                                0.0, 0.0, nothing)
        body = BT.render_tool_body(h.state, tm, model.cwd, model.chat_dir; project_id=pid)
        # render_tool_body wraps the live embed in the detach frame, so the
        # RemoteAppPlaceholder is nested in the returned DOM rather than the body
        # itself. Assert it produced the LIVE embed (placeholder bound to the
        # EvalBridge), not the "(live app unavailable)" fallback.
        bodystr = sprint(show, body)
        @test occursin("RemoteAppPlaceholder", bodystr)
        @test !occursin("unavailable", bodystr)

        host = Session(CapConn(); compression_enabled=false)
        rwa = BT.embed_remote_app(host, eb, appid)       # embeds the live worker app
        sub_id        = rwa.session_id                   # browser-side init_session id (= sub.id)
        bridge_prefix = rwa.bridge_prefix                # cache_key namespace (= bridge.parent.id)
        count_key = "$bridge_prefix/$(Malt.remote_eval_fetch(iow, :(E2E_COUNT.id)))"

        # === browser-driven round-trip ===
        process_message(host, Dict{String,Any}("msg_type"=>"8","session"=>sub_id,"exception"=>"nothing"))
        sleep(0.4); empty!(connection(host).frames)
        process_message(host, Dict{String,Any}("msg_type"=>"0","id"=>count_key,"payload"=>5))
        sleep(0.4)
        @test Malt.remote_eval_fetch(iow, :(E2E_COUNT[])) == 5      # worker (separate process) reacted
        @test Malt.remote_eval_fetch(iow, :(E2E_DOUBLED[])) == 10
        hasdoubled()=any(p->p.second in (10,"10"), updates_in(connection(host).frames))
        tl=time()+5; while !hasdoubled() && time()<tl; sleep(0.05); end
        @test hasdoubled()                                          # relayed back to the browser
        println("✓ full chain: bt_show_app → eval worker dial-back → embed → round-trip")
    finally
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
        try; close(h); catch; end
    end
end

# Regression: the init `.bin` asset must keep serving over HTTP after the
# transient render subsession is torn down. The chat mounts a tool body in a
# fresh `dom_in_js` subsession of the tab's root and discards it (`innerHTML=''`)
# on collapse/re-expand. The proxied init `.bin` must live on the bridge's stable
# per-worker `asset_host` (released only when the WORKER sub closes), NOT on the
# render subsession — binding it to the latter 404'd the app on every re-render.
# Drives a REAL HTTP GET, which the round-trip testset above never does.
@testset "REAL e2e: proxied init asset survives render-session teardown" begin
    h = BT.dev_server()
    try
        pid = "e2e-asset-" * string(rand(UInt16))
        env = BT.eval_dialback_env(h.state, pid)
        for (k,v) in env; ENV[k] = v; end
        ENV["BONITOAGENTS_SERVER_URL"] = Bonito.online_url(h.state.srv, "")
        BonitoMCP.restart!(BonitoMCP.manager(), ROOT)
        res = BonitoMCP.julia_show_app_handler(Dict("code"=>APPCODE, "env_path"=>ROOT))
        @test res["isError"] == false
        appid = String(strip(replace(res["content"][1]["text"], "shown_app:"=>"")))
        @test timedwait(()->haskey(BT.EVAL_WORKERS, pid), 30.0) === :ok
        eb = BT.EVAL_WORKERS[pid]

        geturl(p) = Bonito.HTTP.get("http://127.0.0.1:$(h.state.srv.port)$p"; status_exception=false)
        nsubs() = Malt.remote_eval_fetch(root_worker(), :(RemoteProxy.BRIDGE[] === nothing ? 0 : length(RemoteProxy.BRIDGE[].parent.children)))

        # Stable per-tab root; each mount lands in a transient `dom_in_js` sub of it.
        root = Session(CapConn(); compression_enabled=false)
        ssub1 = Session(root)
        rwa1  = BT.embed_remote_app(ssub1, eb, appid)
        @test geturl(rwa1.init_url).status == 200             # serveable while mounted
        @test haskey(eb.asset_host.parent.files, rwa1.init_url)  # on the bridge, not ssub1
        @test nsubs() == 1

        close(ssub1)                                          # transient render sub torn down
        sleep(0.5)
        @test geturl(rwa1.init_url).status == 200             # ← the bug: was 404 here
        @test nsubs() == 1                                    # worker sub untouched by render-sub close

        # Re-render: a fresh `dom_in_js` sub mounts the same app again. New worker
        # sub (own id → no double-free, own init bundle), and the SUPERSEDED mount's
        # worker sub is closed → its asset released.
        ssub2 = Session(root)
        rwa2  = BT.embed_remote_app(ssub2, eb, appid)
        @test rwa2.session_id != rwa1.session_id
        @test geturl(rwa2.init_url).status == 200
        @test timedwait(()->nsubs() == 1, 5.0) === :ok                          # sub1 closed, sub2 live
        @test timedwait(()->!haskey(eb.asset_host.parent.files, rwa1.init_url), 5.0) === :ok

        # Tab close → the live worker sub is closed and its asset released.
        close(root)
        @test timedwait(()->nsubs() == 0, 5.0) === :ok
        @test timedwait(()->!haskey(eb.asset_host.parent.files, rwa2.init_url), 5.0) === :ok
        println("✓ init asset outlives a render-sub teardown; re-render supersedes + tab close release the worker sub")
    finally
        for k in ("BONITOAGENTS_SERVER_URL","BONITOAGENTS_SECRET","BONITOAGENTS_PROJECT_ID"); haskey(ENV,k) && delete!(ENV,k); end
        try; close(h); catch; end
    end
end
nothing
