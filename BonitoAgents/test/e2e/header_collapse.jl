# Narrow-pane header collapse: below the ~660px container breakpoint the chat
# header hides the action cluster (provider select / Sync / Compact / Restart),
# the env path line and the lens search bar behind ONE ⋯ toggle. Checking it
# expands them all IN FLOW as a full-width stack directly under the toggle,
# and the glyph flips ⋯ → ✕ so the open toggle reads as the close button of
# the panel it sits on top of. Everything is pure CSS (checkbox-in-label +
# container query), so the breakpoint follows the PANE width, not the window.
#
# Contract asserted (what the user sees):
#   * wide pane: no toggle, actions + env + search visible as usual,
#   * narrow pane: exactly ONE toggle (the 🔍 twin was removed on purpose —
#     "collapse them all together, the ⋯ menu should be enough"), everything
#     else hidden,
#   * check: ✕ glyph, actions/env/search all visible; the panel is in flow
#     below the toggle and its controls span the full row (the Sync button's
#     wide-strip max-width cap must not apply; the provider select centers),
#   * uncheck: back to the collapsed row,
#   * the checked state must never leak into the wide layout: widening the
#     pane with the menu open shows the plain wide header again.
#
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# All queries scope to the VISIBLE chat pane — the shared soak server keeps
# background panes mounted, so document-wide selectors can read a stale pane.
const PANE = "[...document.querySelectorAll('.bt-chatpane')].find(x => x.offsetParent !== null)"

visible(s, sel) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const el = p && p.querySelector($(repr(sel)));
    return el ? el.offsetParent !== null : false; })()""") === true

toggle_count(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    return p ? p.querySelectorAll('.bt-header-collapse-toggle').length : -1; })()""")

# Which glyph the toggle currently renders ("⋯" closed, "✕" open) — the swap is
# display-based, so read computed styles, not textContent.
glyph(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const t = p && p.querySelector('.bt-header-more-toggle');
    if (!t) return 'no-toggle';
    const d = el => getComputedStyle(el).display;
    return (d(t.querySelector('.bt-toggle-closed')) !== 'none' ? '⋯' : '')
         + (d(t.querySelector('.bt-toggle-open'))   !== 'none' ? '✕' : ''); })()""")

click_toggle(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const t = p && p.querySelector('.bt-header-more-toggle');
    if (!t) return 'no-toggle';
    t.click(); return 'clicked'; })()""")

# Expanded-panel geometry: the actions stack sits BELOW the toggle and spans
# (nearly) the full header row; the Sync button stretches with it and the
# provider select centers its label.
panel_geometry_ok(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    if (!p) return 'no-pane';
    const acts = p.querySelector('.bt-header-actions');
    const tog  = p.querySelector('.bt-header-more-toggle');
    const row  = p.querySelector('.bt-header-row');
    const sync = p.querySelector('.bt-header-sync');
    const sel  = p.querySelector('.bt-header-provider-select');
    if (!acts || !tog || !row || !sync) return 'missing-el';
    const a = acts.getBoundingClientRect(), t = tog.getBoundingClientRect(),
          r = row.getBoundingClientRect(),  y = sync.getBoundingClientRect();
    if (a.top < t.bottom - 1) return 'panel-not-below-toggle';
    if (a.width < 0.9 * r.width) return 'panel-not-full-width';
    if (y.width < 0.9 * a.width) return 'sync-not-stretched';
    if (sel && getComputedStyle(sel).textAlign !== 'center') return 'select-not-centered';
    // No placeholder children: an empty span (the old xsync placeholder) or a
    // rendered-but-empty meta div costs a flex-gap slot and doubles a row gap.
    if (acts.querySelector(':scope > span:empty')) return 'phantom-empty-child';
    const meta = p.querySelector('.bt-header-meta');
    if (meta && meta.childElementCount === 0 && getComputedStyle(meta).display !== 'none')
        return 'empty-meta-visible';
    // Category prefixes come back in the stacked menu (a bare "default" is
    // ambiguous there) — only present when the session reports config pills.
    const cat = p.querySelector('.bt-header-meta-cat');
    if (cat && getComputedStyle(cat).display === 'none') return 'cat-hidden-in-panel';
    return 'ok'; })()""")

# Resize + let the container query re-evaluate; poll on the toggle's visibility
# flipping rather than a blind sleep.
function resize_and_wait(s, w, h, toggle_visible::Bool)
    TK.set_window_size(s, w, h)
    TK.wait_for(s, "collapse toggle $(toggle_visible ? "shown" : "hidden") at $(w)px",
        """(() => {
            const p = $(PANE);
            const t = p && p.querySelector('.bt-header-more-toggle');
            return t ? (t.offsetParent !== null) === $(toggle_visible) : false; })()""";
        timeout = 5)
end

function run_suite(server)
    s = server
    @testset "narrow-pane header collapse (⋯ menu)" begin
        TK.new_chat(s)
        try
            # Wide pane: plain header, no toggle.
            resize_and_wait(s, 1280, 820, false)
            @test visible(s, ".bt-header-actions")
            @test visible(s, ".bt-lens-bar")
            @test visible(s, ".bt-header-env")

            # Narrow pane: ONE toggle showing ⋯, everything else collapsed.
            resize_and_wait(s, 700, 820, true)
            @test toggle_count(s) == 1
            @test glyph(s) == "⋯"
            @test !visible(s, ".bt-header-actions")
            @test !visible(s, ".bt-lens-bar")
            @test !visible(s, ".bt-header-env")

            # Expand: ✕ glyph, everything back, stacked full-width below the ✕.
            @test click_toggle(s) == "clicked"
            TK.wait_for(s, "collapse menu expanded",
                """(() => {
                    const p = $(PANE);
                    const a = p && p.querySelector('.bt-header-actions');
                    return a ? a.offsetParent !== null : false; })()"""; timeout = 5)
            @test glyph(s) == "✕"
            @test visible(s, ".bt-lens-bar")
            @test visible(s, ".bt-header-env")
            @test visible(s, ".bt-header-sync")
            @test visible(s, ".bt-header-restart")
            @test panel_geometry_ok(s) == "ok"

            # Collapse again: back to the bare row.
            @test click_toggle(s) == "clicked"
            TK.wait_for(s, "collapse menu closed",
                """(() => {
                    const p = $(PANE);
                    const a = p && p.querySelector('.bt-header-actions');
                    return a ? a.offsetParent === null : false; })()"""; timeout = 5)
            @test glyph(s) == "⋯"
            @test !visible(s, ".bt-lens-bar")

            # A checked toggle must not leak into the wide layout: reopen the
            # menu, widen the pane — the plain wide header wins again.
            @test click_toggle(s) == "clicked"
            resize_and_wait(s, 1280, 820, false)
            @test visible(s, ".bt-header-actions")
            @test visible(s, ".bt-lens-bar")
            @test visible(s, ".bt-header-env")
        finally
            TK.set_window_size(s, 1280, 820)
        end
    end
end
