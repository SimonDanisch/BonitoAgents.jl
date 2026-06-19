# Resume / project-list re-render regression — migrated onto the TestKit harness
# (real dev_server, real worker subprocess, real ACP wire, real Electron browser;
# only the agent's behaviour is faked via the `agent=` callback).
#
# This is heavily a "NO JS errors" test. It guards the Key-N-not-found /
# null-Observable race the user hit when a second project landed: adding a
# project re-renders the project_list, which closes the OLD project_card
# subsession (it held `current_view` via an interpolated onclick). Without the
# Bonito root-session-counts-as-reference fix, the next sidebar click
# dereferenced a freed Observable → `Cannot read properties of null (reading
# 'notify')` / `Key N not found` console spam, and nav silently broke.
#
# What it checks (mirrors the legacy intent on the REAL UI):
#   1. Dashboard's Home sidebar entry renders.
#   2. After creating a project, its sidebar row appears in the DOM.
#   3. Creating a SECOND project (the re-render that fired the bug) keeps BOTH
#      sidebar rows present (the project_list re-render that closed the old
#      project_card subsession).
#   4. Clicking each project's sidebar row navigates (chat pane mounts), and
#      clicking Home returns to the dashboard.
#   5. ZERO `window.__errs` JS errors and zero Key-not-found / null-Observable
#      / global-cache-delete warnings across the whole resume flow — asserted
#      after EVERY navigation, not just at the end.
#
# MIGRATION NOTES vs the legacy raw-ElectronCall version:
#   - `state.projects[][id]=p; notify(...)` poking is replaced by REAL project
#     creation through `new_chat` (the dashboard "+ New project" flow), which is
#     exactly the re-render path that closed the subsession in the bug.
#   - DROPPED the legacy `.bt-card-name` per-project dashboard-card assertion:
#     that UI no longer exists. The current dashboard renders the WORKER as a
#     `.bt-card` and lists projects in a separate grouped/discovered section
#     that does NOT carry a per-project `.bt-card-name` for freshly created
#     chats (verified against the live DOM). The sidebar row IS the project's
#     primary nav surface and is exactly where the bug's null-deref click fired,
#     so the regression is fully covered by the sidebar-row + click-nav
#     assertions. Dashboard-return is asserted via the stable hero text.
#   - The legacy test scraped Chromium console-message + a hand-rolled
#     console.* patch for the bug patterns. TestKit already installs
#     `window.__errs` (uncaught errors + unhandled rejections). We additionally
#     install a console.warn/error sink (`window.__bt_warns`) so the
#     Key-not-found / null-Observable *warnings* (which aren't thrown) are still
#     caught — those were the exact bug signature.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn

# Console.warn/error sink for the bug-pattern warnings (these are logged, not
# thrown, so window.__errs alone wouldn't catch them).
const WARN_SINK_JS = """
(() => {
    if (window.__bt_warns) return true;
    window.__bt_warns = [];
    for (const lvl of ['warn', 'error', 'log']) {
        const orig = console[lvl];
        console[lvl] = function(...args) {
            try {
                window.__bt_warns.push(args.map(a =>
                    (typeof a === 'string' ? a : (() => { try { return JSON.stringify(a); }
                                                          catch(e){ return String(a); } })())).join(' '));
            } catch(e) {}
            return orig.apply(this, args);
        };
    }
    return true;
})()
"""

const BUG_PATTERNS = [
    r"Key \d+ not found",
    r"TrackingOnly: Key \d+ not found",
    r"Trying to delete object \d+, which is not in global session cache",
    r"Cannot read properties of null \(reading 'notify'\)",
]

# Returns (js_errs, bug_offenders) — both must be empty at every checkpoint.
function jserror_state(s)
    errs = TK.eval_js(s, "window.__errs || []")
    warns = TK.eval_js(s, "window.__bt_warns || []")
    warn_strs = warns isa AbstractVector ? String.(warns) : String[]
    offenders = String[]
    for w in warn_strs, pat in BUG_PATTERNS
        occursin(pat, w) && push!(offenders, w)
    end
    return errs, offenders
end

# The dashboard hero text — stable across UI revisions, present only on the
# dashboard view (not in a chat pane).
const DASH_VISIBLE = "(document.querySelector('.bt-view-dash') !== null) && " *
    "((document.querySelector('.bt-view-dash').innerText||'').indexOf('Multi-host orchestrator') !== -1)"

