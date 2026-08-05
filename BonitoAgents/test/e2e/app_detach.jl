# Detaching a bt_show_app embed: it becomes its OWN workspace panel that adopts
# the live embed node, and closing the panel returns the embed to its bubble.
#
# Regression for the lose-the-content bug: the old design moved every embed into
# ONE shared `#bt-app-mount` and resolved it with `getElementById`, so a stale /
# duplicate node could win and the move silently no-op'd (panel blank, embed
# stuck inline). Now each embed gets its own panel keyed by tool id, resolved via
# the chat's canonical `toolSlot` — and several apps can be detached at once.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", "appenv"))

# Each "app N" prompt renders a distinct, uniquely-marked live Bonito app.
function agent_script(prompt::AbstractString)
    m = match(r"app (\d+)", lowercase(prompt))
    m === nothing && return [TK.text("Echo: $(prompt)")]
    n = m.captures[1]
    [TK.text("app $n:"),
     TK.bt_show_app("""using Bonito; App(() -> DOM.div("APP-MARKER-$n"; style="padding:30px"))""";
                    env_path = APP_ENV)]
end

# Tool id of app N (read off its inline tool body).
toolid(s, n) = TK.eval_js(s, """(() => {
    const e = [...document.querySelectorAll('.bt-embed')].find(x => (x.innerText||'').includes('APP-MARKER-$n'));
    const b = e && e.closest('.bt-tool-body'); return b ? (b.dataset.toolId||'') : ''; })()""")

# Where app N's embed lives: its OWN panel (app:<tid>), its inline SLOT, or gone.
function whereis(s, n, tid)
    TK.eval_js(s, """(() => {
        const e = [...document.querySelectorAll('.bt-embed')].find(x => (x.innerText||'').includes('APP-MARKER-$n'));
        if (!e) return 'MISSING';
        const p = e.closest('.bw-ws-panel');
        if (p && p.dataset.panelId === 'app:$tid') return 'OWN-PANEL';
        if (e.closest('.bt-slot')) return 'SLOT';
        return 'OTHER'; })()""")
end

detach_btn(s, tid) = TK.eval_js(s, """(() => {
    const b = document.querySelector('.bt-tool-body[data-tool-id="$tid"]');
    const host = b && (b.closest('[data-bt-app]') || b.parentNode);
    const btn = host && host.querySelector('.bt-tool-detach');
    if (!btn) return false; btn.click(); return true; })()""")

function run_suite(server)
    server.agent_fn[] = agent_script
    # Fresh per-project dial-back so this suite's apps don't inherit a prior
    # suite's stale eval-worker binding (see TestKit.refresh_eval_session!).
    TK.refresh_eval_session!(APP_ENV)

    @testset "BonitoAgents bt_show_app detach (UI-only)" begin
        TK.new_chat(server; title = "Detach")

        # Two apps so we exercise the multi-panel case the old single-mount
        # design couldn't do. The Malt cold start + Bonito load is heavy.
        tids = String[]
        for n in 1:2
            TK.send_message(server, "app $n")
            @test TK.wait_for(server, "app $n rendered",
                "(() => [...document.querySelectorAll('.bt-embed')].some(x => (x.innerText||'').includes('APP-MARKER-$n')))()";
                timeout = n == 1 ? 180 : 90) == true
            push!(tids, toolid(server, n))
        end

        # Detach BOTH — each adopts its embed into its OWN panel, simultaneously.
        @test detach_btn(server, tids[1]) == true
        @test TK.wait_for(server, "app 1 in own panel",
            "(() => { const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('APP-MARKER-1')); return !!(e && e.closest('.bw-ws-panel[data-panel-id=\"app:$(tids[1])\"]')); })()"; timeout = 10) == true
        @test detach_btn(server, tids[2]) == true
        @test TK.wait_for(server, "app 2 in own panel",
            "(() => { const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('APP-MARKER-2')); return !!(e && e.closest('.bw-ws-panel[data-panel-id=\"app:$(tids[2])\"]')); })()"; timeout = 10) == true
        # Both detached at once into separate panels.
        @test whereis(server, 1, tids[1]) == "OWN-PANEL"
        @test whereis(server, 2, tids[2]) == "OWN-PANEL"

        # Close app 1's panel → its embed returns to its bubble slot; app 2 stays
        # detached and untouched.
        @test TK.eval_js(server, """(() => {
            const p = document.querySelector('.bw-ws-panel[data-panel-id="app:$(tids[1])"]');
            const win = p && p.closest('.bw-ws-float');
            const btn = win && win.querySelector('.bw-float-close');
            if (!btn) return false; btn.click(); return true; })()""") == true
        @test TK.wait_for(server, "app 1 restored to bubble",
            "(() => { const e=[...document.querySelectorAll('.bt-embed')].find(x=>(x.innerText||'').includes('APP-MARKER-1')); return !!(e && e.closest('.bt-slot')); })()"; timeout = 10) == true
        @test whereis(server, 1, tids[1]) == "SLOT"
        @test whereis(server, 2, tids[2]) == "OWN-PANEL"   # the other app unaffected
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
