# ChatModel stress matrix, migrated onto the TestKit harness (real dev_server,
# real worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked via the `agent=` callback).
#
# Sections (each preserves the legacy invariant; counts scaled where the
# invariant is structural — every scaling is noted):
#   1. 1000-message virtual scroll: totalCount converges to 1000, the window is
#      bounded (< 60 nodes rendered), the last seeded pair is at the bottom, no
#      message loss. Count NOT scaled — 1000 is the structural point (windowing).
#   2. 100-msg burst from Julia via `send!`: every push reaches JS (totalCount
#      converges), the server store has all of them. NOT scaled.
#   3. Two browser tabs of the same project: both see the seed, both pick up a
#      server-side push. Second tab opened via a raw ElectronCall window on the
#      same dev_server URL.
#   4. Fast open/close cycles: server-side store intact across reopen, totalCount
#      reconverges every time. SCALED 10 → 4 cycles (structural: each cycle is an
#      independent mount; 4 still exercises mount/unmount/rebootstrap repeatedly).
#   5. Drop browser mid-stream: pushes without a listener don't throw, the store
#      accumulates, a fresh window bootstraps to the full count.
#   6. Streaming agent chunks into one bubble via the message-as-target verbs
#      (`send!` opens, `append!` grows): the accumulated text lands, still pinned.
#   7. Project switch alpha ↔ beta with a background push to the inactive
#      project: each view shows the correct count, including the background push.
#
# MIGRATION NOTES vs the legacy `serve()` + raw-ElectronCall version:
#   - `fresh_state(...)` + ad-hoc `open_window` are gone. We boot one real
#     `dev_server` (real worker + real ACP) and create each project through
#     `BonitoAgents.create_project!` — the EXACT server-side path the dashboard
#     "+ New project" flow runs (seeds the server mirror, pushes to the worker,
#     registers the route + ChatModel, notifies the project list so the sidebar
#     row appears). We drive into each chat by clicking its real sidebar row
#     (`open_chat`), exactly as a user does. (We use `create_project!` rather
#     than the full folder-picker UI per section because this file creates ~7
#     projects; the picker UI is covered by the other migrated tests' single
#     `new_chat` call. The chat behaviours under test here are driven entirely
#     through the real DOM after navigation.)
#   - Long histories are seeded by pushing (UserMsg, AgentMsg) pairs straight
#     into `model.msgs_store` then emitting a single `msgs.count` and opening the
#     chat (range requests serve slices from `msgs_store`) — far cheaper than
#     1000 real ACP turns, and the virtual-scroll invariant is identical.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
import ElectronCall
const ECT = ElectronCall.Testing
using .TestKit: text, end_turn

# Create a project via the real server-side dashboard path and return its
# (pid, model). `name` must be alphanumeric/_/- (create_project! enforces it).
function make_project(s, name::AbstractString)
    st = s.h.state
    wname = first(keys(st.workers[]))           # the connected worker's id/key
    p = BT.create_project!(st, String(name), mktempdir(), wname)
    sleep(0.3)                                   # let the project_list notify land
    model = lock(st.lock) do; st.chat_models[p.id]; end
    return p.id, model
end

# Push `n` (UserMsg, AgentMsg) pairs into `model.msgs_store`, then emit a single
# `msgs.count` so JS bumps totalCount and (re)fetches the visible range. Texts
# are `hi i` / `ok i` so the tests can assert the final pair lands.
function seed_history!(model, n::Int)
    lock(model.lock) do
        for i in 1:n
            push!(model.msgs_store, BT.UserMsg("hi $i"))
            push!(model.msgs_store, BT.AgentMsg("agent-$i", "ok $i"))
        end
    end
    BT.chat_emit(model, Dict{String,Any}("type" => "msgs.count",
                                         "n" => length(model.msgs_store)))
    return model
end

# Chat panes are KEPT ALIVE: switching projects hides the old `.bt-chatpane`
# (display:none) but leaves its `.bt-messages` node in the DOM, so a bare
# `document.querySelector('.bt-messages')` can grab a hidden prior chat. Every
# assertion must target the VISIBLE pane. `VMSGS` is a JS expression that
# resolves the currently-visible messages container (offsetParent !== null).
const VMSGS = "[...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent !== null)"
# A `.bt-chat` accessor on the visible pane (null-safe).
const VCHAT = "(($VMSGS)?.__bt_chat)"

