# Virtual scroll, migrated onto the TestKit harness (real dev_server, real worker
# subprocess, real ACP wire, real Electron browser). A populated history (200
# messages) must NOT all live in the DOM at once: only the visible-window slice
# (plus overscan) is materialised; scrolling fetches the next slice via
# requestRange and evicts off-screen nodes.
#
# No agent stream is needed here — 200 real streamed turns would be glacial.
# Instead we seed the 200 messages straight into the REAL `model.msgs_store`
# server-side, then re-broadcast `msgs.count` and re-open the chat pane so a
# FRESH JS Chat instance bootstraps from n=200 and runs its initial-load
# windowing through the REAL render path (the same path a reloaded long chat
# takes). Only the messages' origin is faked; the virtualization is the real
# production code.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents

const N_HISTORY = 200    # 100 user + 100 agent pairs

# Push `n` (UserMsg "hi i", AgentMsg "ok i") pairs straight into the store, then
# re-broadcast the count so the (re-opened) client bootstraps from it.
function seed_history!(model, n::Int)
    lock(model.lock) do
        for i in 1:n
            push!(model.msgs_store, BT.UserMsg("hi $i"))
            push!(model.msgs_store, BT.AgentMsg("agent-$i", "ok $i"))
        end
    end
    BT.chat_emit(model, Dict{String,Any}(
        "type" => "msgs.count", "n" => length(model.msgs_store)))
    return model
end

@testset "virtual scroll — 200-msg history windows the DOM, scroll fetches more" begin
    s = TK.dev_server()
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        # Seed 200 messages into the real store + re-broadcast the count.
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end
        seed_history!(model, N_HISTORY ÷ 2)
        @test length(model.msgs_store) == N_HISTORY

        # Re-open the chat pane (Home → back) so a FRESH JS Chat instance reads
        # the latest `msgs.count` (n=200) on connect and runs the initial-load
        # windowing cascade — exactly the reloaded-long-chat path.
        TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\"\"]').click()")
        sleep(0.5)
        TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\"$pid\"]').click()")
        TK.wait_for(s, "chat re-mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        # ── Initial mount renders only a window ───────────────────────────────
        @test TK.wait_for(s, "some bubbles materialised",
            "document.querySelectorAll('.bt-user-msg, .bt-agent-msg').length > 0"; timeout = 15) == true
        sleep(0.5)  # let initial scroll-to-bottom + ResizeObserver settle
        n_in_dom = Int(TK.eval_js(s,
            "document.querySelectorAll('.bt-user-msg, .bt-agent-msg').length"))
        @test n_in_dom > 0
        # Seeded 200; windowing must cap the DOM well below the total (a broken
        # virtual scroll would show all 200). ~15-20 + overscan is typical.
        @test n_in_dom < 100
        # totalCount mirrors the model.
        @test Int(TK.eval_js(s,
            "document.querySelector('.bt-messages').__bt_chat.totalCount")) == N_HISTORY

        # ── Initial scroll parks at the bottom (newest message) ───────────────
        @test TK.wait_for(s, "'ok 100' bubble surfaces near the bottom", """
            (() => Array.from(document.querySelectorAll('.bt-agent-msg'))
                     .some(e => e.innerText === 'ok 100'))()
        """; timeout = 10) == true
        @test TK.eval_js(s, """
            (() => { const c = document.querySelector('.bt-messages');
                     return c && (c.scrollHeight - (c.scrollTop + c.clientHeight) < 200); })()
        """) == true

        # ── Scroll up triggers a new range fetch + new bubbles render ─────────
        top_before = TK.eval_js(s, """
            (() => { const els = document.querySelectorAll('.bt-user-msg, .bt-agent-msg');
                     return els.length > 0 ? els[0].innerText : ''; })()
        """)
        # Jump to scrollTop = 0 and dispatch a synthetic 'scroll' (offscreen
        # renderers don't fire it on programmatic scrollTop assignment).
        TK.eval_js(s, """
            (() => { const c = document.querySelector('.bt-messages');
                     if (c) { c.scrollTop = 0; c.dispatchEvent(new Event('scroll')); }
                     return true; })()""")
        @test TK.wait_for(s, "a different top bubble appears after scrolling up", """
            (() => { const els = document.querySelectorAll('.bt-user-msg, .bt-agent-msg');
                     return els.length > 0 && els[0].innerText !== $(TK.json(top_before)); })()
        """; timeout = 8) == true
        # The first seeded message ("hi 1") becomes visible at the very top.
        @test TK.wait_for(s, "'hi 1' bubble visible at top", """
            (() => Array.from(document.querySelectorAll('.bt-user-msg'))
                     .some(e => e.innerText === 'hi 1'))()
        """; timeout = 8) == true

        # ── Spacers maintain the virtual scrollHeight ─────────────────────────
        # spacer-top + visible bubbles + spacer-bottom ≈ N_HISTORY * EST_HEIGHT
        # (~80px each → ~16000px). scrollHeight reflects the full virtual content.
        @test Int(TK.eval_js(s,
            "document.querySelector('.bt-messages').scrollHeight")) >= 8000

        TK.screenshot(s, joinpath(tempdir(), "bt-virtual-scroll-final.png"))

        # ── No JS errors during the scroll exercise ───────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
