# A browser page RELOAD must not kill live embeds: re-opening a chat must
# re-mount its bt_show_app apps fully ALIVE, not as dead DOM.
#
# The regression this pins: the worker-side RemoteProxy bridge parent is a
# long-lived root session serving many browser pages. Bonito dedups
# serialization (`session_objects`), asset emission (`imports` /
# `global_stylesheets`) and integration state (root `metadata`, e.g.
# WGLMakie's scene-init order counter) against that root "for the page's
# lifetime" — but a reload replaces the page while the bridge root lives on.
# Without `switch_page!` wiping that state per page, a re-mounted embed's
# fragment references cached objects the new page never received: the DOM
# still mounts (it rides in the html fragment), but interpolated observables
# are undefined on the JS side, so interaction is silently dead (and a
# WGLMakie canvas stays black forever). The interaction round trip below is
# therefore THE assertion: it only passes if the remount shipped full values
# against the blank page.
#
# UI-only: real reload, DOM clicks, rendered-DOM assertions.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

const APP_ENV = abspath(joinpath(@__DIR__, "..", "appenv"))

# Same shape as app_interactive.jl: the visible output is a Julia `map`
# (11×clicks) computed in the Malt worker, so a correct value can only appear
# if the click round-tripped through the eval bridge. Observables are created
# inside `App() do` — every (re)mount starts a fresh instance at 0.
function agent_script(prompt::AbstractString)
    occursin("app", lowercase(prompt)) || return [TK.text("Echo: $(prompt)")]
    appcode = """using Bonito
        App() do
            clicks = Observable(0)
            out = map(c -> "RAPP=" * string(11c), clicks)
            btn = DOM.div("bump"; class="rapp-btn",
                          onclick=js"(e)=> \$(clicks).notify(\$(clicks).value + 1)")
            DOM.div(DOM.span("RELOAD-APP "), DOM.span(out; class="rapp-out"),
                    btn; style="padding:16px")
        end"""
    # An edit tool alongside the app: a history-REPLAYED edit pill starts with
    # an empty body (the diff arrives via a tool.render round trip on expand),
    # which regressed to permanently-unexpandable once (Collapsable gated the
    # lazy fetch on !editMode). The post-reload expand below pins that.
    diff = TK.diff_block("src/thing.jl",
        "function f(x)\n    return x\nend\n",
        "function f(x)\n    # doubled\n    return 2x\nend\n")
    return [TK.text("reload app:"),
            TK.tool(kind = "edit", title = "Edit src/thing.jl", tool_name = "Edit",
                    content = Any[diff]),
            TK.bt_show_app(appcode; env_path = APP_ENV)]
end

# Expand the replayed Edit pill by clicking its header (the whole header is
# the expand target while collapsed) and wait for the Monaco diff to arrive.
function expand_edit_pill(s)
    clicked = TK.eval_js(s, """(() => {
        const p = [...document.querySelectorAll('.bt-tool-msg')]
            .find(e => e.offsetParent && (e.innerText||'').includes('Edit src/thing.jl'));
        if (!p) return false;
        p.querySelector('.bt-tool-header').click();
        return true; })()""")
    clicked == true || return false
    return TK.wait_for(s, "replayed diff renders",
        """(() => {
            const p = [...document.querySelectorAll('.bt-tool-msg')]
                .find(e => e.offsetParent && (e.innerText||'').includes('Edit src/thing.jl'));
            return !!(p && p.querySelector('.monaco-diff-editor-div, .monaco-diff-editor'));
        })()"""; timeout = 20) == true
end

# Click the app's button and wait for the WORKER-computed output — a full
# bridge round trip through the currently mounted subsession.
function reload_click_until(s, want)
    TK.eval_js(s, "(() => { const b=document.querySelector('.rapp-btn'); if(b){b.click();return true} return false })()")
    return TK.wait_for(s, "rapp → $want",
        "(() => { const e=document.querySelector('.rapp-out'); return !!(e && e.innerText==='$(want)'); })()";
        timeout = 8) == true
end

# Real page reload: the old JS world (sessions, object cache, module registry)
# dies; the electron window and the server stay up. Re-scope the pane helpers
# and navigate back into the chat, which replays the tool render and re-mounts
# the embed over the same worker-side bridge.
function reload_and_reopen(s, pid)
    TK.eval_js(s, "location.reload(); true")
    sleep(2)
    TK.wait_for(s, "page back up", "!!document.querySelector('.bt-sidebar')"; timeout = 30)
    TK.install_pane_scope!(s)
    TK.open_chat(s, pid)
    return TK.wait_for(s, "embed re-mounted",
        "document.body.innerText.includes('RELOAD-APP')"; timeout = 60) == true
end

function run_suite(server)
    server.agent_fn[] = agent_script
    TK.refresh_eval_session!(APP_ENV)

    @testset "live embed survives page reload (UI-only)" begin
        pid = TK.new_chat(server; title = "ReloadApp")
        TK.send_message(server, "show the app")

        # Baseline: first mount on the first page, live round trip.
        @test TK.wait_for(server, "app renders",
            "document.body.innerText.includes('RELOAD-APP')"; timeout = 180) == true
        @test TK.wait_for(server, "initial out",
            "(() => { const e=document.querySelector('.rapp-out'); return !!(e && e.innerText==='RAPP=0'); })()";
            timeout = 10) == true
        @test reload_click_until(server, "RAPP=11")

        # Reload #1: first page→page transition on the bridge. The re-mounted
        # embed must be a live app (fresh instance at 0, clicks round-trip),
        # not dead DOM.
        @test reload_and_reopen(server, pid)
        @test TK.wait_for(server, "fresh instance after reload",
            "(() => { const e=document.querySelector('.rapp-out'); return !!(e && e.innerText==='RAPP=0'); })()";
            timeout = 15) == true
        @test reload_click_until(server, "RAPP=11")
        @test reload_click_until(server, "RAPP=22")

        # The replayed Edit pill must still be expandable: click the header,
        # the diff arrives via tool.render and Monaco mounts.
        @test expand_edit_pill(server)

        # Reload #2: repeat once more — every page change must reset the
        # bridge's page-lifetime state, not just the first.
        @test reload_and_reopen(server, pid)
        @test TK.wait_for(server, "fresh instance after 2nd reload",
            "(() => { const e=document.querySelector('.rapp-out'); return !!(e && e.innerText==='RAPP=0'); })()";
            timeout = 15) == true
        @test reload_click_until(server, "RAPP=11")
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