# Navigate into a chat by clicking its real sidebar row.
function goto_chat(s, pid)
    TK.open_chat(s, pid)
    TK.wait_for(s, "messages mounted", "($VCHAT)?.totalCount !== undefined"; timeout = 15)
end

total_eq(n) = "($VCHAT)?.totalCount === $n"
# Same, for a raw ElectronCall TestContext (second tab) — the second tab only
# ever opens one chat, but scope it the same way for symmetry / safety.
total_eq_ctx(n) = "($VCHAT)?.totalCount === $n"

@testset "chat stress matrix" begin
    s = TK.dev_server(; agent = _msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        # The browser must mount the dashboard before create_project! rows can be
        # clicked. Gate on the Home sidebar entry.
        TK.wait_for(s, "dashboard mounted",
            "document.querySelector('.bt-side-item[data-project-id=\\\"\\\"]') !== null"; timeout = 20)

        # ── 1. 1000-message virtual scroll integrity ──────────────────────────
        @testset "1k virtual scroll" begin
            pid, model = make_project(s, "stress-1k")
            seed_history!(model, 500)            # 500 pairs = 1000 messages
            goto_chat(s, pid)

            @test TK.wait_for(s, "totalCount → 1000", total_eq(1000); timeout = 20) == true
            # Last seeded user bubble is the final pair, pinned to the bottom
            # (scoped to the visible pane's bubbles).
            @test TK.wait_for(s, "last user bubble is hi 500", """
                (() => { const m = $VMSGS; if (!m) return false;
                         const us = m.querySelectorAll('.bt-user-msg');
                         return us.length > 0 && us[us.length-1].textContent.trim() === 'hi 500'; })()
            """; timeout = 20) == true
            @test TK.wait_for(s, "pinned at bottom",
                "($VCHAT)?.atBottom() === true"; timeout = 10) == true
            # Virtual scroll windows the DOM — only a small slice is rendered.
            rendered = Int(TK.eval_js(s,
                "(() => { const m = $VMSGS; return m ? m.querySelectorAll(':scope > .bt-user-msg, :scope > .bt-agent-msg').length : -1; })()"))
            @test rendered < 60
            @test length(model.msgs_store) == 1000   # no server-side loss
        end

        # ── 2. 100-msg burst from Julia via send! ─────────────────────────────
        @testset "100-msg burst" begin
            pid, model = make_project(s, "stress-burst")
            seed_history!(model, 5)              # 10 messages
            goto_chat(s, pid)
            @test TK.wait_for(s, "seed count 10", total_eq(10); timeout = 12) == true

            for i in 1:100
                BT.send!(model, BT.UserMsg("burst-$i"))
            end
            @test TK.wait_for(s, "burst count 110", total_eq(110); timeout = 15) == true
            @test length(model.msgs_store) == 110
        end

        # ── 3. Multi-tab sync (second raw ElectronCall window) ────────────────
        @testset "multi-tab sync" begin
            pid, model = make_project(s, "stress-multitab")
            seed_history!(model, 3)             # 6 messages
            goto_chat(s, pid)
            @test TK.wait_for(s, "tab A seed 6", total_eq(6); timeout = 12) == true

            # Second tab: a fresh window on the same dev_server URL, navigated to
            # the same project via its sidebar row.
            url = "http://127.0.0.1:$(s.h.state.srv.port)/"
            ctx2 = ECT.open_window(url; width = 1280, height = 820, show = false)
            try
                ECT.install_error_sink(ctx2)
                sleep(3.0)
                ECT.wait_for(ctx2, """!!document.querySelector('.bt-side-item[data-project-id="$pid"]')""";
                             timeout = 12.0)
                ECT.eval_js(ctx2, """(() => { const el =
                    document.querySelector('.bt-side-item[data-project-id="$pid"]'); el && el.click(); return true; })()""")
                ECT.wait_for(ctx2, "($VCHAT)?.totalCount !== undefined"; timeout = 15.0)
                @test ECT.wait_for(ctx2, total_eq_ctx(6); timeout = 15.0) == true

                # A server-side push reaches BOTH tabs.
                BT.send!(model, BT.UserMsg("broadcast"))
                @test TK.wait_for(s, "tab A picked up push", total_eq(7); timeout = 12) == true
                @test ECT.wait_for(ctx2, total_eq_ctx(7); timeout = 12.0) == true

                errs2 = ECT.eval_js(ctx2, "window.__errs || []")
                @test isempty(errs2)
            finally
                try close(ctx2) catch end
            end
        end

        # ── 4. Fast open/close cycles (scaled 10 → 4) ─────────────────────────
        @testset "reopen cycles" begin
            pid, model = make_project(s, "stress-reload")
            seed_history!(model, 4)             # 8 messages
            converged = true
            for i in 1:4                         # SCALED from 10 — structural
                goto_chat(s, pid)                # bounces through the dashboard
                (TK.wait_for(s, "cycle $i seed 8", total_eq(8); timeout = 12) == true) || (converged = false)
            end
            @test converged
            @test length(model.msgs_store) == 8   # server store intact across reopens
        end

        # ── 5. Drop browser mid-stream; reconnect bootstraps ──────────────────
        @testset "drop + reconnect" begin
            pid, model = make_project(s, "stress-drop")
            seed_history!(model, 5)             # 10 messages
            goto_chat(s, pid)
            @test TK.wait_for(s, "pre-drop 10", total_eq(10); timeout = 12) == true

            # Drop the browser entirely, then keep pushing — must not throw.
            close(s.browser[]); s.browser[] = nothing
            threw = false
            try
                for i in 1:50
                    BT.send!(model, BT.UserMsg("offline-$i"))
                end
            catch
                threw = true
            end
            @test threw == false
            @test length(model.msgs_store) == 60

            # Reconnect: fresh window bootstraps to the full count.
            TK.open_browser(s; width = 1280, height = 820)
            TK.wait_for(s, "dashboard remounted",
                "document.querySelector('.bt-side-item[data-project-id=\\\"\\\"]') !== null"; timeout = 20)
            goto_chat(s, pid)
            @test TK.wait_for(s, "reconnect bootstraps to 60", total_eq(60); timeout = 18) == true
        end

        # ── 6. Streaming agent chunks into one bubble ─────────────────────────
        @testset "streaming chunks" begin
            pid, model = make_project(s, "stress-stream")
            seed_history!(model, 10)            # 20 messages
            goto_chat(s, pid)
            @test TK.wait_for(s, "seed 20", total_eq(20); timeout = 12) == true

            bubble = BT.send!(model, BT.AgentMsg(model, "Lorem "))
            for t in ["ipsum ", "dolor ", "sit ", "amet, ", "consectetur ", "adipiscing ", "elit."]
                BT.append!(bubble, t)
                sleep(0.2)
            end
            @test TK.wait_for(s, "accumulated chunks landed", """
                (() => { const m = $VMSGS; if (!m) return false;
                         const ag = m.querySelectorAll('.bt-agent-msg');
                         return ag.length > 0 &&
                                ag[ag.length-1].textContent.includes('Lorem ipsum dolor sit amet'); })()
            """; timeout = 20) == true
            @test TK.eval_js(s, "($VCHAT)?.atBottom() === true") == true
        end

        # ── 7. Project switch with a background push ──────────────────────────
        @testset "project switch" begin
            pid_a, a = make_project(s, "alpha"); seed_history!(a, 3)   # 6 messages
            pid_b, b = make_project(s, "beta");  seed_history!(b, 7)   # 14 messages

            goto_chat(s, pid_a)
            @test TK.wait_for(s, "alpha shows 6", total_eq(6); timeout = 12) == true

            # Push to beta while viewing alpha.
            BT.send!(b, BT.UserMsg("background-beta"))

            goto_chat(s, pid_b)
            @test TK.wait_for(s, "beta shows 15 (14 + background)", total_eq(15); timeout = 18) == true

            goto_chat(s, pid_a)
            @test TK.wait_for(s, "back to alpha still 6", total_eq(6); timeout = 18) == true
        end

        # ── No JS errors across the whole matrix ──────────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
