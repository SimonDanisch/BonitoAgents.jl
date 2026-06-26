# Several live bt_show_apps at once, detached together and driven independently —
# the multi-window workflow the single-app suites don't cover:
#   * THREE interactive apps in one turn
#   * detach ALL into their own windows (floats) at once
#   * interact with EACH while floating — each runs its own Julia map in the
#     worker; the others must not move (independent sessions)
#   * switch to another chat and back — all three windows + their state survive
#   * close the windows one at a time — each embed returns to its OWN bubble, the
#     others stay floating, live, and unchanged
#
# Liveness is a per-app counter whose output is computed IN JULIA (distinct
# formula per app), so a correct value proves that app's click round-tripped to
# its worker session. All moves are real UI clicks (detach button, float-close,
# sidebar chat switch). UI-only.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", "appenv"))

# (css/marker tag, display label, distinct Julia formula over the click count `c`)
const APPS = [(t = "a", L = "A", f = "2c"),
              (t = "b", L = "B", f = "10 + c"),
              (t = "c", L = "C", f = "100 + c")]

function agent_script(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    appcode(a) = """using Bonito
        App() do
            clicks = Observable(0)
            out = map(c -> "$(a.L)=" * string($(a.f)), clicks)
            btn = DOM.div("bump $(a.L)"; class="m-$(a.t)-btn",
                          onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
            DOM.div(DOM.span("MAPP-$(a.L) "), DOM.span(out; class="m-$(a.t)-out"),
                    btn; style="padding:14px")
        end"""
    vcat([TK.text("three live apps:")],
         [TK.bt_show_app(appcode(a); env_path = APP_ENV) for a in APPS])
end

# Tool id of the embed carrying marker MAPP-<L>.
toolid(s, L) = TK.eval_js(s, """(() => {
    const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('MAPP-$(L)'));
    const b=e&&e.closest('.bt-tool-body'); return b?(b.dataset.toolId||''):''; })()""")

is_float(s, tid) = TK.eval_js(s, """(() => { const p=document.querySelector('.bw-ws-panel[data-panel-id="app:$tid"]'); return !!(p && p.closest('.bw-ws-float')); })()""")
is_slot(s, L)    = TK.eval_js(s, """(() => { const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('MAPP-$(L)')); return !!(e && e.closest('.bt-slot')); })()""")

out_text(s, t)  = TK.eval_js(s, "(() => { const e=document.querySelector('.m-$(t)-out'); return e ? e.innerText : '<none>' })()")
click_app(s, t) = TK.eval_js(s, "(() => { const b=document.querySelector('.m-$(t)-btn'); if(b){b.click();return true} return false })()")

detach(s, tid) = TK.eval_js(s, """(() => {
    const b=document.querySelector('.bt-tool-body[data-tool-id="$tid"]');
    const h=b&&(b.closest('[data-bt-app]')||b.parentNode);
    const btn=h&&h.querySelector('.bt-tool-detach'); if(!btn)return false; btn.click(); return true; })()""")
close_float(s, tid) = TK.eval_js(s, """(() => {
    const p=document.querySelector('.bw-ws-panel[data-panel-id="app:$tid"]');
    const w=p&&p.closest('.bw-ws-float'); const btn=w&&w.querySelector('.bw-float-close');
    if(!btn)return false; btn.click(); return true; })()""")

# Retry an action until a predicate holds (onload-wiring lag; see app_stress.jl).
function until(action, pred; tries = 40)
    for _ in 1:tries
        pred() === true && return true
        action(); sleep(0.2)
    end
    return pred() === true
end

# Click app `t`'s button and wait for its Julia-computed output to reach `want`.
function bump_to(s, t, want)
    click_app(s, t)
    TK.wait_for(s, "$t → $want", "(() => { const e=document.querySelector('.m-$(t)-out'); return !!(e && e.innerText==='$(want)'); })()"; timeout = 8) == true
end

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.refresh_eval_session!(APP_ENV)

    @testset "multiple bt_show_apps: detach all, drive independently (UI-only)" begin
        stress_pid = TK.new_chat(server; title = "Multi")
        TK.send_message(server, "show three apps")

        # All three live apps render; the first carries the heavy cold start.
        for (i, a) in enumerate(APPS)
            @test TK.wait_for(server, "$(a.L) renders", "document.body.innerText.includes('MAPP-$(a.L)')"; timeout = i == 1 ? 180 : 60) == true
        end
        tids = Dict(a.t => toolid(server, a.L) for a in APPS)
        @test all(!isempty, values(tids))

        # Each app starts at its formula's c=0 value: A=0, B=10, C=100.
        @test out_text(server, "a") == "A=0"
        @test out_text(server, "b") == "B=10"
        @test out_text(server, "c") == "C=100"

        # Detach ALL three into their own windows at once.
        for a in APPS
            @test until(() -> detach(server, tids[a.t]), () -> is_float(server, tids[a.t]))
        end
        @test count(a -> is_float(server, tids[a.t]), APPS) == 3   # three separate windows

        # Drive EACH while floating; each runs its own Julia map, others frozen.
        @test bump_to(server, "a", "A=2")     # 2×1
        @test out_text(server, "b") == "B=10" # untouched
        @test out_text(server, "c") == "C=100"
        @test bump_to(server, "c", "C=101")   # 100+1
        @test bump_to(server, "c", "C=102")
        @test out_text(server, "a") == "A=2"
        @test bump_to(server, "b", "B=11")    # 10+1
        # Snapshot of each app's independent state.
        @test (out_text(server, "a"), out_text(server, "b"), out_text(server, "c")) == ("A=2", "B=11", "C=102")

        # Switch to another chat and back — all three windows + state survive.
        TK.new_chat(server; title = "Aside")   # new_chat opens it → we're now away
        TK.open_chat(server, stress_pid)
        @test TK.wait_for(server, "multi chat back", "document.body.innerText.includes('MAPP-A')"; timeout = 10) == true
        @test count(a -> is_float(server, tids[a.t]), APPS) == 3
        @test (out_text(server, "a"), out_text(server, "b"), out_text(server, "c")) == ("A=2", "B=11", "C=102")
        @test bump_to(server, "b", "B=12")    # still live after the round-trip

        # Close the windows one at a time: each embed returns to its OWN bubble,
        # the others keep floating, live, and unchanged.
        @test until(() -> close_float(server, tids["a"]), () -> is_slot(server, "A"))
        @test is_float(server, tids["b"]) && is_float(server, tids["c"])
        @test (out_text(server, "b"), out_text(server, "c")) == ("B=12", "C=102")

        @test until(() -> close_float(server, tids["c"]), () -> is_slot(server, "C"))
        @test is_float(server, tids["b"]) && is_slot(server, "A")
        @test out_text(server, "b") == "B=12"

        @test until(() -> close_float(server, tids["b"]), () -> is_slot(server, "B"))
        @test all(a -> is_slot(server, a.L), APPS)   # all three home in their bubbles

        # All still live inline after the whole dance.
        @test bump_to(server, "a", "A=4")     # 2×2
        @test out_text(server, "b") == "B=12"
        @test out_text(server, "c") == "C=102"
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
