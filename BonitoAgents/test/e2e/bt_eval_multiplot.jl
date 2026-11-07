# Several WGLMakie figures proxied from the eval worker into one chat, in several
# apps: two eval results each holding more than one figure plus a bare figure,
# all live over the eval bridge in the same page. The chat is reloaded with all
# of them open: every embed must come back with its text (the page's single glyph
# atlas is refilled from several worker-side sessions), and a figure must still
# update from the worker afterwards.
#
# UI-only: real dev_server, real eval worker, rendered-DOM assertions.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const PLOT_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))

figure_code(label, i) = """let
    fig = Figure(size = (380, 220))
    ax = Axis(fig[1, 1]; title = "$(label) $(i) Ω$(i)")
    lines!(ax, 1:10, (1:10) .* $(i))
    text!(ax, 5, 5 * $(i); text = "$(label) text $(i) ∑", align = (:center, :center), fontsize = 18)
    fig
end"""

# App A: three figures and a counter that retitles the first one from the worker.
const APP_A = """using WGLMakie, Bonito
App() do
    figs = [$(join((figure_code("A", i) for i in 1:3), ", "))]
    clicks = Observable(0)
    on(c -> (figs[1].content[1].title = "A 1 Ω1 clicked " * string(c) * " ⊕"), clicks)
    btn = DOM.div("retitle"; class = "multi-btn", onclick = js"(e) => \$(clicks).notify(\$(clicks).value + 1)")
    out = map(c -> "CLICKS=" * string(c), clicks)
    DOM.div(DOM.span("MULTI-A "), DOM.span(out; class = "multi-out"), btn, DOM.div(figs...; style = "display:flex; flex-wrap:wrap"))
end"""

const APP_B = """using WGLMakie, Bonito
App() do
    DOM.div(DOM.span("MULTI-B "), DOM.div($(join((figure_code("B", i) for i in 1:2), ", ")); style = "display:flex; flex-wrap:wrap"))
end"""

const FIG_C = "using WGLMakie\n" * figure_code("C", 1)

function multiplot_agent(prompt::AbstractString)
    occursin("plots", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    return Any[
        TK.text("three apps with plots:"),
        TK.bt_eval(APP_A; env_path = PLOT_ENV, id = "multi-a"),
        TK.bt_eval(APP_B; env_path = PLOT_ENV, id = "multi-b"),
        TK.bt_eval(FIG_C; env_path = PLOT_ENV, id = "multi-c"),
    ]
end

# Every figure on the page drew its first frame with a live context, and every
# text plot has all of its glyphs in the page's atlas.
rendered_js(n) = """(() => {
    const cs = [...document.querySelectorAll('canvas')];
    if (cs.length !== $(n) || document.querySelector('.wglmakie-spinner')) return false;
    if (!cs.every(c => c.wglmakie_screen && c.wglmakie_screen.renderer && c.width > 0 &&
        !c.wglmakie_screen.renderer.getContext().isContextLost())) return false;
    const atlas = WGL.get_texture_atlas();
    const plots = Object.values(WGL.plot_cache).map(m => m.plot_object).filter(p => p.glyph_info?.glyph_hashes);
    return plots.length >= $(n) && plots.every(p => Array.from(p.glyph_info.glyph_hashes).every(h => atlas.glyph_data.has(String(h))));
})()"""

out_is(s, want) = TK.eval_js(s,
    "(() => { const e=document.querySelector('.multi-out'); return !!(e && e.innerText==='$(want)'); })()") == true

function click_until(s, want)
    TK.eval_js(s, "(() => { const b=document.querySelector('.multi-btn'); if(b){b.click();return true} return false })()")
    return TK.wait_for(s, "clicks → $want",
        "(() => { const e=document.querySelector('.multi-out'); return !!(e && e.innerText==='$(want)'); })()";
        timeout = 8) == true
end

function reload_and_reopen(s, pid)
    TK.eval_js(s, "location.reload(); true")
    sleep(2)
    TK.wait_for(s, "page back up", "!!document.querySelector('.bt-sidebar')"; timeout = 30)
    TK.install_pane_scope!(s)
    TK.open_chat(s, pid)
    return TK.wait_for(s, "embeds re-mounted",
        "document.body.innerText.includes('MULTI-A') && document.body.innerText.includes('MULTI-B')"; timeout = 60) == true
end

function run_suite(server)
    server.agent_fn[] = multiplot_agent
    pid = TK.new_chat(server; title = "MultiPlot")
    TK.send_message(server, "show me the plots")

    @testset "six figures in three apps render live" begin
        @test TK.wait_for(server, "all three embeds mounted",
            "document.body.innerText.includes('MULTI-A') && document.body.innerText.includes('MULTI-B') && document.querySelectorAll('canvas').length === 6";
            timeout = 180) == true
        @test TK.wait_for(server, "six figures drawn with their text", rendered_js(6); timeout = 60) == true
        # The chat page already carries a Three.js of its own; WGLMakie's bundle brings
        # another and THREE warns once about it. Nothing else may be logged.
        logged = TK.check_console!()
        @test length(logged) == 1 && occursin("Multiple instances of Three.js", only(logged))
        @test TK.wait_for(server, "initial clicks", "(() => { const e=document.querySelector('.multi-out'); return !!(e && e.innerText==='CLICKS=0'); })()"; timeout = 30) == true
        @test click_until(server, "CLICKS=1")
        @test TK.wait_for(server, "retitled figure still drawn", rendered_js(6); timeout = 30) == true
        TK.screenshot(server, joinpath(tempdir(), "bt-eval-multiplot-live.png"))
    end

    @testset "all embeds come back with their text after a reload" begin
        @test reload_and_reopen(server, pid)
        @test TK.wait_for(server, "six figures drawn again", rendered_js(6); timeout = 120) == true
        # A reload re-renders the apps as fresh instances (see app_reload.jl), and
        # the fresh ones still round-trip through the worker.
        @test TK.wait_for(server, "fresh counter", "(() => { const e=document.querySelector('.multi-out'); return !!(e && e.innerText==='CLICKS=0'); })()"; timeout = 30) == true
        @test click_until(server, "CLICKS=1")
        @test TK.wait_for(server, "figures drawn after the update", rendered_js(6); timeout = 30) == true
        TK.screenshot(server, joinpath(tempdir(), "bt-eval-multiplot-reloaded.png"))
        logged = TK.check_console!()
        @test length(logged) == 1 && occursin("Multiple instances of Three.js", only(logged))
    end
    return
end