# Click the Home sidebar row directly (empty data-project-id) and gate on the
# dashboard actually rendering, rather than a fixed sleep.
function goto_dashboard(s)
    TK.eval_js(s, """(() => { const h = document.querySelector('.bt-side-item[data-project-id=""]');
        if (h) h.click(); return true; })()""")
    TK.wait_for(s, "dashboard view", DASH_VISIBLE; timeout = 10)
end

@testset "resume flow — project re-render, nav works, zero JS errors" begin
    s = TK.dev_server(; agent = _msg -> [text("ok"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        TK.eval_js(s, WARN_SINK_JS)

        # ── 1. Home sidebar entry renders ─────────────────────────────────────
        @test TK.wait_for(s, "Home sidebar entry",
            "document.querySelector('.bt-side-item[data-project-id=\\\"\\\"]') !== null"; timeout = 15) == true

        # ── 2. Create the first project (Alpha) — sidebar row + card appear ───
        pid_a = TK.new_chat(s; cwd = mktempdir(), title = "Alpha")
        @test TK.wait_for(s, "Alpha sidebar row",
            "document.querySelector('.bt-side-item[data-project-id=\\\"$pid_a\\\"]') !== null"; timeout = 8) == true

        # ── 3. Create a SECOND project (Beta) — the re-render that fired the bug
        pid_b = TK.new_chat(s; cwd = mktempdir(), title = "Beta")
        @test TK.wait_for(s, "Beta sidebar row",
            "document.querySelector('.bt-side-item[data-project-id=\\\"$pid_b\\\"]') !== null"; timeout = 8) == true
        # Alpha's row must still be present after the project_list re-render
        # (the re-render that closed the old project_card subsession in the bug).
        @test TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\\\"$pid_a\\\"]') !== null") == true

        # Returning to the dashboard must render cleanly after the re-render.
        @test goto_dashboard(s) == true
        # Both project rows are still present in the sidebar from the dashboard.
        @test TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\\\"$pid_a\\\"]') !== null") == true
        @test TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\\\"$pid_b\\\"]') !== null") == true

        # Checkpoint: no JS errors / bug-pattern warnings so far.
        errs0, off0 = jserror_state(s)
        @test isempty(errs0)
        @test isempty(off0)

        # ── 4. Click-nav exercises current_view swaps (where the bug crashed) ─
        # Alpha → chat pane mounts.
        TK.click(s, ".bt-side-item[data-project-id=\"$pid_a\"]")
        @test TK.wait_for(s, "Alpha chat pane",
            "!!document.querySelector('.bt-chatpane') || !!document.querySelector('.bt-text-input')"; timeout = 15) == true
        errs_a, off_a = jserror_state(s)
        @test isempty(errs_a)
        @test isempty(off_a)

        # Beta → chat pane mounts (this is the click that dereferenced null in
        # the buggy build after the second project's card subsession freed
        # current_view).
        TK.click(s, ".bt-side-item[data-project-id=\"$pid_b\"]")
        @test TK.wait_for(s, "Beta chat pane",
            "!!document.querySelector('.bt-chatpane') || !!document.querySelector('.bt-text-input')"; timeout = 15) == true
        errs_b, off_b = jserror_state(s)
        @test isempty(errs_b)
        @test isempty(off_b)

        # Home → dashboard returns.
        @test goto_dashboard(s) == true
        errs_h, off_h = jserror_state(s)
        @test isempty(errs_h)
        @test isempty(off_h)

        # Back to Alpha once more — full cycle, still clean.
        TK.click(s, ".bt-side-item[data-project-id=\"$pid_a\"]")
        @test TK.wait_for(s, "Alpha chat pane again",
            "!!document.querySelector('.bt-chatpane') || !!document.querySelector('.bt-text-input')"; timeout = 15) == true

        TK.screenshot(s, joinpath(tempdir(), "bt-resume-no-jserrors-final.png"))

        # ── 5. Final assertion: zero JS errors / bug-pattern warnings ─────────
        errs, offenders = jserror_state(s)
        @test isempty(errs)
        if !isempty(offenders)
            for o in first(offenders, min(10, length(offenders)))
                @info "BUG-PATTERN OFFENDER" o
            end
        end
        @test isempty(offenders)
    finally
        close(s)
    end
end
