# Regression: moving a bt_show_app between bubble / float / tab must NOT scroll
# the chat. A workspace structural change (dock/float/close) re-renders the
# layout, which re-parents EVERY panel through a display:none pool — that resets
# the chat message list's scrollTop to 0 unless the workspace snapshots+restores
# it (BonitoWidgets render()). The jump to the top then pushed the app's bubble
# out of the virtual-scroll viewport, which DETACHED the live embed → blank panel
# + "Reload live app" + a re-detach that no longer worked. This suite reproduces
# a scrollable chat with a live app at the bottom and asserts, across repeated
# detach/dock/close cycles:
#   * the chat scroll position is preserved on dock (content unchanged) and on
#     close (embed returns below the user's position),
#   * the app stays LIVE (click round-trips to its Julia map) and never falls
#     back to the "Reload live app" placeholder,
#   * re-detach keeps working.
# This is exactly what the bubble/float/tab suites missed: they asserted DOM
# identity + liveness but never the chat scroll.
#
# Interaction style: each move is ONE click followed by polling the resulting
# STATE (never re-clicking a working control) — that's how a user drives it, and
# it avoids manufacturing a click-vs-cleanup race the product never sees in
# practice. We also wait for a close to fully settle (the panel leaves the
# workspace) before re-detaching. UI-only.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", "appenv"))

# Tolerance (px) for "the chat held its scroll position" assertions. The bug
# jumped the chat to the TOP — a full-range drop (~the whole scrollable height,
# ~190px in this layout). A workspace re-layout can legitimately settle the
# restored offset a handful of px off (sub-pixel rounding, a late reflow, or a
# followMode re-anchor to a grown bottom on close), so we assert "did not jump
# toward the top" within this margin rather than to the exact pixel. Comfortably
# above observed drift (~16px) and far below the bug's magnitude.
const SCROLL_DRIFT = 40

# A scrollable chat: filler lines, then ONE live counter app at the bottom whose
# output (7×clicks) is computed in Julia, so a correct value proves the app round-
# tripped to its worker session.
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
         [TK.bt_show_app(appcode; env_path = APP_ENV)])
end

# ── State probes (JS predicate strings so they can feed wait_for) ────────────
P(tid)         = "app:" * tid
js_is_float(tid) = "(()=>{const p=document.querySelector('.bw-ws-panel[data-panel-id=\"$(P(tid))\"]'); return !!(p&&p.closest('.bw-ws-float'));})()"
js_is_tab(tid)   = "(()=>{const p=document.querySelector('.bw-ws-panel[data-panel-id=\"$(P(tid))\"]'); const tabbed=[...document.querySelectorAll('.bw-tab')].some(t=>t._panelId==='$(P(tid))'); return tabbed && !!p && !p.closest('.bw-ws-float');})()"
js_in_slot()     = raw"""(()=>{const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('SAPP')); return !!(e&&e.closest('.bt-slot'));})()"""
js_panel_gone(tid) = "!document.querySelector('.bw-ws-panel[data-panel-id=\"$(P(tid))\"]')"

# ── One-shot actions (click ONCE; callers poll the resulting state) ──────────
click_detach(s, tid) = TK.eval_js(s, """(()=>{const b=document.querySelector('.bt-tool-body[data-tool-id="$tid"]'); const h=b&&(b.closest('[data-bt-app]')||b.parentNode); const x=h&&h.querySelector('.bt-tool-detach'); if(!x)return false; x.click(); return true;})()""")
click_dock(s, tid)   = TK.eval_js(s, """(()=>{const p=document.querySelector('.bw-ws-panel[data-panel-id="$(P(tid))"]'); const w=p&&p.closest('.bw-ws-float'); const d=w&&w.querySelector('.bw-float-dock'); if(!d)return false; d.click(); return true;})()""")
click_activate(s, tid) = TK.eval_js(s, """(()=>{const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='$(P(tid))'); if(!t)return false; t.click(); return true;})()""")
click_close(s, tid)  = TK.eval_js(s, """(()=>{const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='$(P(tid))'); const c=t&&t.querySelector('.bw-tab-close'); if(!c)return false; c.click(); return true;})()""")

scroll_st(s) = TK.eval_js(s, raw"""(()=>{const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const m=p&&p.querySelector('.bt-messages'); return m?Math.round(m.scrollTop):-1;})()""")
scroll_to_bottom(s) = TK.eval_js(s, raw"""(()=>{const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const m=p&&p.querySelector('.bt-messages'); if(m)m.scrollTop=m.scrollHeight; return true;})()""")
toolid(s) = TK.eval_js(s, raw"""(()=>{const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('SAPP')); const b=e&&e.closest('.bt-tool-body'); return b?(b.dataset.toolId||''):''; })()""")
reload_shown(s) = TK.eval_js(s, "document.body.innerText.includes('Reload live app')")
app_out(s)      = TK.eval_js(s, raw"""(()=>{const o=document.querySelector('.s-out'); return o?o.innerText:'<none>';})()""")
bump(s)         = TK.eval_js(s, "(()=>{const b=document.querySelector('.s-btn'); if(b)b.click(); return true;})()")

