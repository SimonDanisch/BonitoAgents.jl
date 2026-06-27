# Black-box port of the legacy electron/test_resume_no_jserrors.jl regression.
#
# The original sin: clicking "Resume" on a discovered session re-rendered the
# project list, which closed the OLD project_card subsession (it held
# `current_view` via an interpolated onclick). The freed Observable then fired
# the Bonito "Key N not found" / "TrackingOnly" / "delete object N, not in
# global session cache" / "Cannot read properties of null (reading 'notify')"
# storm on resume — a real shipped regression from Observable timing.
#
# This pins the INVARIANT black-box on a real dev_server: seed a discovered,
# resumable session (exactly what a worker's ~/.claude scan surfaces), clear the
# JS error sink, click Resume, let the chat + sidebar + dashboard settle, then
# assert ZERO JS errors AND zero of the legacy bug-pattern console strings.
#
# ISOLATED (own dev_server, not the shared soak server): resume/discovery mutate
# worker session state, and the assertion is a clean-render invariant that
# shared-server neighbor noise would muddy.
@testitem "e2e:resume_no_jserrors" tags = [:e2e] begin
    using Test
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    import .TestKit
    const TK = TestKit

    # (TestKit now points the mock — `julia -m MockACP` — at the test env via
    # BT_MOCK_PROJECT itself; no per-test override needed.)

    # Console strings the buggy resume path printed; their ABSENCE is the
    # core assertion (alongside an empty window.__errs sink).
    const BUG_PATTERNS = [
        r"Key \d+ not found",
        r"TrackingOnly: Key \d+ not found",
        r"Trying to delete object \d+, which is not in global session cache",
        r"Cannot read properties of null \(reading 'notify'\)",
    ]

    s = TK.dev_server(; agent = msg -> [
        TK.text("Resumed our earlier conversation."),
        TK.end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 880)
        state = s.h.state
        wid   = first(keys(state.workers[]))
        cwd   = mktempdir(; prefix = "bt-resume-nojs-")
        sid   = "sess-resume-nojs-1"

        # Seed a discovered, resumable session for this worker (what a ~/.claude
        # scan surfaces). A non-empty `session_id` makes the row a "Resume".
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

        # The discovered Resume row appears; expand the worker's "projects (N)"
        # <details> so the row is visible/clickable.
        TK.wait_for(s, "discover row present",
            """document.querySelector('[data-bt-session-id="$sid"]') !== null"""; timeout = 10)
        TK.eval_js(s, "document.querySelectorAll('details').forEach(d=>d.open=true); true")
        btn_label = TK.eval_js(s, """(() => {
            const b = document.querySelector('[data-bt-session-id="$sid"]');
            return b ? b.textContent.trim() : "NONE";
        })()""")
        @test occursin("Resume", btn_label)

        # Arm the assertion: clear the JS error sink (window.__errs) right
        # BEFORE the resume so anything captured is attributable to resume.
        TK.clear_js_errors(s)

        # ── Click Resume → the project_list re-renders + the chat mounts ──────
        TK.eval_js(s, """(() => {
            const b = document.querySelector('[data-bt-session-id="$sid"]');
            if (b) b.click();
        })()""")
        # Loading curtain shows, then the chat mounts (input box present).
        @test TK.wait_for(s, "chat loading or mounted",
            """document.querySelector('.bt-loading, .bt-loading-wrap, .bt-text-input') !== null""";
            timeout = 25)
        @test TK.wait_for(s, "chat input mounted",
            "document.querySelector('.bt-text-input') !== null"; timeout = 25)

        # ── Bounce back to the dashboard so the SIDEBAR + project cards re-render
        #    (the re-render that historically tripped the freed-Observable storm).
        TK.to_dashboard(s)
        TK.wait_for(s, "back on dashboard",
            "document.querySelector('.bt-worker-cell, .bt-card') !== null"; timeout = 10)
        TK.eval_js(s, "document.querySelectorAll('details').forEach(d=>d.open=true); true")

        # Re-open the resumed chat from the sidebar — another current_view flip,
        # the exact path the buggy onclick dereferenced a freed Observable on.
        TK.wait_for(s, "resumed chat in sidebar",
            "document.querySelector('.bt-side-item[data-project-id]') !== null"; timeout = 10)
        TK.eval_js(s, """(() => {
            const items = [...document.querySelectorAll('.bt-side-item')]
                .filter(e => (e.getAttribute('data-project-id') || '') !== '');
            if (items[0]) items[0].click();
        })()""")
        @test TK.wait_for(s, "chat re-opened",
            "document.querySelector('.bt-text-input') !== null"; timeout = 15)

        # Let everything settle so any deferred Observable teardown fires.
        sleep(1.0)

        # ── INVARIANT 1: the error sink is empty (window.onerror + rejections) ─
        errs = TK.js_errors(s)
        @test isempty(errs)
        if !isempty(errs)
            @info "resume_no_jserrors: JS errors captured" errs
        end

        # ── INVARIANT 2: none of the legacy bug-pattern console strings fired ──
        # `__errs` carries `message`; scan it for the resume-specific patterns so
        # a "Key N not found" / null-Observable regression fails LOUD even if it
        # somehow didn't reach window.onerror.
        msgs = String[]
        for e in errs
            e isa AbstractDict || continue
            m = get(e, "message", get(e, "msg", ""))
            m === nothing || push!(msgs, String(m))
        end
        offenders = String[]
        for m in msgs, pat in BUG_PATTERNS
            occursin(pat, m) && push!(offenders, m)
        end
        @test isempty(offenders)
        if !isempty(offenders)
            for o in first(offenders, min(10, length(offenders)))
                @info "resume_no_jserrors OFFENDER" o
            end
        end
    finally
        close(s)
    end
end
