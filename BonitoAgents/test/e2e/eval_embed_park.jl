# A LIVE eval-result embed gets `bt_show_app`'s output handling, end to end:
#
#   • Keep-alive parking: scrolling the card out of the virtual-scroll window
#     must NOT remove its DOM (removal closes the Bonito sub-session and
#     disposes a WGLMakie WebGL context — the plot comes back dead). Cards
#     whose completed eval holds a live result embed are flagged
#     `live_embed` (typed, from the result descriptor) → `data-bt-app` → the
#     client PARKS them display:none in place. THE assertion is instance
#     identity: a counter clicked to 11 before scrolling away still reads 11
#     when scrolled back (a re-render would reset it to 0), and it still
#     round-trips clicks through the eval bridge afterwards.
#   • ⤢ Detach: the header button pops the embed into its own workspace
#     panel — the SAME live DOM node is adopted (no re-render, counter keeps
#     its value, clicks still round-trip inside the panel); closing the
#     panel returns it to its bubble slot, still live.
#
# UI-only: real dev_server, real eval worker, DOM clicks + rendered-DOM
# assertions. Mirrors app_reload.jl's structure on the shared soak server.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const PARK_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))

# The clicker app (see app_reload.jl): output = 13×clicks computed in the
# Malt worker, so a correct value proves the browser→worker round trip.
# FILLER messages after the eval overflow the transcript so scrolling to the
# bottom pushes the eval card out of the virtual-scroll render window.
function park_agent(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    appcode = """using Bonito
        App() do
            clicks = Observable(0)
            out = map(c -> "PARKAPP=" * string(13c), clicks)
            btn = DOM.div("bump"; class="park-btn",
                          onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
            DOM.div(DOM.span("PARK-APP "), DOM.span(out; class="park-out"),
                    btn; style="padding:16px")
        end"""
    # Filler must be many separate MESSAGES (the virtual scroll windows per
    # message): consecutive `text` events coalesce into ONE streamed AgentMsg,
    # which left a 4-message transcript where nothing was ever evicted — so
    # interleave a tool row per line (same trick as filter_scroll's seed).
    # 50 messages ≈ far past viewport + overscan (8×EST_HEIGHT): scrolling to
    # the bottom must evict (= park) the eval card.
    evs = Any[TK.text("here is the app:"),
              TK.bt_eval(appcode; env_path = PARK_ENV, id = "park-app")]
    for i in 1:25
        push!(evs, TK.text("filler line number $(i) — pushes the eval card out of view"))
        push!(evs, TK.tool(kind = "read", title = "filler tool $(i)", id = "fill-$(i)"))
    end
    return evs
end

CARD = ".bt-tool-msg[data-msg-id*=\"park-app\"]"

out_is(s, want) = TK.eval_js(s,
    "(() => { const e=document.querySelector('.park-out'); return !!(e && e.innerText==='$(want)'); })()") == true

# Click the app's bump button and wait for the WORKER-computed output.
click_until(s, want) = begin
    TK.eval_js(s, "(() => { const b=document.querySelector('.park-btn'); if(b){b.click();return true} return false })()")
    TK.wait_for(s, "park → $want",
        "(() => { const e=document.querySelector('.park-out'); return !!(e && e.innerText==='$(want)'); })()";
        timeout = 8) == true
end

function run_suite(server)
    server.agent_fn[] = park_agent

    pid = TK.new_chat(server; title = "ParkApp")
    TK.send_message(server, "show the app")

    @testset "live eval embed gets the bt_show_app affordances" begin
        @test TK.wait_for(server, "app mounts live",
            "document.body.innerText.includes('PARK-APP')"; timeout = 180) == true
        # Cold-start budget: "app mounts live" only sees the static PARK-APP
        # string; the first live value (PARKAPP=0) waits on the embed's
        # WGLMakie/Bonito live-init, so give it room like the render/interaction
        # waits, not the old 10s (shortest budget for the slowest step).
        @test TK.wait_for(server, "initial out",
            "(() => { const e=document.querySelector('.park-out'); return !!(e && e.innerText==='PARKAPP=0'); })()";
            timeout = 30) == true
        # The completed card is flagged for keep-alive + carries the ⤢ button.
        @test TK.eval_js(server, "document.querySelector('$CARD')?.dataset.btApp === '1'") == true
        @test TK.eval_js(server, "!!document.querySelector('$CARD .bt-tool-detach')") == true
        # Make the instance identifiable: one click → 13.
        @test click_until(server, "PARKAPP=13")
    end

    @testset "scroll-off parks the embed alive (never re-rendered)" begin
        # Scroll to the BOTTOM (the filler) so the eval card leaves the render
        # window, then wait until the card is actually PARKED: still connected
        # to the document (display:none) — not removed. Removal would close
        # the sub-session; parking is the whole point.
        TK.eval_js(server, """(() => {
            const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
            c.scrollTop = c.scrollHeight;
            c.dispatchEvent(new Event('scroll', {bubbles:true}));
        })()""")
        @test TK.wait_for(server, "card parked (connected but hidden)",
            """(() => { const n = document.querySelector('$CARD');
                return !!(n && n.isConnected && n.offsetParent === null &&
                          n.querySelector('.park-btn')); })()"""; timeout = 30) == true

        # Scroll back: the SAME instance re-appears — the counter still reads
        # 13 (a re-mount would render a fresh instance at 0) and it still
        # round-trips clicks through the bridge. The WheelEvent marks this as
        # USER scrolling — without it followMode stays on and the next
        # geometry settle snaps the viewport straight back to the bottom.
        TK.eval_js(server, """(() => {
            const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
            c.dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles:true}));
        })()""")
        @test TK.wait_for(server, "card visible again",
            "(() => { const n = document.querySelector('$CARD'); return !!(n && n.offsetParent !== null); })()";
            timeout = 30) == true
        @test out_is(server, "PARKAPP=13")          # same instance, not re-rendered
        @test click_until(server, "PARKAPP=26")     # and still live
    end

    @testset "⤢ detach adopts the live node into a workspace panel and back" begin
        TK.eval_js(server, "document.querySelector('$CARD .bt-tool-detach')?.click(); true")
        # The floating panel adopts the embed (same DOM node — counter holds).
        @test TK.wait_for(server, "panel adopted the embed",
            """(() => { const p = document.querySelector('.bw-ws-panel[data-panel-id="app:park-app"]');
                return !!(p && p.querySelector('.bt-embed .park-out')); })()"""; timeout = 20) == true
        @test TK.eval_js(server, "document.querySelector('$CARD .bt-slot')?.dataset.detached === '1'") == true
        @test out_is(server, "PARKAPP=26")          # adopted, not re-rendered
        @test click_until(server, "PARKAPP=39")     # live inside the panel

        # Close the float: the embed returns to its bubble slot, still live.
        @test TK.eval_js(server, """(() => {
            const p = document.querySelector('.bw-ws-panel[data-panel-id="app:park-app"]');
            const btn = p && p.closest('.bw-float')?.querySelector('.bw-float-close');
            if (btn) { btn.click(); return true; } return false;
        })()""") == true
        @test TK.wait_for(server, "embed restored to its bubble",
            """(() => { const slot = document.querySelector('$CARD .bt-slot');
                return !!(slot && !slot.dataset.detached && slot.querySelector('.park-out')); })()""";
            timeout = 20) == true
        @test out_is(server, "PARKAPP=39")
        @test click_until(server, "PARKAPP=52")
    end

    @test isempty(TK.js_errors(server))
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = park_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