# Click the detach button until the embed has actually left the bubble — needed
# ONLY for the first detach, where the button's handler may still be wiring up on
# a cold render. Once detached the control is live, so every later move is a
# single click + a state poll (see the cycle body).
function detach_until_float(s, tid; timeout = 15)
    t0 = time()
    while time() - t0 < timeout
        click_detach(s, tid)
        try
            TK.wait_for(s, "floated", js_is_float(tid); timeout = 2) == true && return true
        catch; end
    end
    return false
end

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.refresh_eval_session!(APP_ENV)

    @testset "bt_show_app moves preserve chat scroll + liveness (UI-only)" begin
        TK.new_chat(server; title = "Scroll")
        TK.send_message(server, "show me an app")
        @test TK.wait_for(server, "app renders", "document.body.innerText.includes('SAPP')"; timeout = 180) == true
        tid = toolid(server)
        @test !isempty(tid)

        # Force a scroll region: a short viewport makes the chat overflow
        # regardless of the CI screen size.
        TK.set_window_size(server, 1280, 460); sleep(1.0)
        @test TK.wait_for(server, "chat is scrollable", "(() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null); const m=p&&p.querySelector('.bt-messages'); return !!m && (m.scrollHeight - m.clientHeight) > 40; })()"; timeout = 10) == true

        # Detach into a float (content shrinks as the embed leaves the chat —
        # scroll legitimately changes here, so we don't pin it).
        @test detach_until_float(server, tid)

        # ── The regression: DOCK must not move the chat ──────────────────────
        # The embed is already out of the chat, so docking the float as a tab
        # changes NOTHING in the message list — the chat must stay where it is.
        # The bug jumped it to the TOP (scrollTop 0, a full-range drop); we assert
        # it held position within a small reflow-drift tolerance rather than to the
        # exact pixel (an async re-layout can settle a few px off).
        scroll_to_bottom(server); sleep(0.3)
        before_dock = scroll_st(server)
        @test before_dock > 0                                  # genuinely scrolled
        @test click_dock(server, tid)
        @test TK.wait_for(server, "docked as tab", js_is_tab(tid); timeout = 8) == true
        sleep(0.3)
        @test scroll_st(server) >= before_dock - SCROLL_DRIFT  # held position; no jump to top
        @test !reload_shown(server)                            # embed never went stale

        # App is still LIVE as a tab: a click round-trips to its Julia map.
        @test click_activate(server, tid); sleep(0.3)
        bump(server)
        @test TK.wait_for(server, "click round-trips (SVAL=7)", "(() => { const o=document.querySelector('.s-out'); return !!(o && o.innerText==='SVAL=7'); })()"; timeout = 8) == true

        # ── Close restores the embed to its bubble without jumping the chat ──
        # Closing returns the embed below the user (content grows). The scroll must
        # stay where they were — either held at the same offset or followed down to
        # the new bottom — and must NOT collapse toward the top (the bug, which
        # landed at 0). A small downward tolerance allows the followMode re-anchor.
        scroll_to_bottom(server); sleep(0.3)
        before_close = scroll_st(server)
        @test before_close > 0                                  # genuinely scrolled
        @test click_close(server, tid)
        @test TK.wait_for(server, "embed back in bubble", js_in_slot(); timeout = 8) == true
        sleep(0.3)
        @test scroll_st(server) >= before_close - SCROLL_DRIFT  # held position; no jump to top
        @test !reload_shown(server)
        @test app_out(server) == "SVAL=7"                      # still live inline, state kept

        # ── Stress: repeat detach → dock → close, asserting scroll held + the
        #    app stays live (never the "Reload live app" placeholder). Each move
        #    is ONE click + a state poll; we also wait for the close to fully
        #    settle (panel gone) before the next detach, like a real user. ─────
        for i in 1:6
            @testset "cycle $i: detach → dock (scroll held, app live) → close" begin
                @test TK.wait_for(server, "close settled (panel gone)", js_panel_gone(tid); timeout = 8) == true
                @test click_detach(server, tid)
                @test TK.wait_for(server, "floated", js_is_float(tid); timeout = 8) == true
                scroll_to_bottom(server); sleep(0.2)
                p = scroll_st(server)
                @test click_dock(server, tid)
                @test TK.wait_for(server, "docked", js_is_tab(tid); timeout = 8) == true
                sleep(0.3)
                @test scroll_st(server) >= p - SCROLL_DRIFT    # dock held scroll (no jump to top)
                @test !reload_shown(server)                    # app stayed live
                @test click_activate(server, tid); sleep(0.2)
                @test click_close(server, tid)
                @test TK.wait_for(server, "back in bubble", js_in_slot(); timeout = 8) == true
            end
        end
        # Final liveness: still interactive inline after the whole dance.
        @test TK.wait_for(server, "close settled", js_panel_gone(tid); timeout = 8) == true
        bump(server)
        @test TK.wait_for(server, "still live (SVAL=14)", "(() => { const o=document.querySelector('.s-out'); return !!(o && o.innerText==='SVAL=14'); })()"; timeout = 8) == true
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
