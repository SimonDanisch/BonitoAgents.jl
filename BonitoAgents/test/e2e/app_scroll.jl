# Regression: moving a live eval embed between bubble / float / tab must NOT
# scroll the chat. A workspace structural change re-parents every panel through
# a display:none pool, which resets the message list's scrollTop to 0 unless the
# workspace snapshots + restores it. The jump then pushed the embed's bubble out
# of the virtual-scroll viewport, DETACHING the live app → blank panel +
# "Reload live app" and a re-detach that no longer worked.
#
# Ported from the bt_show_app-era suite deleted with that tool: the behaviour it
# guarded still exists via bt_julia_eval embeds + ⤢ detach, and COVERAGE.md
# still advertises it. Asserts across repeated detach/dock/close cycles:
#   * chat scroll held on dock (content unchanged) and on close,
#   * the app stays LIVE (a click round-trips to its Julia map) and never falls
#     back to the "Reload live app" placeholder,
#   * re-detach keeps working.
#
# One click per move, then poll the resulting STATE — that's how a user drives
# it, and it avoids manufacturing a click-vs-cleanup race. UI-only.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))
const TID     = "scroll-app"

# Tolerance (px) for "the chat held its position". The bug jumped to the TOP —
# a full-range drop — so anything within a few px of the pre-move offset is a
# pass; a workspace re-layout can legitimately settle slightly off.
const SCROLL_DRIFT = 40

