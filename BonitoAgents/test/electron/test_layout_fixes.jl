# Layout-fix regression tests, migrated onto the TestKit harness (real
# dev_server, real worker subprocess, real ACP wire, real Electron browser; only
# the agent's behaviour is faked, via the `agent=` callback).
#
# Guards the dvh / .bt-dash scroll / .bt-session-info min-width:0 / mobile
# button + section / chat-input-visible / chat-spinner-remount fixes.
#
# MIGRATION NOTES vs the legacy MockTransport version:
#   - The legacy test fabricated a 10-worker / 6-project ServerState plus
#     mounted isolated components through `display(ctx.disp, probe_app)` to
#     check `.bt-session-row`, `.bt-discover-header` and `.bt-pill-active` CSS.
#     TestKit's Electron context exposes no Bonito display handle, so the
#     probe-app technique is gone. Instead every section asserts against the
#     REAL dashboard DOM: the real worker already advertises 80+ discovered
#     session rows and open Discover panels, so the same layout invariants
#     (long-name truncation, button-inside-row, discover-header stacking) are
#     exercised on production markup with no fakes.
#   - DROPPED: "session-row active badge doesn't overlap Resume" — it needs a
#     RUNNING session row (`.bt-pill-active`), which only appears for a live
#     agent process. The live dashboard here advertises none (verified:
#     `document.querySelectorAll('.bt-pill-active').length === 0`), and the
#     legacy version only saw one because it hand-fabricated a SessionRow with
#     `active: true`. We do NOT fake it; the truncation + button-inside-row
#     invariants it shared are already covered by the real session-row section.
#   - DROPPED the standalone `.bt-session-path` truncation probe: the current
#     markup has no `.bt-session-path` element; the path/name now lives in
#     `.bt-session-name-text`, whose ellipsis + button-inside-row we assert on
#     the real rows.
#   - Spinner section uses a REAL slow agent: the callback emits a 1.5s `delay`
#     before its first chunk, so the prompt is genuinely in flight while the test
#     navigates Home → back and re-checks the spinner. BEHAVIOUR CHANGE since the
#     legacy test: navigating Home no longer tears the chat subsession down — the
#     chat pane is now KEPT ALIVE in the DOM and merely hidden (verified:
#     `.bt-text-input` stays present, `offsetParent === null`). So we assert
#     visibility (offsetParent) flips on navigation instead of presence, and that
#     the busy spinner survives the round-trip and clears when the turn ends —
#     the same user-facing guarantee (the spinner doesn't go dark mid-prompt when
#     you leave and come back).

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, delay, end_turn

