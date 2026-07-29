# Reported: with several plots in one chat, scrolling to an earlier one doesn't
# work. Reproduced here: scrolling UP past several tall embeds moves once, then
# stops dead well short of the top.
#
# Two things this suite exists to encode, both learned the hard way:
#
# 1. It must use a REAL wheel gesture (`ECT.wheel`). `followMode` only
#    disengages on a user-initiated scroll — a scroll event within ~400ms of a
#    wheel/touch/keydown. Setting `scrollTop` or calling `scrollIntoView`
#    carries no gesture, so it is classified as a layout shift, the chase rAF
#    snaps back to the bottom, and you measure follow-mode instead of the bug.
# 2. It must build the chat ONE EVAL PER TURN. Several `bt_eval`s in a single
#    mock turn don't all render (see test_bt_eval_types_e2e.jl).
#
# Ruled out by measurement while narrowing this: the workspace re-parent path
# (BonitoWidgets snapshots/restores scroll, and `app_scroll` passes across seven
# move cycles), and `EST_HEIGHT` skew (it only adapts past 20 measured rows —
# here it stays at the 80px default).

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK  = TestKit
const ECT = TestKit.ECT

const APP_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))
const NAPPS   = 4

tall_app(i) = """using Bonito
    App() do
        DOM.div(DOM.span("TALLAPP$(i)"); style="height:600px;padding:12px;background:#eef")
    end"""

# One eval per prompt: "plot <i>" → filler rows + that plot.
function agent_script(prompt::AbstractString)
    m = match(r"plot\s+(\d+)", lowercase(prompt))
    m === nothing && return [TK.text("Echo: $(prompt)")]
    i = parse(Int, m.captures[1])
    return vcat([TK.text("row $i.$j — " * "z"^40) for j in 1:8],
                [TK.bt_eval(tall_app(i); env_path = APP_ENV, id = "tall-$i")])
end

msgs_sel = raw"""[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null)?.querySelector('.bt-messages')"""
scroll_st(s)  = TK.eval_js(s, "(()=>{const m=$msgs_sel; return m?Math.round(m.scrollTop):-1;})()")
scroll_max(s) = TK.eval_js(s, "(()=>{const m=$msgs_sel; return m?Math.round(m.scrollHeight-m.clientHeight):-1;})()")
to_bottom(s)  = TK.eval_js(s, "(()=>{const m=$msgs_sel; if(m)m.scrollTop=m.scrollHeight; return true;})()")

# EST_HEIGHT / measured-row count / last captured anchor — for diagnosing.
scroller_state(s) = TK.eval_js(s, """(() => {
    const c = [...document.querySelectorAll('*')].map(e => e.__bt_chat).find(Boolean);
    const m = $msgs_sel;
    if (!c) return null;
    return { est: Math.round(c.EST_HEIGHT), measured: c.heights ? c.heights.size : -1,
             anchor: c._anchorDebugG, st: m ? Math.round(m.scrollTop) : -1 }; })()""")

# Park the cursor over the message list, so `wheel` lands on it.
function aim_at_messages(s)
    ctx = s.browser[]
    pos = ECT.eval_js(ctx, """(() => {
        const m = $msgs_sel; if (!m) return null;
        const r = m.getBoundingClientRect();
        return {x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2)}; })()""")
    pos === nothing && return nothing
    ECT.install_cursor(ctx)                       # `wheel` reads cursor_pos
    ECT.set_cursor(ctx, pos["x"], pos["y"])
    return ctx
end

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "wheel-scrolling up past several tall embeds" begin
        TK.new_chat(server; title = "MultiScroll")
        for i in 1:NAPPS
            TK.send_message(server, "plot $i")
            @test TK.wait_for(server, "embed $i rendered",
                "document.body.innerText.includes('TALLAPP$(i)')"; timeout = 240) == true
        end

        TK.set_window_size(server, 1280, 500); sleep(1.5)
        to_bottom(server); sleep(0.8)
        top_of_scroll = scroll_max(server)
        @test top_of_scroll > 1000                 # genuinely long

        ctx = aim_at_messages(server)
        @test ctx !== nothing

        # Wheel upward repeatedly and record how far each gesture actually got.
        moves = Int[]
        for _ in 1:8
            before = scroll_st(server)
            ECT.wheel(ctx, -600)
            sleep(0.7)
            push!(moves, before - scroll_st(server))
            scroll_st(server) == 0 && break
        end
        final = scroll_st(server)

        # The first gesture works, which is why this isn't obvious immediately.
        @test moves[1] > 100

        # KNOWN BUG: scrolling then stops dead — observed 598px, 100px, then 0
        # for every gesture after, stranding the view ~2500 of 3199 with no way
        # to reach the earlier plots. @test_broken keeps CI green and flags the
        # moment this starts working.
        @test_broken all(>(50), moves)
        @test_broken final < top_of_scroll ÷ 2     # should be able to get well up

        # Diagnostics for whoever picks this up: the anchor is never re-captured
        # and the estimate never adapts, so neither is the mechanism.
        @info "scroll-up profile" moves final top_of_scroll state=scroller_state(server)
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = agent_script)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