# A scrollable chat: filler, then ONE live counter app whose output is computed
# in Julia, so a correct value proves the click round-tripped to the worker.
function agent_script(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    appcode = """using Bonito
        App() do
            clicks = Observable(0)
            out = map(c -> "SVAL=" * string(7c), clicks)
            btn = DOM.div("bump"; class="s-btn", onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
            DOM.div(DOM.span("SAPP "), DOM.span(out; class="s-out"), btn; style="padding:14px")
        end"""
    vcat([TK.text("filler line $i — " * "x"^24) for i in 1:14],
         [TK.bt_eval(appcode; env_path = APP_ENV, id = TID)])
end

P = "app:" * TID
js_is_float = "(()=>{const p=document.querySelector('.bw-ws-panel[data-panel-id=\"$P\"]'); return !!(p&&p.closest('.bw-ws-float'));})()"
js_is_tab   = "(()=>{const p=document.querySelector('.bw-ws-panel[data-panel-id=\"$P\"]'); const tabbed=[...document.querySelectorAll('.bw-tab')].some(t=>t._panelId==='$P'); return tabbed && !!p && !p.closest('.bw-ws-float');})()"
js_in_slot  = raw"""(()=>{const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('SAPP')); return !!(e&&e.closest('.bt-slot'));})()"""
js_panel_gone = "!document.querySelector('.bw-ws-panel[data-panel-id=\"$P\"]')"

const CARD = ".bt-tool-msg[data-msg-id*=\"$TID\"]"
click_detach(s)   = TK.eval_js(s, "(()=>{const x=document.querySelector('$CARD .bt-tool-detach'); if(!x)return false; x.click(); return true;})()")
click_dock(s)     = TK.eval_js(s, "(()=>{const p=document.querySelector('.bw-ws-panel[data-panel-id=\"$P\"]'); const w=p&&p.closest('.bw-ws-float'); const d=w&&w.querySelector('.bw-float-dock'); if(!d)return false; d.click(); return true;})()")
click_activate(s) = TK.eval_js(s, "(()=>{const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='$P'); if(!t)return false; t.click(); return true;})()")
click_close(s)    = TK.eval_js(s, "(()=>{const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='$P'); const c=t&&t.querySelector('.bw-tab-close'); if(!c)return false; c.click(); return true;})()")

scroll_st(s) = TK.eval_js(s, raw"""(()=>{const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const m=p&&p.querySelector('.bt-messages'); return m?Math.round(m.scrollTop):-1;})()""")
scroll_to_bottom(s) = TK.eval_js(s, raw"""(()=>{const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const m=p&&p.querySelector('.bt-messages'); if(m)m.scrollTop=m.scrollHeight; return true;})()""")
reload_shown(s) = TK.eval_js(s, "document.body.innerText.includes('Reload live app')")
app_out(s)      = TK.eval_js(s, raw"""(()=>{const o=document.querySelector('.s-out'); return o?o.innerText:'<none>';})()""")
bump(s)         = TK.eval_js(s, "(()=>{const b=document.querySelector('.s-btn'); if(b)b.click(); return true;})()")

# Prove a click round-trips to the app's Julia `map` by waiting for the output
# to CHANGE, not for an exact value: the first interaction after a move can take
# well over 8s (cold bridge), and `click_until` may land more than one click.
# Same approach as eval_embed_park.
function bump_live(s, prev; timeout = 40)
    pred = "(() => { const o=document.querySelector('.s-out'); return !!(o && o.innerText && o.innerText !== " *
           TK.json(prev) * "); })()"
    try
        TK.click_until(s, ".s-btn", pred; timeout = timeout)
    catch e
        e isa InterruptException && rethrow()
        return false                       # never satisfied within the budget
    end
    return TK.eval_js(s, pred) === true    # a Bool, so @test can read it
end

# Only the FIRST detach retries: the button's handler may still be wiring up on
# a cold render. Every later move is one click + a state poll.
function detach_until_float(s; timeout = 15)
    t0 = time()
    while time() - t0 < timeout
        click_detach(s)
        try
            TK.wait_for(s, "floated", js_is_float; timeout = 2) == true && return true
        catch e
            e isa InterruptException && rethrow()
        end
    end
    return false
end

function run_suite(server)
    server.agent_fn[] = agent_script

    @testset "eval embed moves preserve chat scroll + liveness (UI-only)" begin
        TK.new_chat(server; title = "Scroll")
        TK.send_message(server, "show me an app")
        @test TK.wait_for(server, "app renders", "document.body.innerText.includes('SAPP')";
                          timeout = 180) == true

        # Force a scroll region regardless of screen size.
        TK.set_window_size(server, 1280, 460); sleep(1.0)
        @test TK.wait_for(server, "chat is scrollable",
            "(() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const m=p&&p.querySelector('.bt-messages'); return !!m && (m.scrollHeight - m.clientHeight) > 40; })()";
            timeout = 10) == true

        # Detach into a float. Content shrinks as the embed leaves the chat, so
        # scroll legitimately changes here — not pinned.
        @test detach_until_float(server)

        # Liveness WHILE FLOATING, before any dock — isolates whether the tab
        # path specifically breaks the round-trip.
        @test bump_live(server, "SVAL=0")          # live while floating
        floating_val = app_out(server)

        # DOCK must not move the chat: the embed is already out of the message
        # list, so docking the float as a tab changes nothing in it.
        scroll_to_bottom(server); sleep(0.3)
        before_dock = scroll_st(server)
        @test before_dock > 0
        @test click_dock(server)
        @test TK.wait_for(server, "docked as tab", js_is_tab; timeout = 8) == true
        sleep(0.3)
        @test scroll_st(server) >= before_dock - SCROLL_DRIFT
        @test !reload_shown(server)

        # Live as a tab: a click round-trips to its Julia map.
        @test click_activate(server); sleep(0.3)
        @test bump_live(server, floating_val)      # live as a docked tab
        tab_val = app_out(server)

        # CLOSE returns the embed below the user (content grows). Scroll must
        # hold or follow down — never collapse toward the top.
        scroll_to_bottom(server); sleep(0.3)
        before_close = scroll_st(server)
        @test before_close > 0
        @test click_close(server)
        @test TK.wait_for(server, "embed back in bubble", js_in_slot; timeout = 8) == true
        sleep(0.3)
        @test scroll_st(server) >= before_close - SCROLL_DRIFT
        @test !reload_shown(server)
        @test app_out(server) == tab_val       # state kept across the move back

        for i in 1:6
            @testset "cycle $i: detach → dock (scroll held, app live) → close" begin
                @test TK.wait_for(server, "close settled", js_panel_gone; timeout = 8) == true
                @test click_detach(server)
                @test TK.wait_for(server, "floated", js_is_float; timeout = 8) == true
                scroll_to_bottom(server); sleep(0.2)
                p = scroll_st(server)
                @test click_dock(server)
                @test TK.wait_for(server, "docked", js_is_tab; timeout = 8) == true
                sleep(0.3)
                @test scroll_st(server) >= p - SCROLL_DRIFT
                @test !reload_shown(server)
                @test click_activate(server); sleep(0.2)
                @test click_close(server)
                @test TK.wait_for(server, "back in bubble", js_in_slot; timeout = 8) == true
            end
        end
        @test TK.wait_for(server, "close settled", js_panel_gone; timeout = 8) == true
        @test bump_live(server, tab_val)           # still interactive inline
        @test isempty(TK.js_errors(server))
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