@testset "layout fixes — dashboard scroll, mobile cards/buttons, chat input, spinner remount" begin
    # Slow agent: 1.5s before the first chunk so the spinner-remount section has
    # a window to navigate away while the prompt is still streaming.
    s = TK.dev_server(; agent = msg -> [delay(1500), text("thinking… "), delay(800),
                                        text("here is the answer."), end_turn()])
    try
        TK.open_browser(s; width = 480, height = 600)
        # The dashboard needs a moment to mount its worker card + discovered
        # sessions; TestKit's open_browser already sleeps, plus the worker WS.
        TK.wait_for(s, "dashboard mounted", "!!document.querySelector('.bt-dash')"; timeout = 15)
        TK.wait_for(s, "session rows discovered",
            "document.querySelectorAll('.bt-session-row').length > 0"; timeout = 20)

        # ── Dashboard is its own scroll container ─────────────────────────────
        # Narrow + short viewport — the worker card + discovered sessions exceed
        # the viewport, so .bt-dash must scroll. Pre-fix bug: `.bt-main` had
        # `overflow: hidden` and `.bt-dash` had `min-height: 100vh`, clipping the
        # overflow so scrollTop couldn't advance.
        TK.set_window_size(s, 480, 600); sleep(0.4)
        scroll_info = TK.eval_js(s, """(() => {
            const d = document.querySelector('.bt-dash');
            if (!d) return null;
            d.scrollTop = 200;
            return { scrollHeight: d.scrollHeight, clientHeight: d.clientHeight,
                     scrollTop: d.scrollTop }; })()""")
        @test scroll_info["scrollHeight"] > scroll_info["clientHeight"] + 50
        @test scroll_info["scrollTop"] >= 150

        # ── Card actions don't overflow on mobile ─────────────────────────────
        # ~390px mobile viewport. Pre-fix: `.bt-card-actions` had `margin-left:
        # auto` even on mobile so the cluster right-aligned and overflowed the
        # card. Post-fix it takes `width: 100%` and wraps cleanly.
        TK.set_window_size(s, 390, 800); sleep(0.4)
        overflow_info = TK.eval_js(s, """(() => {
            const card = document.querySelector('.bt-card');
            const acts = card && card.querySelector('.bt-card-actions');
            if (!card || !acts) return null;
            const cardR = card.getBoundingClientRect();
            const actsR = acts.getBoundingClientRect();
            return { card_right: cardR.right, acts_right: actsR.right }; })()""")
        @test overflow_info !== nothing
        @test overflow_info["acts_right"] <= overflow_info["card_right"] + 1

        # ── Buttons never wrap their own text ─────────────────────────────────
        # Pre-fix: `.bt-btn` was inline-flex without `white-space: nowrap`, so
        # "+ New project" wrapped onto two lines at narrow widths. Any visible
        # button with scrollHeight > clientHeight is wrapping vertically.
        TK.set_window_size(s, 360, 800); sleep(0.4)
        wraps = TK.eval_js(s, """(() => {
            const out = [];
            for (const b of document.querySelectorAll('.bt-btn')) {
                if (b.offsetParent === null) continue;
                if (b.scrollHeight > b.clientHeight + 1) out.push(b.innerText.trim().slice(0,30));
            }
            return out; })()""")
        @test isempty(wraps)

        # ── Section heading + form buttons stack cleanly ──────────────────────
        # The NEW PROJECT section header has h2 + "+ New project" + "+ From
        # GitHub"; at 390px they can't share a row. Post-fix the h2 takes its own
        # row (flex: 1 0 100%) and the buttons wrap below.
        TK.set_window_size(s, 390, 800); sleep(0.4)
        info = TK.eval_js(s, """(() => {
            const secs = [...document.querySelectorAll('.bt-section')];
            for (const sec of secs) {
                const h2 = sec.querySelector('h2');
                if (!h2 || !h2.innerText.toLowerCase().includes('new project')) continue;
                const btns = sec.querySelectorAll('.bt-btn');
                if (btns.length < 2) return null;
                const h2R = h2.getBoundingClientRect();
                const b1R = btns[0].getBoundingClientRect();
                const b2R = btns[1].getBoundingClientRect();
                return { h2_bottom: h2R.bottom, b1_top: b1R.top, b1_right: b1R.right,
                         b2_right: b2R.right, sec_right: sec.getBoundingClientRect().right };
            }
            return null; })()""")
        @test info !== nothing
        @test info["b1_top"] >= info["h2_bottom"] - 1            # h2 on its own row
        @test info["b1_right"] <= info["sec_right"] + 1          # buttons inside section
        @test info["b2_right"] <= info["sec_right"] + 1

        # ── Session-row info column constrains long names ─────────────────────
        # The real worker advertises 80+ discovered session rows; long names must
        # ellipsize (`.bt-session-name-text` overflow) and the Resume/Open button
        # must stay inside the row. Pre-fix bug: the text column had no
        # `min-width: 0`, so the monospace nowrap name grew the column and pushed
        # the button off the right edge.
        TK.eval_js(s, "document.querySelector('.bt-dash').scrollTop = 400"); sleep(0.3)
        row_info = TK.eval_js(s, """(() => {
            let any_trunc = false, btn_inside = true, probed = false;
            for (const row of document.querySelectorAll('.bt-session-row')) {
                const t = row.querySelector('.bt-session-name-text');
                const btn = row.querySelector('.bt-btn');
                if (!t || !btn) continue;
                probed = true;
                const rR = row.getBoundingClientRect(), bR = btn.getBoundingClientRect();
                if (bR.right > rR.right + 1) btn_inside = false;
                if (t.scrollWidth > t.clientWidth) any_trunc = true;
            }
            return { any_trunc, btn_inside, probed }; })()""")
        @test row_info["probed"] == true
        @test row_info["btn_inside"] == true
        @test row_info["any_trunc"] == true   # at least one long name ellipsizes

        # ── Discover panel header stacks (title above actions) on mobile ──────
        # The worker card's Discover panel header is "Claude Code sessions on
        # <worker>" + ↻ Rescan + close. At 390px all three on one row squashes
        # the actions; post-fix the mobile media query gives `.bt-discover-header`
        # `flex-direction: column` so the title takes its own row.
        disc = TK.eval_js(s, """(() => {
            const hdr = document.querySelector('.bt-discover-header');
            if (!hdr) return null;
            const ttl = hdr.querySelector('.bt-discover-title');
            const acts = hdr.querySelector('.bt-discover-actions');
            if (!ttl || !acts) return null;
            const tR = ttl.getBoundingClientRect();
            const aR = acts.getBoundingClientRect();
            const hR = hdr.getBoundingClientRect();
            return { title_bottom: tR.bottom, acts_top: aR.top, acts_right: aR.right,
                     hdr_right: hR.right }; })()""")
        @test disc !== nothing
        @test disc["acts_top"] >= disc["title_bottom"] - 4      # title row above actions
        @test disc["acts_right"] <= disc["hdr_right"] + 1       # actions inside panel

        # ── Chat input stays in viewport at small heights + header layout ─────
        TK.set_window_size(s, 1280, 800); sleep(0.3)
        pid = TK.new_chat(s; title = "LayoutFixTestProject")
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        sleep(0.5)

        TK.set_window_size(s, 420, 640); sleep(0.4)
        layout = TK.eval_js(s, """(() => {
            const inp = document.querySelector('.bt-input-area');
            const shell = document.querySelector('.bt-shell');
            if (!inp || !shell) return null;
            return { input_bottom: inp.getBoundingClientRect().bottom,
                     shell_height: shell.getBoundingClientRect().height,
                     inner_height: window.innerHeight }; })()""")
        @test layout !== nothing
        # `.bt-shell` follows the rendered viewport (100dvh, not 100vh).
        @test abs(layout["shell_height"] - layout["inner_height"]) < 4
        @test layout["input_bottom"] <= layout["inner_height"] + 1

        # Chat header: title gets meaningful width, Sync doesn't dominate, no
        # overlap. Pre-fix `.bt-header-sync` had `min-width: 260px`, covering the
        # title on phone widths.
        header = TK.eval_js(s, """(() => {
            const t = document.querySelector('.bt-header-title');
            const sy = document.querySelector('.bt-header-sync');
            if (!t || !sy) return null;
            const tR = t.getBoundingClientRect(), sR = sy.getBoundingClientRect();
            return { title_content_w: t.scrollWidth, sync_w: sR.width,
                     title_right: tR.right, sync_left: sR.left }; })()""")
        @test header !== nothing
        # The title's content has meaningful width (not crushed to ~0 by the Sync
        # cluster). We read scrollWidth, not the flex box's clamped boundingRect
        # width — the title column ellipsizes, so its rendered content extends
        # past its measured box.
        @test header["title_content_w"] >= 80                   # title not crushed
        @test header["sync_w"] <= 130                           # Sync doesn't dominate
        @test header["title_right"] <= header["sync_left"] + 1  # no overlap

        # ── Spinner survives navigate-away-and-back mid-prompt ────────────────
        # Send a prompt — the slow agent waits 1.5s before its first chunk, so we
        # have a window to leave the chat. The spinner must stay active across the
        # round-trip (it's driven off the shared ChatModel's busy state, not a
        # transient comm event that a re-mount would miss). With keep-alive the
        # chat pane is hidden (not torn down), so we gate on VISIBILITY flipping.
        TK.set_window_size(s, 1280, 800); sleep(0.3)
        chat_visible = "(() => { const c = document.querySelector('.bt-chatpane'); return !!c && c.offsetParent !== null; })()"
        TK.send_message(s, "are you there?")
        @test TK.wait_for(s, "busy spinner activates after send",
            "document.querySelector('.bt-busy.bt-busy-active') !== null"; timeout = 5)

        # Navigate Home → the chat pane hides (kept alive in the DOM).
        TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\"\"]').click()")
        @test TK.wait_for(s, "chat pane hidden on Home",
            "(() => { const c = document.querySelector('.bt-chatpane'); return !c || c.offsetParent === null; })()"; timeout = 5)
        sleep(0.2)
        # Back to the project — the chat pane shows again; the spinner must still
        # be active because the prompt is still in flight on the shared ChatModel.
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        @test TK.wait_for(s, "chat pane visible again", chat_visible; timeout = 10)
        @test TK.wait_for(s, "busy spinner active after return (still streaming)",
            "document.querySelector('.bt-busy.bt-busy-active') !== null"; timeout = 4)
        # Once the scripted response completes, the spinner clears — confirms
        # busy_active toggles off via the finally block in send_prompt_async!.
        @test TK.wait_for(s, "spinner clears once response finishes",
            "document.querySelector('.bt-busy.bt-busy-active') === null"; timeout = 10)

        TK.screenshot(s, joinpath(tempdir(), "bt-layout-fixes-final.png"))

        # ── No JS errors during the whole layout exercise ─────────────────────
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
