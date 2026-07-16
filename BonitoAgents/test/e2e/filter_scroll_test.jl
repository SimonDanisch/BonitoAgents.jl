# Toggling a message-TYPE filter (the `hiddenTypes` toolbar) while scrolled up in
# history must NOT move the view. Hiding/showing a type reflows the transcript
# (matching rows collapse to / expand from 0px) — a bulk above-viewport height
# change. `setKeyHidden` captures the top-visible SURVIVING row BEFORE the reflow
# and re-pins it after refresh; pre-fix the reflow jumped the reader several
# messages down (marker 9 -> 15 in the repro) because refresh's own anchor ran
# only AFTER the jump and faithfully preserved the wrong spot (#48).
#
# The invariant asserted is "the READING ROW keeps its screen offset": the
# marker that was top-visible at the toggle instant must sit at the same
# viewport offset afterwards. It is NOT "the top-visible marker number is
# unchanged" — when a to-be-hidden tool row straddles the viewport top edge,
# collapsing it necessarily slides the PREVIOUS marker's bottom down into the
# viewport, so the first-visible-marker identity can legitimately change while
# the view holds pixel-perfectly (observed: anchor held marker 9 at +30 exactly,
# yet marker 8's bottom landed at +30 and became the new "top" marker).
@testitem "e2e:filter_scroll" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer; s = S.server(); TK = S.TK

    function seed_agent(prompt)
        occursin("seed", lowercase(prompt)) || return [TK.text("echo")]
        evs = Any[]
        for i in 1:30
            push!(evs, TK.text("marker bubble number $(i) — a short line of prose"))
            push!(evs, TK.tool(kind = "read", title = "probe tool $(i)", id = "probe-$(i)"))
        end
        evs
    end
    s.agent_fn[] = seed_agent

    TK.new_chat(s; title = "FilterScroll")
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "seeded",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 5"; timeout = 30) == true
    @test TK.wait_for(s, "overflows",
        "(() => { const c=[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent); return !!c && c.scrollHeight > c.clientHeight + 800; })()"; timeout = 15) == true

    CH = "[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent).__bt_chat"
    # Top-visible MARKER number (a text bubble; skip the tool rows so a hidden
    # tool sitting at the very top isn't itself counted as a "jump"). The 4px
    # bottom-overhang tolerance keeps a row whose last couple of pixels hang
    # into the viewport from being counted as "the top row": an anchor-held
    # toggle can legitimately land ±1px, which used to flip the reported
    # marker to the neighbour above (off-by-one) even though the view held.
    MARKER = """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const st = c.scrollTop;
        const nodes = [...c.querySelectorAll('.bt-agent-msg')].filter(n=>n.offsetParent).sort((a,b)=>a.offsetTop-b.offsetTop);
        for (const n of nodes) if (n.offsetTop + n.offsetHeight > st + 4) {
            const m = (n.innerText||'').match(/number (\\d+)/);
            return {mk: m?+m[1]:-1, off: Math.round(n.offsetTop - st)};
        }
        return null;
    })()"""

    # Scroll to the MIDDLE of history (a text marker at the top), not following.
    TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        c.dispatchEvent(new WheelEvent('wheel', {bubbles:true}));
        c.scrollTop = Math.round(c.scrollHeight * 0.5);
        c.dispatchEvent(new Event('scroll', {bubbles:true}));
    })()""")
    # Wait for the virtual-scroll GEOMETRY TO SETTLE before capturing the
    # reference: scrolling into uncached history triggers range fetches +
    # ResizeObserver re-measures that shift the transcript by hundreds of px
    # for a while (estimates → real heights). Toggling mid-settle makes
    # "hold the view" ill-defined — the view is moving regardless — and under
    # full-suite load the settle takes well over the old fixed sleep. Stable ≡
    # scrollHeight AND scrollTop unchanged across 4 consecutive polls.
    @test TK.wait_for(s, "geometry settled", """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const key = c.scrollHeight + '|' + Math.round(c.scrollTop);
        window.__fsN = (window.__fsPrev === key) ? (window.__fsN || 0) + 1 : 0;
        window.__fsPrev = key;
        return window.__fsN >= 4;
    })()"""; timeout = 30, interval = 0.25) == true
    before = TK.eval_js(s, MARKER)
    @test before !== nothing && before["mk"] > 0

    # Toggle + pre-probe ATOMICALLY (one synchronous JS execution): the
    # invariant is "the toggle preserves the view AS OF THE TOGGLE INSTANT".
    # Under full-suite load a late ResizeObserver re-measure can still shift
    # the transcript by one row BETWEEN a Julia-side probe and the toggle —
    # that drift is settle noise, not a toggle jump, and comparing against a
    # stale probe was exactly the recurring one-row (~53px) soak flake.
    TOGGLE(hidden) = """(() => {
        const probe = $MARKER;
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        c.__bt_chat.setKeyHidden('tool:read', $hidden);
        return probe;
    })()"""
    # On failure, the anchor's own capture decision tells WHICH row it pinned.
    ANCHOR_DEBUG = "JSON.stringify(($CH)._anchorDebug ?? null)"
    # Viewport offset of marker #mk (the reading row), or null if not rendered.
    # The row is pinned at the viewport top by the toggle anchor, so it cannot
    # be virtualized away between the toggle and this probe.
    OFFSET_OF(mk) = """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const n = [...c.querySelectorAll('.bt-agent-msg')].filter(n=>n.offsetParent)
            .find(n => (((n.innerText||'').match(/number (\\d+)/)||[])[1]|0) === $mk);
        return n ? Math.round(n.offsetTop - c.scrollTop) : null;
    })()"""

    @testset "hiding a type holds the reading row" begin
        pre = TK.eval_js(s, TOGGLE(true))
        @test pre !== nothing && pre["mk"] > 0
        # Settle drift between the reference probe and the toggle is worth
        # SEEING when diagnosing (it was the historical flake), but it is not
        # a failure of the toggle itself.
        pre["mk"] == before["mk"] && pre["off"] == before["off"] ||
            @info "filter_scroll: geometry drifted between probe and toggle (settle noise)" before pre
        sleep(0.6)
        off = TK.eval_js(s, OFFSET_OF(pre["mk"]))
        ok = off !== nothing && abs(Int(off) - Int(pre["off"])) <= 4
        ok || @info "filter_scroll hide FAILED" pre off top = TK.eval_js(s, MARKER) anchor = TK.eval_js(s, ANCHOR_DEBUG)
        @test off !== nothing
        @test abs(Int(off) - Int(pre["off"])) <= 4   # reading row kept its screen position
    end

    @testset "showing it again holds the reading row" begin
        pre = TK.eval_js(s, TOGGLE(false))
        @test pre !== nothing && pre["mk"] > 0
        sleep(0.6)
        off = TK.eval_js(s, OFFSET_OF(pre["mk"]))
        ok = off !== nothing && abs(Int(off) - Int(pre["off"])) <= 6
        ok || @info "filter_scroll show FAILED" pre off top = TK.eval_js(s, MARKER) anchor = TK.eval_js(s, ANCHOR_DEBUG)
        @test off !== nothing
        @test abs(Int(off) - Int(pre["off"])) <= 6
    end

    @test isempty(TK.js_errors(s))
end
