# Cross-worker sync modal, UI wiring — migrated onto the TestKit harness (real
# dev_server, a SECOND real worker via add_worker!, real ACP wire, real Electron
# browser; only the agent's behaviour is faked via the `agent=` callback).
#
# Complements the backend test (test_cross_worker_sync.jl) by driving the actual
# DOM: the chat header surfaces a "⇄ <worker>" button only when the open project
# has a same-named sibling on ANOTHER worker; clicking it opens the comparison
# modal (render_sync_modal); the modal shows both sides and its Cancel / direction
# buttons behave.
#
# Setup that makes the ⇄ button appear (see `same_name_siblings`): two projects
# with the SAME display name on DIFFERENT workers. We:
#   1. Create "BonitoAgents" on the dev_server's first worker through the real
#      dashboard "+ New project" flow (new_chat) — that's the chat we open.
#   2. Add a SECOND real worker (add_worker!), then register a same-named sibling
#      on it via the real `create_project_from_worker!` (start_session=false — no
#      ACP bring-up needed; we only need the ProjectInfo registered so
#      same_name_siblings pairs them). This is the one piece the dashboard form
#      can't express against the harness (it always targets the first worker), so
#      it's done through the real server API — NOT a fake.
# Each side's worker_path + server mirror is seeded with real, distinct files so
# `compare_projects` (live worker inspect, with server-mirror fallback) has
# something to summarise.
#
# MIGRATION NOTES vs the legacy `make_state` + `mock_transport` version:
#   - `make_state(n_workers=2)`'s offline stub workers and the MockTransport
#     ChatModel are gone. Both workers here are REAL subprocesses; the chat is a
#     REAL chat. The two same-name projects are created through real server APIs.
#   - DOM assertions are unchanged in intent: ⇄ button present + names the other
#     worker, modal opens with two side panels + three action buttons + a title
#     naming the project + both worker names referenced, Cancel closes it, and a
#     direction pick closes it without a new JS error.
#   - Ends asserting `window.__errs` is empty.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn

const NM = "BonitoAgents"

