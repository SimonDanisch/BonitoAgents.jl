# Server-side memory-leak STRESS probe. Hammers the real server-side agent path
# (real MockACP subprocess → real worker_client + AgentClientProtocol connection →
# real ChatModel / msgs_store / tool caches) with MANY turns of RICH per-turn
# content, and samples every accumulating server container + the host RSS, so an
# unbounded grower shows as a rising column. Modes:
#
#   stress  (default): TURNS turns, each emitting TOOLS_PER_TURN tool events +
#           text — pounds msgs_store + tool_content_cache/order + tool_renders.
#   eval    : one bt_julia_eval embed per turn (per-page-root / proxied-asset path).
#   plot    : a WGLMakie plot per turn (heavy glyph/texture assets).
#   reload  : eval + a full page reload each turn (page-root churn).
#
# Run:  DISPLAY=:1 XAUTHORITY=$(ls -t /run/user/1000/xauth_*|head -1) \
#         julia --project=BonitoAgents/test BonitoAgents/test/leak_probe.jl [TURNS] [mode] [tools_per_turn]

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
const BT = TestKit.BT

const APP_ENV = abspath(joinpath(@__DIR__, "evalenv"))
const TURNS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 200
const MODE  = length(ARGS) >= 2 ? ARGS[2] : "stress"
const TPT   = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 25   # tool events per stress turn
const SAMPLE_EVERY = max(1, TURNS ÷ 12)

eval_code(i) = MODE == "plot" ?
    "using WGLMakie; f = scatter(1:10, rand(10) .+ $i; axis=(; title=\"LEAKPROBE$(i)=\")); f" :
    "using Bonito; App() do; c=Observable($i); DOM.div(DOM.span(\"LEAKPROBE$(i)=\"), DOM.span(map(string,c))) end"

# Rich stress turn: a burst of tool pills (execute + edit) + streamed text —
# the shape a chatty real agent produces, which is what fills the per-tool caches.
function stress_turn(i)
    evs = Any[]
    for j in 1:TPT
        push!(evs, TK.tool(; kind = "execute", title = "t$(i).$(j)",
                           content = [TK.text_block("out line $(i).$(j) " * "x"^40)]))
    end
    push!(evs, TK.text("turn $i done"))
    return evs
end

function probe_agent(prompt)
    if MODE == "stress"
        return stress_turn(parse(Int, split(prompt)[end]))
    elseif occursin("eval", lowercase(prompt))
        i = parse(Int, split(prompt)[end])
        return Any[TK.text("eval:"), TK.bt_eval(eval_code(i); env_path = APP_ENV, id = "lp-$i")]
    end
    return [TK.text("echo")]
end

rss_mb() = try parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1e6 catch; -1.0 end
sumf(f, xs) = try sum(f, xs; init = 0) catch; -1 end

# Every accumulating server-side container (host process — where the leak is).
function sample(state)
    ms = collect(values(state.chat_models))
    sh(m) = try BT.shared(m) catch; m end
    getn(m, f) = try length(getfield(sh(m), f)) catch
        try length(getfield(m, f)) catch; 0 end
    end
    pc = tp = 0
    for eb in values(state.eval_workers)
        pc += try length(eb.page_conns) catch; 0 end
        tp += try length(eb.tab_prefix) catch; 0 end
    end
    return (; rss = round(rss_mb(); digits = 1),
              chat_models = length(ms),
              msgs        = sumf(m -> getn(m, :msgs_store), ms),
              tool_cache  = sumf(m -> getn(m, :tool_content_cache), ms),
              cache_order = sumf(m -> getn(m, :tool_cache_order), ms),
              tool_render = sumf(m -> getn(m, :tool_renders), ms),
              pend_subag  = sumf(m -> getn(m, :pending_subagent), ms),
              pend_asks   = sumf(m -> getn(m, :pending_asks), ms),
              pending_rpc = try length(state.pending_rpcs) catch; -1 end,
              bound_lru   = try length(state.bound_lru) catch; -1 end,
              eval_workers = length(state.eval_workers),
              page_conns = pc, tab_prefix = tp)
end

function main()
    server = TK.dev_server(agent = probe_agent)
    try
        TK.open_browser(server)
        state = server.h.state
        pid = TK.new_chat(server; title = "LeakStress")
        TK.open_chat(server, pid)
        TK.wait_for(server, "input", "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 20)
        GC.gc(true); println("baseline: ", sample(state))

        for i in 1:TURNS
            TK.send_message(server, "turn $i")
            if MODE == "stress"
                # Wait until this turn's tool pills have landed in the store (a
                # server-side signal, robust to the virtual scroller unmounting the
                # DOM rows). Lower bound: at least TPT new tool msgs per turn.
                want = i * TPT
                t0 = time()
                while time() - t0 < 60
                    m = get(state.chat_models, pid, nothing)
                    m !== nothing && length(BT.shared(m).msgs_store) >= want && break
                    sleep(0.1)
                end
            else
                pred = MODE == "plot" ?
                    "!!document.querySelector('.bt-tool-msg[data-msg-id*=\"lp-$(i)\"] canvas')" :
                    "document.body.innerText.includes('LEAKPROBE$(i)=')"
                try TK.wait_for(server, "embed $i", pred; timeout = 120) catch; end
                if MODE == "reload"
                    TK.eval_js(server, "location.reload(); true"); sleep(2)
                    TK.wait_for(server, "up", "!!document.querySelector('.bt-sidebar')"; timeout = 30)
                    TK.install_pane_scope!(server); TK.open_chat(server, pid)
                end
            end
            if i % SAMPLE_EVERY == 0
                GC.gc(true)
                println("after $i turns: ", sample(state))
            end
        end
        GC.gc(true); GC.gc(true)
        println("FINAL (post-GC): ", sample(state))
    finally
        close(server)
    end
    TK.exit_success()
end

main()
