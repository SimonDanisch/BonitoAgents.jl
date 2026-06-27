# End-to-end test for the discover → Resume → chat flow, via TestKit (real
# dev_server + real worker + real ACP wire, only the agent binary is the mock).
#
# What it pins down (the user-visible flow + the "stuck Resuming…" fix):
#   1. A discovered (resumable) session on the worker renders a project group
#      with a "Resume" button in the dashboard (opening projects + the button).
#   2. Clicking Resume opens the chat — the loading spinner/curtain appears and
#      the chat mounts (session/load resume over real ACP to the mock).
#   3. The resumed session is removed from the discover list (a project with a
#      matching resume_session_id now exists), so its row no longer lingers —
#      previously it stuck around with an optimistic "Resuming…" label forever
#      because the KeyedList row (keyed by session id) never re-rendered.

using Test, JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit
const TK = TestKit

# (TestKit now points the mock — `julia -m MockACP` — at the test env via
# BT_MOCK_PROJECT itself; no per-test override needed.)

const RESUME_SHOT_DIR = joinpath(tempdir(), "bt-resume-e2e")
mkpath(RESUME_SHOT_DIR)

@testset "discover → Resume → chat (and the resumed row disappears)" begin
    s = TK.dev_server(; agent = msg -> [
        TK.text("Resumed our earlier conversation."),
        TK.end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 880)
        state = s.h.state
        wid   = first(keys(state.workers[]))
        cwd   = mktempdir(; prefix = "bt-resume-")
        sid   = "sess-resume-e2e-1"

        # Seed a discovered, resumable session for this worker (what a worker
        # scan of ~/.claude would surface). A non-empty `session_id` makes the
        # row's button a "Resume" (vs "Import" for session-less folders).
        lock(state.lock) do
            state.discovered[][wid] = [Dict{String,Any}(
                "path"         => cwd,
                "name"         => basename(cwd),
                "session_id"   => sid,
                "kind"         => "session",
                "last_used"    => time(),
                "first_prompt" => "the earlier conversation",
            )]
        end
        notify(state.discovered)

        # ── 1. Opening projects: the discovered session shows a Resume button ──
        TK.wait_for(s, "discover row present",
            """document.querySelector('[data-bt-session-id="$sid"]') !== null"""; timeout = 10)
        # Expand the worker's "projects (N)" <details> so the rows are visible.
        TK.eval_js(s, "document.querySelectorAll('details').forEach(d=>d.open=true); true")
        btn_label = TK.eval_js(s, """(() => {
            const b = document.querySelector('[data-bt-session-id="$sid"]');
            return b ? b.textContent.trim() : "NONE";
        })()""")
        @test occursin("Resume", btn_label)
        @test TK.eval_js(s, """document.querySelectorAll('[data-bt-session-id="$sid"]').length""") == 1

        # ── 2. Click Resume → chat opens (spinner/curtain, then mount) ─────────
        TK.eval_js(s, """(() => {
            const b = document.querySelector('[data-bt-session-id="$sid"]');
            if (b) b.click();
        })()""")
        # The loading curtain ("Opening …" / spinner) shows while the chat mounts.
        # TK.wait_for returns true on success (throws on timeout).
        @test TK.wait_for(s, "chat loading or mounted",
            """document.querySelector('.bt-loading, .bt-loading-wrap, .bt-text-input') !== null""";
            timeout = 25)
        # And it finishes mounting (input box present).
        @test TK.wait_for(s, "chat input mounted",
            "document.querySelector('.bt-text-input') !== null"; timeout = 25)
        TK.screenshot(s, joinpath(RESUME_SHOT_DIR, "resumed-chat.png"))

        # A project with the resumed session id now exists (the resume bound it).
        @test lock(state.lock) do
            any(p -> p.resume_session_id == sid, values(state.projects[]))
        end

        # ── 3. The resumed session is gone from the discover list (the fix) ────
        TK.eval_js(s, """(() => {
            const h = [...document.querySelectorAll('.bt-side-item')].find(e => /Home/i.test(e.innerText));
            if (h) h.click();
        })()""")
        TK.wait_for(s, "back on dashboard",
            "document.querySelector('.bt-worker-cell, .bt-card') !== null"; timeout = 10)
        TK.eval_js(s, "document.querySelectorAll('details').forEach(d=>d.open=true); true")
        sleep(0.5)
        @test TK.eval_js(s, """document.querySelectorAll('[data-bt-session-id="$sid"]').length""") == 0
    finally
        close(s)
    end
end
