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

# The action cluster must never spill past the header — `html,body` is
# `overflow:hidden`, so anything past the edge is CUT with no scrollbar to reach
# it (the Restart button lost its last letters at ~800px). The mock reports no
# usage figure and no config pills, so its cluster is ~440px and fits anywhere;
# a real chat carries "608.7k/1M · 61% · $8.15" plus model/permissions/effort
# pills for ~1124px. Seed equivalents into the REAL rendered header so the
# stylesheet meets production-width content — the thing under test is the CSS
# response to a wide cluster, not how the pills got there.
seed_wide_header(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const acts = p && p.querySelector('.bt-header-actions');
    if (!acts) return 'no-actions';
    if (acts.querySelector('.probe-seed')) return 'already';
    for (const t of ['effort:Xhigh', 'permissions:bypass permissions',
                     'model:Opus 5 with 1M context', '608.7k/1M · 61% · \$8.15']) {
        const d = document.createElement('div');
        d.className = 'bt-header-meta-item probe-seed';
        d.textContent = t;
        acts.insertBefore(d, acts.firstChild);
    }
    return 'seeded'; })()""")

unseed_header(s) = TK.eval_js(s,
    "(() => { document.querySelectorAll('.probe-seed').forEach(n => n.remove()); return 'ok'; })()")

# How far the cluster spills past the header's right edge (≤0 means contained).
spill(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const acts = p && p.querySelector('.bt-header-actions');
    const hdr  = p && p.querySelector('.bt-header');
    if (!acts || !hdr) return 9999;
    return Math.round(acts.getBoundingClientRect().right - hdr.getBoundingClientRect().right);
    })()""")

header_width(s) = TK.eval_js(s, """(() => {
    const p = $(PANE); const h = p && p.querySelector('.bt-header');
    return h ? Math.round(h.getBoundingClientRect().width) : -1; })()""")

# Resize and wait for the layout to actually follow, so a measurement can't read
# the pre-resize geometry. Each width in the sweep is distinct, so "the header
# width changed" is a sound settle signal.
function resize_settle(s, w, h)
    prev = header_width(s)
    TK.set_window_size(s, w, h)
    TK.wait_for(s, "header re-laid out at $(w)px",
        """(() => {
            const p = $(PANE); const el = p && p.querySelector('.bt-header');
            return el ? Math.round(el.getBoundingClientRect().width) !== $(prev) : false;
        })()"""; timeout = 5)
end

# Is the Restart button whole and inside the header?
restart_intact(s) = TK.eval_js(s, """(() => {
    const p = $(PANE);
    const b = p && p.querySelector('.bt-header-restart');
    const hdr = p && p.querySelector('.bt-header');
    if (!b || !hdr) return 'missing';
    const r = b.getBoundingClientRect(), h = hdr.getBoundingClientRect();
    if (r.right > h.right + 1) return 'clipped-right';
    if (r.width < 40) return 'squashed';
    return 'ok'; })()""")

function run_suite(server)
    s = server
    @testset "wide action cluster wraps instead of clipping" begin
        TK.new_chat(s)
        try
            @test seed_wide_header(s) == "seeded"
            # Every width from "everything fits" down to the last one where the
            # cluster is still SHOWN — a 900px window is a 700px pane, just
            # above the 660px collapse breakpoint. (Below it the cluster is
            # hidden behind ⋯ and has no geometry to measure; the next testset
            # covers that regime.) The regression clipped by 61px at 1280 and
            # 440px at 900, losing the Restart button entirely.
            for w in (1400, 1280, 1100, 1000, 900)
                resize_settle(s, w, 820)
                @test spill(s) <= 0
                @test restart_intact(s) == "ok"
            end
        finally
            unseed_header(s)
            TK.set_window_size(s, 1280, 820)
        end
    end

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
