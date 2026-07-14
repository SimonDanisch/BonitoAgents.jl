# Black-box port of the legacy electron `test_layout_fixes.jl` regression suite.
#
# The legacy file mixed responsive-layout asserts (now covered by
# dashboard_layout_test.jl + chat_features_test.jl's "responsive / mobile
# layout" section) with three layout *behaviour* regressions that nothing else
# guards. This testitem ports exactly those three, BLACK-BOX, on the shared real
# `dev_server` — no server-state introspection, only rendered DOM:
#
#   1. The dashboard is its OWN scroll container (`.bt-dash`, overflow-y:auto,
#      min-height:0). Pre-fix `.bt-main` clipped overflow and `.bt-dash` had a
#      `min-height: 100vh`, so a long worker/project list overflowed the
#      viewport with nowhere to scroll: `scrollTop` couldn't advance past 0.
#
#   2. The `.bt-busy` indicator transitions its height in/out (0 ⇄ 28px over
#      150ms, via the `bt-busy-active` class) while a turn streams, instead of
#      jumping. We hold a turn open with `delay` so the indicator stays active,
#      assert it shows at ~28px, then clears back to 0 once the turn ends.
#
#   3. The chat-spinner remount race: the busy dots are driven by the shared
#      `busy_active` Observable, server-rendered into the `bt-busy-active` class
#      (chat.jl: `busy_class = map(b -> ...)`). Pre-fix the spinner was driven
#      only by transient `busy_start`/`busy_end` comm events, so a chat pane that
#      RE-MOUNTED mid-prompt (navigate away + back) never saw the original start
#      event and the dots stayed hidden until `busy_end`. Post-fix the remount
#      re-renders the class from the live observable, so the spinner is active
#      again the moment the pane comes back — and `onSessionReset` doesn't leave
#      it stuck. We reproduce by sending a slow (delayed) turn, navigating Home
#      and back while it's in flight, and asserting the spinner is still active
#      after remount with no duplicate `.bt-busy` element, then clears on finish.
@testitem "e2e:layout_fixes" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    const TK = TestKit
    s = SharedServer.server()

    using Test

    # Make sure we start from the dashboard at a normal viewport.
    TK.to_dashboard(s)
    TK.set_window_size(s, 1280, 800)
    TK.clear_js_errors(s)

    @testset "dashboard is its own scroll container" begin
        # A short, narrow viewport: whatever the shared server has accumulated
        # (it soaks many chats → many sidebar entries + dashboard sections)
        # comfortably exceeds 600px of dashboard content. Even an empty
        # dashboard's header + stats + two section headers + the "+ New" forms
        # overflow 600px once the worker/projects cards render, but to be robust
        # we only assert the scroll *mechanism* is live, not an exact height.
        TK.set_window_size(s, 480, 600)
        @test TK.wait_for(s, "dashboard mounted",
            "!!document.querySelector('.bt-dash')"; timeout = 10) == true
        sleep(0.4)

        scroll_info = TK.eval_js(s, """
            (() => {
                const d = document.querySelector('.bt-dash');
                if (!d) return null;
                d.scrollTop = 200;          // try to scroll the dashboard
                return { scrollHeight: d.scrollHeight,
                         clientHeight: d.clientHeight,
                         scrollTop:    d.scrollTop };
            })()
        """)
        @test scroll_info !== nothing
        # `.bt-dash` is the scroll container: its content exceeds its own box.
        @test scroll_info["scrollHeight"] > scroll_info["clientHeight"] + 20
        # Pre-fix bug: `.bt-main` had `overflow:hidden` and `.bt-dash` had a
        # `min-height` that defeated the internal scroll, so `scrollTop` stayed
        # pinned at 0. Post-fix it advances toward the 200 we requested (clamped
        # to scrollHeight-clientHeight, but well past 0).
        @test scroll_info["scrollTop"] >= 100

        # And `.bt-main` still clips its own overflow (that's WHY `.bt-dash`
        # must scroll itself) — the property the fix relies on.
        @test TK.eval_js(s, """
            (() => {
                const m = document.querySelector('.bt-main');
                if (!m) return null;
                return getComputedStyle(m).overflow;
            })()
        """) == "hidden"

        TK.set_window_size(s, 1280, 800)
    end

    @testset ".bt-busy height transitions in/out while a turn streams" begin
        # Hold the turn open for ~2s so the busy indicator stays active long
        # enough to assert its expanded height, then auto-ends. `delay` sleeps
        # in the mock WITHOUT ending the turn, so `busy_active` stays true.
        s.agent_fn[] = prompt -> [TK.text("on it…"), TK.delay(2000),
                                   TK.text("done"), TK.end_turn()]

        TK.new_chat(s)
        # `.bt-busy` exists (collapsed) before any turn — verify its resting
        # height is 0 so the transition is a real in/out, not a static box.
        @test TK.wait_for(s, "busy element present",
            "!!document.querySelector('.bt-busy')"; timeout = 15) == true
        rest_h = TK.eval_js(s,
            "Math.round(document.querySelector('.bt-busy').getBoundingClientRect().height)")
        @test rest_h <= 1

        TK.send_message(s, "are you there?")

        # The active class lands and the height transitions UP to ~28px.
        @test TK.wait_for(s, "busy active",
            "!!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 10) == true
        @test TK.wait_for(s, "busy height expanded",
            "Math.round(document.querySelector('.bt-busy').getBoundingClientRect().height) >= 24";
            timeout = 5) == true
        active_h = TK.eval_js(s,
            "Math.round(document.querySelector('.bt-busy').getBoundingClientRect().height)")
        # CSS sets content height 28px; the bounding box is ~36px once its padding
        # is included. Assert the expanded box height (well clear of the 0 resting
        # height), allowing for padding + layout rounding.
        @test 28 <= active_h <= 42

        # Pre-fix the row jumped; post-fix it transitions. We can't time the
        # 150ms tween reliably under rAF throttling on a hidden window, but we
        # CAN assert the indicator is the only thing whose height changed — the
        # surrounding message rows keep their position (no layout jump that
        # shoves the composer off-screen). The composer stays inside the shell.
        @test TK.eval_js(s, """
            (() => {
                const inp   = document.querySelector('.bt-input-area');
                const shell = document.querySelector('.bt-shell');
                if (!inp || !shell) return null;
                return inp.getBoundingClientRect().bottom
                       <= shell.getBoundingClientRect().bottom + 1;
            })()
        """) == true

        # Turn ends → class clears → height transitions back to 0.
        @test TK.wait_for(s, "busy cleared",
            "document.querySelector('.bt-busy.bt-busy-active') === null"; timeout = 10) == true
        @test TK.wait_for(s, "busy height collapsed",
            "Math.round(document.querySelector('.bt-busy').getBoundingClientRect().height) <= 1";
            timeout = 5) == true
    end

    @testset "chat spinner survives a mid-prompt remount (no stuck / no dup)" begin
        # A genuinely slow turn so we have a window to navigate away + back
        # while the prompt is still in flight on the shared ChatModel.
        s.agent_fn[] = prompt -> [TK.text("thinking…"), TK.delay(4000),
                                   TK.text("here you go"), TK.end_turn()]

        pid = TK.new_chat(s)
        TK.send_message(s, "slow one please")

        # Spinner activates on the live pane.
        @test TK.wait_for(s, "busy active after send",
            "!!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 10) == true

        # Navigate Home — the chat pane is HIDDEN (the KeyedList keeps it in the
        # DOM for fast switching, so the input still exists but is no longer
        # visible). Assert no VISIBLE input, not that it's gone from the DOM.
        # (Checking `=== null` would never succeed — it'd block the full timeout,
        # by which point the streaming turn below has already finished.)
        TK.to_dashboard(s)
        @test TK.wait_for(s, "chat input not visible on Home",
            "[...document.querySelectorAll('.bt-text-input')].every(e => e.offsetParent === null)";
            timeout = 8) == true
        sleep(0.3)

        # Back to the same chat — the pane re-mounts. Because the spinner class
        # is server-rendered from the live `busy_active` observable, the dots
        # must be active again immediately (the prompt is still streaming),
        # NOT stuck hidden until busy_end.
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "chat remounted",
            "!!document.querySelector('.bt-text-input')"; timeout = 10) == true
        @test TK.wait_for(s, "busy active after remount (still streaming)",
            "!!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 8) == true

        # No duplicate spinner: the remount must not leave a second `.bt-busy`
        # in the VISIBLE pane. (The pane-scope shim resolves these selectors
        # within the visible chat pane, so this counts the live pane's busy
        # elements — exactly one.)
        @test TK.eval_js(s, "document.querySelectorAll('.bt-busy').length") == 1

        # And once the scripted turn completes, the spinner clears (confirms
        # busy_active is toggled off and onSessionReset / the finally path
        # didn't leave it stuck active across the remount).
        @test TK.wait_for(s, "spinner clears once response finishes",
            "document.querySelector('.bt-busy.bt-busy-active') === null"; timeout = 12) == true
    end

    @testset "composer textarea spans the full controls column (yolo strip included)" begin
        # Regression: `.bt-text-input` had min-height 40px — the send/stop pair's
        # height only — while the controls column beside it is ~64px (Yolo bar +
        # gap + buttons). With the row bottom-aligned, the Yolo strip's height
        # was dead space above the textarea. The fix pins the textarea's
        # min-height to the full column height; the auto-resize JS still grows
        # it to the 120px cap and shrinks back to the floor, never below.
        geo = TK.eval_js(s, """
            (() => {
                const p  = [...document.querySelectorAll('.bt-chatpane')].find(x => x.offsetParent !== null);
                if (!p) return null;
                const ta = p.querySelector('.bt-text-input');
                const c  = p.querySelector('.bt-input-controls');
                const tb = ta.getBoundingClientRect(), cb = c.getBoundingClientRect();
                return { taH: Math.round(tb.height), ctrH: Math.round(cb.height),
                         topDelta: Math.round(Math.abs(tb.top - cb.top)) };
            })()""")
        @test geo !== nothing
        @test geo["taH"] >= geo["ctrH"] - 2     # textarea covers the whole column…
        @test geo["topDelta"] <= 1              # …from the very top (no dead strip)

        # Auto-resize still works around the new floor: grow toward the cap,
        # then shrink BACK to the column height (not below) when cleared.
        TK.set_input(s, ".bt-text-input", join(["line $(i)" for i in 1:8], "\n"))
        sleep(0.4)
        grown = TK.eval_js(s, """
            (() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null);
                     return Math.round(p.querySelector('.bt-text-input').getBoundingClientRect().height); })()""")
        @test grown > geo["taH"]                # grew past the floor
        @test grown <= 122                      # …capped at max-height
        TK.set_input(s, ".bt-text-input", "")
        sleep(0.4)
        cleared = TK.eval_js(s, """
            (() => { const p=[...document.querySelectorAll('.bt-chatpane')].find(x=>x.offsetParent!==null);
                     return Math.round(p.querySelector('.bt-text-input').getBoundingClientRect().height); })()""")
        @test abs(cleared - geo["ctrH"]) <= 2   # settles back to the column height
    end

    # Restore the default echo agent + normal viewport for the next soak suite.
    s.agent_fn[] = prompt -> [TK.text("echo: $(prompt)"), TK.end_turn()]
    TK.set_window_size(s, 1280, 820)

    @test isempty(TK.js_errors(s))
end