@testset "cross-worker sync modal — ⇄ button, comparison modal, Cancel/apply" begin
    s = TK.dev_server(; agent = _msg -> [text("ok"), end_turn()])
    w2 = nothing
    try
        TK.open_browser(s; width = 1280, height = 820)

        # The dev_server's first worker (the one new_chat will bind to).
        w1_id = ""
        let deadline = time() + 30
            while time() < deadline
                w1_id = lock(s.h.state.lock) do
                    ids = [k for k in keys(s.h.state.workers[]) if
                           s.h.state.workers[][k].status === :online]
                    isempty(ids) ? "" : first(ids)
                end
                isempty(w1_id) || break
                sleep(0.2)
            end
        end
        @test !isempty(w1_id)

        # ── Add a SECOND real worker and register a same-name sibling on it ───
        # Done BEFORE new_chat so the sibling already exists when the chat
        # header is built (the ⇄ control is computed at header-build time).
        w2 = TK.add_worker!(s; name = "worker-b")
        w2_id = ""
        let deadline = time() + 30
            while time() < deadline
                w2_id = lock(s.h.state.lock) do
                    ids = [k for k in keys(s.h.state.workers[]) if k != w1_id &&
                           s.h.state.workers[][k].status === :online]
                    isempty(ids) ? "" : first(ids)
                end
                isempty(w2_id) || break
                sleep(0.2)
            end
        end
        @test !isempty(w2_id)

        # Seed worker-2's project folder (its projects_root is local to this box)
        # + the server mirror, so the live/mirror inspect both have real content.
        w2_root = lock(s.h.state.lock) do; s.h.state.workers[][w2_id].projects_root; end
        w2_path = joinpath(w2_root, NM)
        mkpath(w2_path)
        write(joinpath(w2_path, "README.md"), "FROM worker 2\n")
        write(joinpath(w2_path, "two.txt"), "2\n")

        p2 = BonitoAgents.create_project_from_worker!(s.h.state, w2_id, w2_path;
                                                      name = NM, start_session = false)
        # Make sure the server-side mirror dir exists too (mirror fallback path).
        mkpath(p2.server_path)
        write(joinpath(p2.server_path, "README.md"), "FROM worker 2\n")
        notify(s.h.state.projects)

        # ── Now create "BonitoAgents" on the first worker through the real
        #    dashboard "+ New project" flow. Its header, built here, already
        #    sees the worker-2 sibling → the ⇄ control renders. ────────────────
        cwd1 = mktempdir()
        write(joinpath(cwd1, "README.md"), "FROM worker 1\n")
        write(joinpath(cwd1, "one.txt"), "1\n")
        pid1 = TK.new_chat(s; cwd = cwd1, title = NM)

        w1_name = lock(s.h.state.lock) do; s.h.state.workers[][w1_id].name; end
        w2_name = lock(s.h.state.lock) do; s.h.state.workers[][w2_id].name; end

        # ── ⇄ button present only because a sibling exists ────────────────────
        @test TK.wait_for(s, "⇄ cross-worker button appears", """
            [...document.querySelectorAll('.bt-header-sync')].some(b => (b.innerText||'').includes('⇄'))
        """; timeout = 10) == true
        # It names the other worker.
        @test TK.eval_js(s, """
            [...document.querySelectorAll('.bt-header-sync')]
                .some(b => (b.innerText||'').includes('⇄') && (b.innerText||'').includes($(TK.json(w2_name))))
        """) == true

        # ── clicking ⇄ opens the comparison modal ─────────────────────────────
        TK.eval_js(s, """
            (() => { const b = [...document.querySelectorAll('.bt-header-sync')]
                        .find(x => (x.innerText||'').includes('⇄')); if (b) b.click(); return true; })()
        """)
        @test TK.wait_for(s, "modal overlay appears",
            "document.querySelector('.bt-collision-overlay') !== null"; timeout = 10) == true
        @test TK.eval_js(s, "document.querySelectorAll('.bt-collision-side').length") == 2
        @test TK.eval_js(s, "document.querySelectorAll('.bt-collision-actions button').length") == 3
        title = TK.eval_js(s, """(() => { const h = document.querySelector('.bt-collision-card h3');
            return h ? (h.innerText||'') : null; })()""")
        @test title isa AbstractString && occursin(NM, title)
        # Both workers should be named somewhere in the card.
        card = TK.eval_js(s, """(() => { const c = document.querySelector('.bt-collision-card');
            return c ? (c.innerText||'') : null; })()""")
        @test card isa AbstractString && occursin(w1_name, card) && occursin(w2_name, card)

        # ── Cancel closes the modal ───────────────────────────────────────────
        TK.click(s, ".bt-collision-actions .bt-btn-ghost")
        @test TK.wait_for(s, "overlay gone after Cancel",
            "document.querySelector('.bt-collision-overlay') === null"; timeout = 8) == true

        # ── a direction button dismisses the modal without a new JS error ─────
        # Re-open, then click the primary (push) direction. The apply runs the
        # real sync; whatever it does, the handler closes the modal in `finally`,
        # and the click itself must not throw.
        TK.eval_js(s, """
            (() => { const b = [...document.querySelectorAll('.bt-header-sync')]
                        .find(x => (x.innerText||'').includes('⇄')); if (b) b.click(); return true; })()
        """)
        @test TK.wait_for(s, "modal reopened",
            "document.querySelector('.bt-collision-overlay') !== null"; timeout = 8) == true
        errs_before = TK.eval_js(s, "(window.__errs || []).length")
        TK.click(s, ".bt-collision-actions .bt-btn-primary")
        @test TK.wait_for(s, "overlay closes after a direction pick",
            "document.querySelector('.bt-collision-overlay') === null"; timeout = 10) == true
        @test TK.eval_js(s, "(window.__errs || []).length") == errs_before

        TK.screenshot(s, joinpath(tempdir(), "bt-cross-worker-sync-ui-final.png"))

        # ── No JS errors across the whole flow ────────────────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        w2 === nothing || (try kill(w2) catch end)
        close(s)
    end
end
