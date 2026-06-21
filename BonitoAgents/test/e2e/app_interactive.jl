# Interacting with a live bt_show_app must run its JULIA logic in the worker and
# reflect the result back through the eval bridge — and several independent apps
# must each react on their own.
#
# Each app's visible output is a `map(...)` computed IN JULIA (in the Malt worker
# where the app is defined), over a click counter. The DOM click only bumps the
# raw counter; the OUTPUT (e.g. 7×clicks) is never computed in JS — so a correct
# output value can ONLY appear if the click round-tripped to the worker, the map
# ran there, and the new value streamed back. A broken bridge leaves the output
# stale. We drive real clicks and assert the Julia-computed output, and that the
# two apps stay independent.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", ".."))

# Two interactive apps with DISTINCT Julia-side formulas (so an output can't be
# confused for the other's): A shows 7×clicks, B shows 100+clicks. The onclick
# only bumps the counter; the formula is a Julia `map` in the worker.
function agent_script(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    appcode(tag, formula) = """using Bonito
        App() do
            clicks = Observable(0)
            out = map(c -> "$(tag)=" * string($(formula)), clicks)
            btn = DOM.div("bump $(tag)"; class="iapp-$(lowercase(tag))-btn",
                          onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
            DOM.div(DOM.span("IAPP-$(tag) "), DOM.span(out; class="iapp-$(lowercase(tag))-out"),
                    btn; style="padding:16px")
        end"""
    [TK.text("two interactive apps:"),
     TK.bt_show_app(appcode("A", "7c"); env_path = APP_ENV),
     TK.bt_show_app(appcode("B", "100 + c"); env_path = APP_ENV)]
end

out_text(s, tag) = TK.eval_js(s, "(() => { const e=document.querySelector('.iapp-$(tag)-out'); return e ? e.innerText : '<none>' })()")
click_app(s, tag) = TK.eval_js(s, "(() => { const b=document.querySelector('.iapp-$(tag)-btn'); if(b){b.click();return true} return false })()")

# Click `tag`'s button and wait until its Julia-computed output reaches `want`
# (the click → worker map → DOM update is a full bridge round-trip).
function click_until(s, tag, want)
    click_app(s, tag)
    TK.wait_for(s, "$tag → $want",
        "(() => { const e=document.querySelector('.iapp-$(tag)-out'); return !!(e && e.innerText==='$(want)'); })()";
        timeout = 8) == true
end

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.refresh_eval_session!(APP_ENV)

    @testset "bt_show_app interaction round-trips through Julia (UI-only)" begin
        TK.new_chat(server; title = "Interactive")
        TK.send_message(server, "show two apps")

        # Both live apps render; their Julia maps produce the initial values.
        @test TK.wait_for(server, "app A renders", "document.body.innerText.includes('IAPP-A')"; timeout = 180) == true
        @test TK.wait_for(server, "app B renders", "document.body.innerText.includes('IAPP-B')"; timeout = 90) == true
        @test TK.wait_for(server, "A initial", "(() => { const e=document.querySelector('.iapp-a-out'); return !!(e && e.innerText==='A=0'); })()"; timeout = 10) == true
        @test out_text(server, "b") == "B=100"

        # Interact with A three times: each click must run A's Julia map (7×clicks)
        # in the worker. B must NOT change (independent sessions).
        @test click_until(server, "a", "A=7")
        @test click_until(server, "a", "A=14")
        @test click_until(server, "a", "A=21")
        @test out_text(server, "b") == "B=100"      # B untouched

        # Now interact with B twice: B's Julia map (100+clicks) updates; A is frozen.
        @test click_until(server, "b", "B=101")
        @test click_until(server, "b", "B=102")
        @test out_text(server, "a") == "A=21"        # A untouched

        # A keeps its own state and keeps reacting after B was driven.
        @test click_until(server, "a", "A=28")
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
