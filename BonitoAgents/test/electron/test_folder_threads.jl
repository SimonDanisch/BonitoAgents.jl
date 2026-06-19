# Folder→threads browser + active-chats sidebar — migrated onto the TestKit
# harness (real dev_server, real worker subprocess, real ACP wire, real Electron
# browser; only the agent's behaviour is faked via the `agent=` callback).
#
# Two things are proven against the LIVE DOM:
#
#  1. ACTIVE-CHATS SIDEBAR. A real chat created through the dashboard
#     ("+ New project" → new_chat) starts a live ChatModel, which makes the
#     project appear in the left sidebar as a `.bt-side-item[data-project-id]`
#     carrying a close ✕ (`.bt-side-close`). Clicking the ✕ stops the chat and
#     removes its row.
#
#  2. FOLDER→THREADS TREE (the KeyedList-driven discover panel). dev_server's
#     real worker has no real ~/.claude sessions to scan, so — exactly as
#     production's `scan_and_store!` would have — we publish a discovered set
#     directly into `state.discovered[<worker_id>]` and `notify` it. The browser
#     then renders the worker's `.bt-discover-panel` with one `.bt-group`
#     <details> per folder path, each row leading with the cleaned first prompt
#     (`.bt-session-name-text`), a "+ New thread" control, and a "Resume" button
#     for sessions that carry a session_id.
#
# MIGRATION NOTES vs the legacy `make_state` + `mock_transport` version:
#   - The legacy test hand-built an offline state, a MockTransport ChatModel, and
#     poked `state.discovered` directly. The MockTransport fake is gone; the chat
#     is now a REAL chat created through the dashboard flow (new_chat), which is
#     also what populates the active-chats sidebar — so that half is now driven
#     end-to-end through the UI instead of faked.
#   - The discover tree still can't come from a real scan in a hermetic test (no
#     real claude session files on the worker box), so its INPUT is still seeded
#     via `state.discovered` — but through the real server state object
#     (`s.h.state`), exactly the dict `scan_and_store!` writes — and every
#     ASSERTION is against the live browser DOM.
#   - Ends asserting `window.__errs` is empty (the harness installs that sink).

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn

@testset "folder→threads tree + active-chats sidebar" begin
    s = TK.dev_server(; agent = _msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)

        # ── A running chat so the active-chats sidebar has something to list ──
        pid = TK.new_chat(s; cwd = mktempdir(), title = "Project1")

        # The real worker's id (assigned at connect time) — the key
        # state.discovered is bucketed under.
        wid = lock(s.h.state.lock) do
            ks = collect(keys(s.h.state.workers[]))
            isempty(ks) ? "" : ks[1]
        end
        @test !isempty(wid)

        # ── 1. active-chats sidebar lists the running chat, with a ✕ ──────────
        @test TK.wait_for(s, "Project1 active-chat row present",
            "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=\\\"$pid\\\"]') !== null";
            timeout = 8) == true
        @test TK.eval_js(s,
            "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=\\\"$pid\\\"] .bt-side-close') !== null") == true

        # ── Seed the discover set, exactly as scan_and_store! would ───────────
        # One folder (/work/MyApp) with two sibling sessions, plus a second
        # folder (/work/Other) → two distinct `.bt-group` <details>.
        lock(s.h.state.lock) do
            s.h.state.discovered[][wid] = [
                Dict{String,Any}("session_id" => "aaaa1111", "path" => "/work/MyApp",
                                 "name" => "MyApp", "first_prompt" => "refactor the parser",
                                 "last_used" => 1.70e9, "kind" => "session", "running" => true),
                Dict{String,Any}("session_id" => "bbbb2222", "path" => "/work/MyApp",
                                 "name" => "MyApp", "first_prompt" => "add tests for IO",
                                 "last_used" => 1.69e9, "kind" => "session"),
                Dict{String,Any}("session_id" => "cccc3333", "path" => "/work/Other",
                                 "name" => "Other", "first_prompt" => "write the README",
                                 "last_used" => 1.68e9, "kind" => "session"),
            ]
        end
        notify(s.h.state.discovered)

        # Back to the dashboard so the worker card (which hosts the discover
        # panel) is on screen.
        TK.to_dashboard(s)

        # ── 2. folder→threads tree mounts (KeyedList renders) ─────────────────
        @test TK.wait_for(s, "two folder groups render",
            "document.querySelectorAll('.bt-group').length >= 2"; timeout = 10) == true

        # The discover panel is a default-collapsed <details>; open it so its
        # contents land in innerText for the text assertions below.
        TK.eval_js(s, "(() => { const d = document.querySelector('details.bt-discover-panel'); if (d) d.open = true; return true; })()")
        @test TK.wait_for(s, "folder name MyApp shown",
            "document.body.innerText.indexOf('MyApp') !== -1"; timeout = 5) == true

        # The row LEADS with the prompt (folder name is in the group header).
        @test TK.eval_js(s, """
            [...document.querySelectorAll('.bt-session-name-text')]
                .some(e => (e.textContent||'').indexOf('refactor the parser') !== -1)
        """) == true
        # "+ New thread" present per folder.
        @test TK.eval_js(s, "document.querySelector('.bt-new-thread') !== null") == true
        # Resume buttons present for discovered sessions (they carry session_ids).
        @test TK.eval_js(s, """
            [...document.querySelectorAll('.bt-session-row')]
                .some(r => (r.textContent||'').indexOf('Resume') !== -1)
        """) == true

        # ── 3. expand the MyApp folder → both sibling threads become visible ──
        TK.eval_js(s, """
            (() => {
                for (const g of document.querySelectorAll('details.bt-group')) {
                    if ((g.innerText||'').indexOf('MyApp') !== -1) g.open = true;
                }
                return true;
            })()
        """)
        @test TK.wait_for(s, "both sibling threads visible when expanded", """
            document.body.innerText.indexOf('refactor the parser') !== -1 &&
            document.body.innerText.indexOf('add tests for IO') !== -1
        """; timeout = 5) == true

        # ── 4. switch to the active chat, then close it ───────────────────────
        TK.click(s, ".bt-sidebar .bt-side-item[data-project-id=\"$pid\"]")
        @test TK.wait_for(s, "clicking the row opens the chat (input mounts)",
            "!!document.querySelector('.bt-text-input') || !!document.querySelector('.bt-chatpane')";
            timeout = 10) == true

        # Click its ✕ → chat stops, row disappears.
        TK.click(s, ".bt-sidebar .bt-side-item[data-project-id=\"$pid\"] .bt-side-close")
        @test TK.wait_for(s, "closing the chat removes its sidebar row",
            "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=\\\"$pid\\\"]') === null";
            timeout = 8) == true

        # The folder→threads tree must still be present after the close
        # (dashboard re-mounts; the seeded discover set re-renders).
        @test TK.wait_for(s, "folder tree still present after close",
            "document.querySelectorAll('.bt-group').length >= 2"; timeout = 8) == true

        TK.screenshot(s, joinpath(tempdir(), "bt-folder-threads-final.png"))

        # ── 5. no JS errors fired across the whole flow ───────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
