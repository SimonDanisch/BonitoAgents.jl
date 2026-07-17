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

    # First visible message bubble at the viewport top + its offset, by TEXT.
    TOP_PROBE = """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const st = c.scrollTop;
        const nodes = [...c.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg')]
            .filter(n => n.offsetParent).sort((a,b) => a.offsetTop - b.offsetTop);
        for (const n of nodes) {
            if (n.offsetTop + n.offsetHeight > st) {
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

    # The real-world churn: heights in the TOP SPACER region (below the
    # rendered window) get set LARGER than their estimate — prefetch
    # measurement and EST_HEIGHT adaptation only ever touch UNRENDERED
    # indices; the ResizeObserver keeps every rendered node's map entry
    # equal to its DOM pixels, so inflating rendered rows would fabricate a
    # map/DOM contradiction production cannot reach. Returns the number of
    # inflated entries.
    INFLATE = """(() => {
        const ch = $CH;
        if (ch.rendered.size === 0) return 0;
        const winStart = Math.min(...ch.rendered);
        let inflated = 0;
        for (let i = 0; i < winStart; i++) {
            const h = ch.heights.get(i) ?? ch.EST_HEIGHT;
            ch.heights.set(i, h + 90);   // prefetch measured them ~90px taller
            inflated++;
        }
        ch.refresh();
        return inflated;
    })()"""

    @testset "height churn above the viewport must not move the view" begin
        # Churn heights in the top spacer (below the rendered window) LARGER than
        # their estimate — the same shape as a background prefetch re-measuring
        # unrendered rows taller. When the map-based visibleRange() shifts off the
        # DOM's real top-visible node the anchor gets EVICTED, and _restoreAnchor
        # then used a cumHeight() virtual position that omitted the container
        # padding + gap-after-spacer, landing ~a row short — so the follow-up
        # refresh re-anchored the NEIGHBOUR and the view jumped ~1 row (stuck).
        scroll_frac!(0.55)
        # Wait for the virtual-scroll geometry to SETTLE first: under
        # full-suite load, range fetches + estimate→real corrections keep
        # shifting the transcript for a while after the scroll, and probing
        # mid-settle compares against a state the anchor never saw (the
        # filter_scroll one-row-drift disease, here worth many rows).
        @test TK.wait_for(s, "geometry settled before churn", """(() => {
            const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
            const key = c.scrollHeight + '|' + Math.round(c.scrollTop);
            window.__saN = (window.__saPrev === key) ? (window.__saN || 0) + 1 : 0;
            window.__saPrev = key;
            return window.__saN >= 4;
        })()"""; timeout = 30, interval = 0.25) == true
        # Probe + churn ATOMICALLY (one synchronous JS execution): the
        # invariant is "the compensation preserves the view AS OF THE CHURN
        # INSTANT" — a probe taken a round-trip earlier measures settle
        # noise, not the compensation.
        r = TK.eval_js(s, """(() => {
            const probe = $TOP_PROBE;
            const inflated = $INFLATE;
            return { probe, inflated };
        })()""")
        before = r["probe"]
        @test before !== nothing
        @test Int(r["inflated"]) > 3     # the churn genuinely hit rows above
        # Poll until the top marker STABILISES (the compensation is a synchronous
        # bump plus a few async correction passes; all settle well under 1s even
        # under load), then assert the view didn't move. No fixed-sleep gamble —
        # and because the drift landed on a STABLE wrong row, waiting for
        # stability still catches a regression.
        prev = nothing; after = nothing
        for _ in 1:40          # up to ~2s
            sleep(0.05)
            after = TK.eval_js(s, TOP_PROBE)
            if prev !== nothing && after !== nothing &&
               after["text"] == prev["text"] && abs(Int(after["off"]) - Int(prev["off"])) <= 1
                break
            end
            prev = after
        end
        @test after !== nothing
        ok = after !== nothing && after["text"] == before["text"] &&
             abs(Int(after["off"]) - Int(before["off"])) <= 3
        ok || @info "scroll_anchor churn FAILED" before after anchor =
            TK.eval_js(s, "JSON.stringify(($CH)._anchorDebugG ?? null)")
        @test after["text"] == before["text"]
        @test abs(Int(after["off"]) - Int(before["off"])) <= 3
    end

    @testset "evicted-anchor restore lands the node at its offset (#32)" begin
        # Deterministic (no load/timing) guard for the coordinate bug: force the
        # EVICT branch of _restoreAnchor and require the anchored node to end up
        # exactly at the requested offset once the queued refresh re-materialises
        # it. Pre-fix, the virtual restore used cumHeight() WITHOUT PAD_TOP +
        # ITEM_GAP, so scrollTop landed ~a row short (node ~26px off) → the
        # follow-up refresh re-anchored the neighbour (the stuck ~1-row jump).
        idx = TK.eval_js(s, "(() => { const ch=$CH; " *
            "const r=[...ch.rendered].sort((a,b)=>a-b); return r[Math.floor(r.length/2)]; })()")
        @test idx !== nothing
        TK.eval_js(s, """(() => {
            const ch = $CH;
            ch.rendered.delete($idx);          // simulate the re-window eviction
            ch._restoreAnchor({idx: $idx, off: -20});
            return true; })()""")
        @test TK.wait_for(s, "evicted anchor restored to off=-20",
            """(() => {
                const ch = $CH;
                const n = ch.cache.get($idx);
                if (!n || !n.isConnected || !ch.rendered.has($idx)) return false;
                return Math.abs((n.offsetTop - ch.container.scrollTop) - (-20)) <= 2;
            })()"""; timeout = 3) == true
        TK.eval_js(s, "(() => { ($CH).refresh(); })()")   # settle state for the next testset
    end

    @testset "a msgs.range reply from before a reload must not be cached" begin
        # The splice race, simulated at the seam: an UNCACHED index receives a
        # reply stamped with the pre-reload epoch. It must be dropped.
        ghost_cached = TK.eval_js(s, """(() => {
            const ch = $CH;
            const idx = 3;
            ch.cache.get(idx)?.remove();
            ch.cache.delete(idx); ch.rendered.delete(idx);
            const stale = (ch._epoch ?? 0) - 1;
            ch.onRange({start: idx, msgs: [{type: 'user', text: 'STALE-EPOCH-GHOST'}], epoch: stale});
            return ch.cache.has(idx) &&
                   (ch.cache.get(idx).innerText || '').includes('STALE-EPOCH-GHOST');
        })()""")
        @test ghost_cached == false
        sleep(0.3)
        # The evicted real row refetches on the next refresh (sanity).
        TK.eval_js(s, "(() => { ($CH).refresh(); })()")
    end

    @testset "hidden panes stop backfilling the transcript" begin
        # Prior testsets' fetch cascades (forced refresh + refetch above) can
        # still be in flight under load — their msgs.request would be counted
        # against _startPrefetch (the intermittent `116 == 0`). Wait for
        # REQUEST QUIESCENCE (no msgs.request for 800ms) before hooking.
        quiesced = TK.eval_js(s, """(() => new Promise(resolve => {
            const ch = $CH;
            const orig = ch.comm.notify.bind(ch.comm);
            let last = performance.now();
            const t0 = last;
            ch.comm.notify = (m) => {
                if (m && m.type === 'msgs.request') last = performance.now();
                return orig(m);
            };
            const tick = setInterval(() => {
                const idle = performance.now() - last > 800;
                if (idle || performance.now() - t0 > 15000) {
                    clearInterval(tick);
                    ch.comm.notify = orig;
                    resolve(idle);
                }
            }, 100);
        }))()""")
        @test quiesced == true
        # Stash the chat object + poke holes in its cache (so a running
        # prefetcher WOULD have rows to fetch), then REALLY hide the pane by
        # navigating to the dashboard — the product drives onHidden itself.
        # Manually faking ch.onHidden() on a still-visible pane was a
        # synthetic state: any product-side visibility resync — e.g. the
        # chat-LRU eviction (cap 8) updating the sidebar, which only happens
        # once the full soak has accumulated enough chats — flipped it back
        # to shown MID-COUNT, the backfill legitimately resumed (the
        # intermittent `188 == 0`), and by the explicit onShown phase it had
        # already finished (its `0 > 0` twin).
        TK.eval_js(s, """(() => {
            const ch = $CH;
            window.__saBf = ch;
            for (const k of [...ch.cache.keys()]) if (k % 2 === 0) { ch.cache.get(k)?.remove(); ch.cache.delete(k); ch.rendered.delete(k); }
            ch._prefetchStarted = false; ch._prefetchCursor = null;
            return true;
        })()""")
        TK.to_dashboard(s)
        sleep(0.5)
        n_requests = TK.eval_js(s, """(() => new Promise(resolve => {
            const ch = window.__saBf;
            let n = 0;
            const orig = ch.comm.notify.bind(ch.comm);
            ch.comm.notify = (m) => { if (m && m.type === 'msgs.request') n++; return orig(m); };
            ch._startPrefetch();
            setTimeout(() => { ch.comm.notify = orig; resolve(n); }, 1500);
        }))()""")
        @test Int(n_requests) == 0
        # Navigate back: the pane shows for real and the backfill resumes.
        TK.eval_js(s, """(() => {
            const ch = window.__saBf;
            window.__saBfN = 0;
            const orig = ch.comm.notify.bind(ch.comm);
            window.__saBfRestore = () => { ch.comm.notify = orig; };
            ch.comm.notify = (m) => { if (m && m.type === 'msgs.request') window.__saBfN++; return orig(m); };
            return true;
        })()""")
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "backfill resumes once shown",
            "window.__saBfN > 0"; timeout = 15) == true
        TK.eval_js(s, "window.__saBfRestore(); delete window.__saBf; true")
        sleep(1.5)   # let the resumed backfill settle
    end

    @testset "saved position is content-true across hide/show height churn" begin
        scroll_frac!(0.35)
        before = TK.eval_js(s, TOP_PROBE)
        @test before !== nothing
        # The REAL race: pixels move right AFTER showing (post-show
        # re-measure corrections re-space the pane) while the restore
        # cascade (0/rAF/50/200ms) is still re-writing the SAVED value. A
        # pixel restore then lands on a different message; a content anchor
        # lands on the one the user was reading. We hide/show, then inject
        # the correction churn INSIDE the cascade window (~80ms, between the
        # 50ms and 200ms applies).
        TK.eval_js(s, """(() => {
            const ch = $CH;
            ch.onHidden();
            ch.onShown();
            setTimeout(() => {
                for (const [i, h] of [...ch.heights]) ch.heights.set(i, h + 70);
                ch.refresh();                            // re-space: pixels move
            }, 80);
        })()""")
        sleep(0.8)   # past the 200ms apply + settle
        after = TK.eval_js(s, TOP_PROBE)
        @test after !== nothing
        @test after["text"] == before["text"]
    end

    @testset "no JS errors" begin
        @test isempty(TK.js_errors(s))
    end
end
