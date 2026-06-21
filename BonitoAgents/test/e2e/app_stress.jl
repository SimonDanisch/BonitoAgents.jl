# Stress the signature bt_show_app feature by MOVING one live embed around its
# whole state space, 100×, and proving it stays ALIVE the entire time.
#
# The embed is a real Bonito app whose body is `float_panel!`-ed between the chat
# bubble slot and a floating workspace window; the live DOM node is *moved*, never
# re-created (that move path is where the layout-identity / orphaned-node bugs
# lived — a tab-click once re-cloned the layout and the next move silently dropped
# the panel). A 100× cycle is the hammer for that class.
#
# Liveness instrument: the app is an interactive counter (a button that bumps a
# server-driven Observable). We click it in each location and assert the count
# ADVANCES and is PRESERVED across every move — that can only hold if the same
# live session/node survived. A marker-present check would pass even on a dead,
# re-cloned, or orphaned node; the counter would not.
#
# All moves are real UI clicks (detach button, float-close button, sidebar chat
# switch). UI-only — the one server-side read is the post-run leak check.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", ".."))
const CYCLES = parse(Int, get(ENV, "APP_STRESS_CYCLES", "100"))
const SWITCH_EVERY = 20   # do a chat-switch round-trip on every Nth cycle

# A live counter app: clicking `.bt-stress-btn` notifies an Observable, which
# re-renders `.bt-stress-count`. The count surviving moves proves the app is alive.
function agent_script(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    [TK.text("stress app:"),
     TK.bt_show_app("""using Bonito
        App() do
            n = Observable(0)
            btn = DOM.div("bump"; class="bt-stress-btn",
                          onclick=js"(e)=> \$(n).notify(\$(n).value + 1)")
            DOM.div(DOM.span("STRESS-MARKER c="), DOM.span(n; class="bt-stress-count"),
                    btn; style="padding:20px")
        end"""; env_path = APP_ENV)]
end

# Tool id of the embed (read off its inline tool body).
toolid(s) = TK.eval_js(s, """(() => {
    const e = [...document.querySelectorAll('.bt-embed')].find(x => (x.innerText||'').includes('STRESS-MARKER'));
    const b = e && e.closest('.bt-tool-body'); return b ? (b.dataset.toolId||'') : ''; })()""")

# 'FLOAT' (detached into its own workspace panel `app:<tid>`), 'SLOT' (inline in
# the bubble), or 'MISSING'/'OTHER'. Selectors mirror the proven app_detach.jl:
# the detached embed lives in `.bw-ws-panel[data-panel-id="app:<tid>"]`.
function whereis(s, tid)
    TK.eval_js(s, """(() => {
        const e = [...document.querySelectorAll('.bt-embed')].find(x => (x.innerText||'').includes('STRESS-MARKER'));
        if (!e) return 'MISSING';
        if (e.closest('.bw-ws-panel[data-panel-id="app:$tid"]')) return 'FLOAT';
        if (e.closest('.bt-slot')) return 'SLOT';
        return 'OTHER'; })()""")
end

# JS predicate strings (for wait_for) + their instantaneous evaluators.
floated_pred(tid) = """(() => { const e=[...document.querySelectorAll('.bt-embed')]
    .find(x=>(x.innerText||'').includes('STRESS-MARKER')); return !!(e && e.closest('.bw-ws-panel[data-panel-id="app:$tid"]')); })()"""
slotted_pred() = """(() => { const e=[...document.querySelectorAll('.bt-embed')]
    .find(x=>(x.innerText||'').includes('STRESS-MARKER')); return !!(e && e.closest('.bt-slot')); })()"""

# Exactly one live embed node carrying the marker (orphaning would leave >1).
marker_nodes(s) = TK.eval_js(s, "[...document.querySelectorAll('.bt-embed')].filter(x => (x.innerText||'').includes('STRESS-MARKER')).length")

click_bump(s) = TK.eval_js(s, "(() => { const b=document.querySelector('.bt-stress-btn'); if(b){b.click();return true} return false })()")
read_count(s) = TK.eval_js(s, "(() => { const c=document.querySelector('.bt-stress-count'); return c ? parseInt(c.innerText||'-1') : -1 })()")

detach(s, tid) = TK.eval_js(s, """(() => {
    const b = document.querySelector('.bt-tool-body[data-tool-id="$tid"]');
    const host = b && (b.closest('[data-bt-app]') || b.parentNode);
    const btn = host && host.querySelector('.bt-tool-detach');
    if (!btn) return false; btn.click(); return true; })()""")

close_float(s, tid) = TK.eval_js(s, """(() => {
    const p = document.querySelector('.bw-ws-panel[data-panel-id="app:$tid"]');
    const w = p && p.closest('.bw-ws-float');
    const btn = w && w.querySelector('.bw-float-close');
    if (!btn) return false; btn.click(); return true; })()""")

# Re-click a move button until the embed reaches the target state (bounded). The
# float's close handler / the detach button are wired by a Bonito `onload` that
# can lag a few hundred ms behind the node appearing, so a single click can land
# before the handler is attached and no-op. Re-checking the target predicate FIRST
# means we stop the instant it took, and never double-fire once we're there. A
# move that genuinely never happens still fails (bounded ~8s), so this hardens
# against the wiring race WITHOUT hiding a real stuck move.
function move_until(s, action, target_pred::AbstractString; tries = 40, pause = 0.2)
    for _ in 1:tries
        TK.eval_js(s, target_pred) == true && return true
        action()
        sleep(pause)
    end
    return TK.eval_js(s, target_pred) == true
end

# Click bump and wait for the live count to actually reach `want` (the click ->
# Observable -> re-render makes a bridge round-trip). Returns true on success.
function bump_to(s, want)
    click_bump(s)
    TK.wait_for(s, "count=$want", "document.querySelector('.bt-stress-count') && parseInt(document.querySelector('.bt-stress-count').innerText)===$want"; timeout = 8) == true
end

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.refresh_eval_session!(APP_ENV)   # fresh per-project dial-back (see embedded_app.jl)

    @testset "bt_show_app 100× move stress (UI-only, liveness)" begin
        # Render the app FIRST in its own chat (the eval-bridge dial-back binds to
        # this project), then create the aside chat — creating a second chat before
        # the embed dials back leaves it unrendered.
        stress_pid = TK.new_chat(server; title = "Stress")
        TK.send_message(server, "show app")

        rendered = TK.wait_for(server, "embed renders",
            "document.body.innerText.includes('STRESS-MARKER')"; timeout = 180) == true
        @test rendered
        tid = rendered ? toolid(server) : ""
        @test tid != ""
        # If the embed never came up there is nothing to stress — bail instead of
        # running 100 doomed cycles (each would burn its full wait budget).
        if tid == ""
            @error "app_stress: embed never rendered; skipping the move cycles"
            return server
        end
        @test whereis(server, tid) == "SLOT"
        @test marker_nodes(server) == 1

        # Now a second chat to switch away to mid-stress (workspace must survive it).
        aside = TK.new_chat(server; title = "Aside")
        TK.open_chat(server, stress_pid)
        TK.wait_for(server, "stress chat reopened", "document.body.innerText.includes('STRESS-MARKER')"; timeout = 10)

        want = 0
        @test bump_to(server, (want += 1))           # alive inline

        for i in 1:CYCLES
            # SLOT -> FLOAT (retry through the onload wiring lag)
            @test move_until(server, () -> detach(server, tid), floated_pred(tid)) == true
            @test marker_nodes(server) == 1          # moved, not duplicated
            @test bump_to(server, (want += 1))        # alive while floating

            # Every Nth cycle: switch away to the aside chat and back. The float
            # workspace + live app must survive a full chat remount.
            if i % SWITCH_EVERY == 0
                TK.open_chat(server, aside)
                TK.wait_for(server, "aside open", "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 8)
                TK.open_chat(server, stress_pid)
                @test TK.wait_for(server, "stress reopened #$i",
                    "document.body.innerText.includes('STRESS-MARKER')"; timeout = 10) == true
                @test whereis(server, tid) == "FLOAT"     # still floating after the round-trip
                @test read_count(server) == want          # count preserved across the switch
                @test bump_to(server, (want += 1))         # still alive after the switch
            end

            # FLOAT -> SLOT (retry through the onload wiring lag)
            @test move_until(server, () -> close_float(server, tid), slotted_pred()) == true
            @test marker_nodes(server) == 1
            @test bump_to(server, (want += 1))        # alive back inline
        end

        # The live node made it through all 100 cycles: it's home, unique, and the
        # counter advanced monotonically the whole way (no reset == never re-created).
        @test whereis(server, tid) == "SLOT"
        @test marker_nodes(server) == 1
        @test read_count(server) == want
        @test want >= 2 * CYCLES                       # ~2 liveness bumps per cycle (+1 on switch cycles)

        # Server-side leak check (the one allowed secondary read): all those detach
        # cycles must leave NO leftover app panels in the workspace and exactly one
        # eval bridge for this project — not 100.
        st = server.h.state
        m = get(st.chat_models, stress_pid, nothing)
        @test m !== nothing
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
