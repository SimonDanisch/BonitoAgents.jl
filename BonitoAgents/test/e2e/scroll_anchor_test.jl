# Scroller hardening regressions (the "scrolling gets stuck / resets to an
# earlier position every second" review). Probes are PLAIN DOM / behavioral —
# deliberately independent of the fix's own helpers — and the history is many
# SMALL bubbles so the "which message is at the viewport top" probe is
# fine-grained (a single tall bubble hides shifts happening inside it).
# Each bug testset was verified RED against the pre-fix scroller.
@testitem "e2e:scroll_anchor" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    # Keep the viewport reproducible when this shares a browser with other suites.
    TK.set_window_size(s, 1280, 820)

    # One turn, MANY separate bubbles: tool events break the text coalescing,
    # so this yields ~30 small text bubbles + 30 tool rows in a single send.
    function anchor_agent(prompt)
        if occursin("seed", lowercase(prompt))
            evs = Any[]
            for i in 1:30
                push!(evs, TK.text("marker bubble number $(i) — a short line of prose"))
                push!(evs, TK.tool(kind = "read", title = "probe tool $(i)", id = "probe-$(i)"))
            end
            return evs
        end
        return [TK.text("echo: $(prompt)")]
    end
    s.agent_fn[] = anchor_agent

    pid = TK.new_chat(s; title = "Anchor")
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "seeded bubbles rendered",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 5"; timeout = 60) == true
    @test TK.wait_for(s, "overflows",
        "(() => { const c=[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent); return !!c && c.scrollHeight > c.clientHeight + 800; })()"; timeout = 15) == true

    CH = "[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent).__bt_chat"

    # The row read at the viewport top + its offset, by TEXT: the first with MORE
    # than 4px in view, which is the row the transcript itself keeps in place
    # (`captureAnchor`). A row showing less is no reading position: its last
    # pixel comes and goes with the up-to-1px rounding a correction may land
    # with (whole pixels at CI's devicePixelRatio 1), and counting it made the
    # probe name the NEXT row while the view had not moved (|Δoff| = one row
    # step, 53 px, on every CI run since 10-16).
    TOP_PROBE = """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const st = c.scrollTop;
        const nodes = [...c.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg')]
            .filter(n => n.offsetParent).sort((a,b) => a.offsetTop - b.offsetTop);
        for (const n of nodes) {
            if (n.offsetTop + n.offsetHeight > st + 4) {
                return {text: (n.innerText||'').replace(/\\s+/g,' ').slice(0, 40),
                        off: Math.round(n.offsetTop - st)};
            }
        }
        return null;
    })()"""

    scroll_frac!(frac) = (TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
        c.scrollTop = Math.round(c.scrollHeight * $frac);
        c.dispatchEvent(new Event('scroll', {bubbles: true}));
    })()"""); sleep(0.8))

    # Poll until the top marker is STABLE (the row observer's correction lands
    # before the next paint, but loads and mounts can follow), then return it.
    function settled_top()
        prev = nothing; now = nothing
        for _ in 1:40
            sleep(0.05)
            now = TK.eval_js(s, TOP_PROBE)
            prev !== nothing && now !== nothing && now["text"] == prev["text"] &&
                abs(Int(now["off"]) - Int(prev["off"])) <= 1 && break
            prev = now
        end
        return now
    end

    @testset "rows growing above the viewport must not move the view" begin
        # The real-world churn: images, editors and bodies above the reader
        # reach their real size after the rows are in the page. Grow every row
        # above the viewport by a media-sized amount, in the same synchronous
        # step as the probe, and the reading row has to stay where it was.
        TK.eval_js(s, "(() => { const ch = $CH; ch.setFollowMode(false); ch.cancelPendingScroll(); return true; })()")
        scroll_frac!(0.55)
        settled_top()
        r = TK.eval_js(s, """(() => {
            const probe = $TOP_PROBE;
            const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
            let grown = 0;
            for (const n of c.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg')) {
                if (n.offsetParent === null || n.offsetTop + n.offsetHeight > c.scrollTop) continue;
                n.style.minHeight = (n.offsetHeight + 300) + 'px';
                grown++;
            }
            return { probe, grown };
        })()""")
        before = r["probe"]
        @test before !== nothing
        @test Int(r["grown"]) > 3                # the churn genuinely hit rows above
        after = settled_top()
        @test after !== nothing
        @test after["text"] == before["text"]
        @test abs(Int(after["off"]) - Int(before["off"])) <= 3
    end

    @testset "rows dropped above the reader must not move the view" begin
        # A block grown past its cap drops rows on the side away from the
        # viewport. Dropping them ABOVE the reader takes their height with them,
        # which the scroll position has to absorb.
        scroll_frac!(0.85)
        before = settled_top()
        @test before !== nothing
        dropped = TK.eval_js(s, """(() => {
            const ch = $CH;
            const n0 = ch.order.length;
            ch.MAX_WINDOW = 20; ch.CHUNK = 10;     // force a trim right here
            ch.trimBlock();
            return n0 - ch.order.length;
        })()""")
        @test Int(dropped) > 0
        after = settled_top()
        @test after["text"] == before["text"]
        @test abs(Int(after["off"]) - Int(before["off"])) <= 3
        TK.eval_js(s, "(() => { const ch = $CH; ch.MAX_WINDOW = 160; ch.CHUNK = 40; ch.ensureWindow(); return true; })()")
    end

    @testset "a reply for a block that is gone is not placed" begin
        # The splice race, simulated at the seam: a msgs.range reply stamped with
        # a stale epoch, and one answering no request of ours, must both be
        # dropped instead of inserted among the wrong rows.
        ghost = TK.eval_js(s, """(() => {
            const ch = $CH;
            const ghost = {type: 'user', text: 'STALE-EPOCH-GHOST'};
            ch.onRange({start: 0, msgs: [ghost], epoch: ch.epoch - 1, req: ch.reqSeq});
            ch.onRange({start: 0, msgs: [ghost], epoch: ch.epoch, req: 987654});
            return ch.container.innerText.includes('STALE-EPOCH-GHOST');
        })()""")
        @test ghost == false
    end

    @testset "an idle pane downloads nothing" begin
        # The block loads only what the viewport nears: a pane left alone sends
        # no requests at all (the old scroller trickled the entire history in).
        sleep(1)
        n = TK.eval_js(s, """(() => new Promise(resolve => {
            const ch = $CH;
            let n = 0;
            const orig = ch.comm.notify.bind(ch.comm);
            ch.comm.notify = (m, ...rest) => { if (m && m.type === 'msgs.request') n++; return orig(m, ...rest); };
            setTimeout(() => { ch.comm.notify = orig; resolve(n); }, 2000);
        }))()""")
        @test Int(n) == 0
    end

    @testset "saved position is content-true across hide/show height churn" begin
        scroll_frac!(0.35)
        before = settled_top()
        @test before !== nothing
        # The REAL race: pixels move right AFTER showing (rows reaching their
        # size) while the restore cascade (0/rAF/50/200ms) is still re-writing
        # the saved position. A pixel restore then lands on a different
        # message; a content anchor lands on the one the user was reading. We
        # hide/show, then grow every row INSIDE the cascade window (~80ms).
        TK.eval_js(s, """(() => {
            const ch = $CH;
            ch.onHidden();
            ch.onShown();
            setTimeout(() => {
                for (const n of ch.container.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg'))
                    n.style.minHeight = (n.offsetHeight + 70) + 'px';
            }, 80);
        })()""")
        sleep(0.8)   # past the 200ms apply + settle
        after = settled_top()
        @test after !== nothing
        @test after["text"] == before["text"]
    end

    @testset "no JS errors" begin
        @test isempty(TK.js_errors(s))
    end
end
