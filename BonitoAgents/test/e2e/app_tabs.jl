# bt_show_apps docked into ONE window as TABS (the VSCode-style flow): detach
# several apps, then dock each float into the chat group so they become tabs
# beside the chat; switch between the tabs; each app stays LIVE as a tab (its
# Julia map runs in the worker); then close the tabs and the apps return to their
# bubbles.
#
# Docking is one click on the float's ⤢ dock button (.bw-float-dock → dockFloat).
# A docked panel is a tab whose button carries `_panelId === "app:<tid>"`; only
# the active tab's panel is visible. Liveness is a per-app counter computed IN
# JULIA (distinct formula each), so a correct value proves the click round-tripped
# to that app's worker session while it was the active tab. UI-only.
#
# NOTE: closing the ACTIVE tab is exercised here (it restores the embed to its
# bubble). Closing an INACTIVE app tab currently LOSES the embed — a known
# workspace bug (see COVERAGE.md); this suite always activates a tab before
# closing it, which is the path that works and the natural user action.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", ".."))
const APPS = [(t = "a", L = "A", f = "2c"),
              (t = "b", L = "B", f = "10 + c"),
              (t = "c", L = "C", f = "100 + c")]

function agent_script(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    appcode(a) = """using Bonito
        App() do
            clicks = Observable(0)
            out = map(c -> "$(a.L)=" * string($(a.f)), clicks)
            btn = DOM.div("bump $(a.L)"; class="w-$(a.t)-btn",
                          onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
            DOM.div(DOM.span("WTAB-$(a.L) "), DOM.span(out; class="w-$(a.t)-out"),
                    btn; style="padding:14px")
        end"""
    vcat([TK.text("three apps to tab:")],
         [TK.bt_show_app(appcode(a); env_path = APP_ENV) for a in APPS])
end

toolid(s, L) = TK.eval_js(s, """(() => {
    const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('WTAB-$(L)'));
    const b=e&&e.closest('.bt-tool-body'); return b?(b.dataset.toolId||''):''; })()""")

detach(s, tid) = TK.eval_js(s, """(() => {
    const b=document.querySelector('.bt-tool-body[data-tool-id="$tid"]');
    const h=b&&(b.closest('[data-bt-app]')||b.parentNode);
    const x=h&&h.querySelector('.bt-tool-detach'); if(!x)return false; x.click(); return true; })()""")
# Click the float's ⤢ dock button → the panel docks into the chat group as a tab.
dock(s, tid) = TK.eval_js(s, """(() => {
    const p=document.querySelector('.bw-ws-panel[data-panel-id="app:$tid"]');
    const w=p&&p.closest('.bw-ws-float'); const d=w&&w.querySelector('.bw-float-dock');
    if(!d)return false; d.click(); return true; })()""")

is_float(s, tid) = TK.eval_js(s, """(() => { const p=document.querySelector('.bw-ws-panel[data-panel-id="app:$tid"]'); return !!(p && p.closest('.bw-ws-float')); })()""")
app_tab_count(s) = TK.eval_js(s, "[...document.querySelectorAll('.bw-tab')].filter(t => String(t._panelId||'').indexOf('app:')===0).length")
has_tab(s, tid)  = TK.eval_js(s, """[...document.querySelectorAll('.bw-tab')].some(t => t._panelId === 'app:$tid')""")
tab_active(s, tid) = TK.eval_js(s, """(() => { const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='app:$tid'); return !!(t && t.classList.contains('bw-active')); })()""")
visible(s, L)    = TK.eval_js(s, """(() => { const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('WTAB-$(L)')); return !!(e && e.offsetParent !== null); })()""")
in_slot(s, L)    = TK.eval_js(s, """(() => { const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('WTAB-$(L)')); return !!(e && e.closest('.bt-slot')); })()""")

activate(s, tid) = TK.eval_js(s, """(() => { const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='app:$tid'); if(!t)return false; t.click(); return true; })()""")
close_tab(s, tid) = TK.eval_js(s, """(() => { const t=[...document.querySelectorAll('.bw-tab')].find(x=>x._panelId==='app:$tid'); const c=t&&t.querySelector('.bw-tab-close'); if(!c)return false; c.click(); return true; })()""")
out_text(s, t)   = TK.eval_js(s, "(() => { const e=document.querySelector('.w-$(t)-out'); return e ? e.innerText : '<none>' })()")
click_app(s, t)  = TK.eval_js(s, "(() => { const b=document.querySelector('.w-$(t)-btn'); if(b){b.click();return true} return false })()")

function until(action, pred; tries = 40)
    for _ in 1:tries
        pred() === true && return true
        action(); sleep(0.2)
    end
    return pred() === true
end
# Click the active app `t`'s button and wait for its Julia output to reach `want`.
function bump_to(s, t, want)
    click_app(s, t)
    TK.wait_for(s, "$t → $want", "(() => { const e=document.querySelector('.w-$(t)-out'); return !!(e && e.innerText==='$(want)'); })()"; timeout = 8) == true
end

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.refresh_eval_session!(APP_ENV)

    @testset "bt_show_apps docked as tabs in one window (UI-only)" begin
        TK.new_chat(server; title = "Tabs")
        TK.send_message(server, "show apps to tab")
        for (i, a) in enumerate(APPS)
            @test TK.wait_for(server, "$(a.L) renders", "document.body.innerText.includes('WTAB-$(a.L)')"; timeout = i == 1 ? 180 : 60) == true
        end
        tids = Dict(a.t => toolid(server, a.L) for a in APPS)
        @test all(!isempty, values(tids))

        # Detach all three (floats), then DOCK each into the chat group as a tab.
        for a in APPS
            @test until(() -> detach(server, tids[a.t]), () -> is_float(server, tids[a.t]))
        end
        for a in APPS
            @test until(() -> dock(server, tids[a.t]), () -> has_tab(server, tids[a.t]) && !is_float(server, tids[a.t]))
        end
        @test app_tab_count(server) == 3          # three app tabs in the one window
        @test count(a -> is_float(server, tids[a.t]), APPS) == 0   # no floating windows left

        # Switch between the tabs: the active tab's app is the visible one, and it
        # stays LIVE (its Julia map runs while it's the active tab). Each app keeps
        # its own state.
        @test activate(server, tids["a"]); sleep(0.3)
        @test tab_active(server, tids["a"]) && visible(server, "A")
        @test !visible(server, "B") && !visible(server, "C")
        @test bump_to(server, "a", "A=2")          # A=2c, c=1 — round-trips while tabbed

        @test activate(server, tids["b"]); sleep(0.3)
        @test tab_active(server, tids["b"]) && visible(server, "B") && !visible(server, "A")
        @test bump_to(server, "b", "B=11")         # B=10+c
        @test bump_to(server, "b", "B=12")

        @test activate(server, tids["c"]); sleep(0.3)
        @test tab_active(server, tids["c"]) && visible(server, "C")
        @test bump_to(server, "c", "C=101")        # C=100+c

        # Back to A: its earlier state survived the tab switches.
        @test activate(server, tids["a"]); sleep(0.3)
        @test visible(server, "A")
        @test out_text(server, "a") == "A=2"
        @test bump_to(server, "a", "A=4")          # still live, c=2

        # Close each tab (activate it first → the active-tab close that restores):
        # the app returns to its bubble; the others stay tabbed and live.
        for a in APPS
            @test activate(server, tids[a.t]); sleep(0.3)
            @test until(() -> close_tab(server, tids[a.t]), () -> in_slot(server, a.L))
        end
        @test app_tab_count(server) == 0
        @test all(a -> in_slot(server, a.L), APPS)
        # All three live inline again.
        @test bump_to(server, "b", "B=13")
        @test out_text(server, "a") == "A=4"
        @test out_text(server, "c") == "C=101"
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
