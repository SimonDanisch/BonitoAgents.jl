# Two browser tabs on ONE project, each mounting the SAME live eval result.
#
# The per-page-root design gives each tab its own proxied root (own object cache,
# own `page_conn`), so both embeds are live SIMULTANEOUSLY and their interaction
# round-trips are INDEPENDENT — a click in tab B never moves tab A. This is the
# regression the old single `root_conn` could NOT pass: the second tab clobbered
# the first's relay target, so one embed always went dead.
#
# The value round-trips through the worker (`out = map(11c)` computed in the Malt
# worker), so a correct number can only appear if that tab's click reached its own
# page-root and the reply came back to THAT tab. Each (re)mount renders the held
# App afresh → each tab starts its own fresh instance at 0.
#
# UI-only: two REAL electron windows on one dev_server, DOM assertions only.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit
const ECT = TK.ECT            # raw ElectronCall.Testing to drive the SECOND window

const APP_ENV = abspath(joinpath(@__DIR__, "..", "evalenv"))

const TWOAPP = """using Bonito
    App() do
        clicks = Observable(0)
        out = map(c -> "TWO=" * string(11c), clicks)
        DOM.div(DOM.span("TWO-TAB "), DOM.span(out; class="two-out"),
                DOM.div("bump"; class="two-btn",
                        onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)");
                style="padding:16px")
    end"""

two_agent(prompt::AbstractString) =
    occursin("app", lowercase(prompt)) ?
        Any[TK.text("two-tab app:"), TK.bt_eval(TWOAPP; env_path = APP_ENV, id = "two-tab")] :
        [TK.text("Echo: $(prompt)")]

out_pred(want) = "(() => { const e=document.querySelector('.two-out'); return !!(e && e.innerText==='$(want)'); })()"

# Tab A is the shared TestServer browser; click its button once and wait for the
# worker-computed value (a full bridge round trip through A's page-root).
function a_click_wait(s, want)
    TK.eval_js(s, "(() => { const b=document.querySelector('.two-btn'); if(b){b.click();return true} return false })()")
    return TK.wait_for(s, "A → $want", out_pred(want); timeout = 10) == true
end

# Tab B is a second raw ECT window; poll a predicate / click on it directly.
function b_wait(ctx, predicate; timeout = 30)
    t0 = time()
    while time() - t0 < timeout
        try
            ECT.eval_js(ctx, predicate) === true && return true
        catch
        end
        sleep(0.3)
    end
    return false
end
b_out(ctx) = try
    ECT.eval_js(ctx, "(() => { const e=document.querySelector('.two-out'); return e ? e.innerText : ''; })()")
catch
    ""
end
function b_click_wait(ctx, want)
    ECT.eval_js(ctx, "(() => { const b=document.querySelector('.two-btn'); if(b){b.click();return true} return false })()")
    return b_wait(ctx, out_pred(want); timeout = 10)
end

function run_suite(server)
    server.agent_fn[] = two_agent

    @testset "two tabs on one project: independent live embeds (UI-only)" begin
        pid = TK.new_chat(server; title = "TwoTab")
        TK.send_message(server, "show the app")

        # Tab A: embed mounts live; a click round-trips 0 → 11.
        @test TK.wait_for(server, "A renders",
            "document.body.innerText.includes('TWO-TAB')"; timeout = 180) == true
        @test TK.wait_for(server, "A initial", out_pred("TWO=0"); timeout = 30) == true
        @test a_click_wait(server, "TWO=11")

        # Tab B: a SECOND real window on the SAME chat. Open the dashboard, then
        # open the SAME chat via its sidebar entry (exactly like TestKit.open_chat,
        # but driven on the second window). History replay re-mounts the SAME parked
        # value into a fresh per-page render → its own instance @ 0.
        url  = "http://127.0.0.1:$(server.h.state.srv.port)/"
        ctxB = ECT.open_window(url; show = false)
        try
            ECT.install_error_sink(ctxB)
            @test b_wait(ctxB, "!!document.querySelector('.bt-side-item[data-project-id=\"$(pid)\"]')"; timeout = 60)
            ECT.eval_js(ctxB, """(() => {
                const el = document.querySelector('.bt-side-item[data-project-id="$(pid)"]');
                if (!el) return false; el.click(); return true; })()""")
            @test b_wait(ctxB, "document.body.innerText.includes('TWO-TAB')"; timeout = 90)
            # B starts fresh at 0 even though A is already at 11 — independent roots.
            @test b_wait(ctxB, out_pred("TWO=0"); timeout = 40)

            # Two clicks in B → B reaches 22 via ITS OWN worker round trip…
            @test b_click_wait(ctxB, "TWO=11")
            @test b_click_wait(ctxB, "TWO=22")
            # …while A is UNTOUCHED at 11 (no clobber across page-roots).
            @test TK.eval_js(server,
                "(() => { const e=document.querySelector('.two-out'); return e && e.innerText; })()") == "TWO=11"

            # And a click in A moves ONLY A (→ 22); B stays at 22.
            @test a_click_wait(server, "TWO=22")
            @test b_out(ctxB) == "TWO=22"

            @test isempty(ECT.js_errors(ctxB))
        finally
            try
                ECT.close(ctxB)
            catch e
                e isa InterruptException && rethrow()
                @debug "two_tab: closing second window failed" exception = e
            end
        end
        @test isempty(TK.js_errors(server))
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = two_agent)
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
