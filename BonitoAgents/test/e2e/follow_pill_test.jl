# Black-box port of the legacy Tier-2n electron test (test_follow_pill.jl).
#
# Verifies the scroll-UX contract for follow mode + the "↓ New messages" pill,
# driven PURELY through the browser against a real dev_server — no make_state,
# no chat_emit, no msgs_store, no internal-state injection. History is seeded by
# actually sending user messages (the echo agent builds the bubbles); the
# "agent burst while the user is scrolled away" is produced by swapping
# `agent_fn` to a scenario that holds the turn open with a `delay`, then streams
# many `text` chunks — each chunk lands via `appendChunk`, which bumps
# `unreadCount` + surfaces the pill while followMode is off. The `delay` gives
# the test a window to scroll up BEFORE the chunks arrive, exactly mirroring the
# legacy "scroll up first, then emit the burst" ordering.
#
# Contract covered (one behavioral assertion per legacy section):
#   1. followMode starts true; no pill, unread 0.
#   2. streaming while pinned at the bottom keeps followMode true, no pill.
#   3. user scroll-to-top (wheel + scrollTop=0 + scroll event) → followMode
#      false; the pill shows as the PLAIN "Move to bottom" jump button (visible
#      whenever off-bottom) but NOT glowing (nothing unread yet).
#   4. new chunks while disengaged → pill GLOWS "New messages" + unreadCount > 0,
#      and the chunks DON'T yank follow back on.
#   5. clicking the pill → followMode true, pill hidden, unread cleared, viewport
#      snapped to the bottom (scroll gap < 50).
#   6. scrolling manually back to the very bottom auto-re-engages followMode.
#   7. sending a user message from scrollback does NOT auto-re-engage — the
#      user's bubble counts as unread, the pill stays up, scrollTop doesn't jump.
#   8. no JS errors during the whole exercise.
#
# All assertions read BROWSER state (`__bt_chat.followMode`, `.unreadCount`,
# `.bt-new-msg-pill.bt-new-msg-pill-visible`, scrollTop/scrollHeight) via eval_js
# — that's the UI's own client state, not a Julia internal, so it's fair game.
@testitem "e2e:follow_pill" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # A tall fenced code block renders as a <pre> that preserves all its lines,
    # so the messages container genuinely overflows (plain text collapses
    # newlines and wouldn't give us a real scroll range to play with).
    CODE = "```\n" * join(["history row $(i) of generated output" for i in 1:90], "\n") * "\n```"

    # Agent scenarios, swapped per phase via `agent_fn`:
    #   "seed …"  → a tall code block (overflows the viewport, gives a bottom to
    #                chase + a top to scroll to).
    #   "burst …" → hold the turn open ~1.6s (so the test can scroll up first),
    #                then stream many short chunks into ONE agent bubble. Each
    #                chunk is a distinct `appendChunk` → registers unread while
    #                followMode is off.
    #   else      → a plain echo.
    function follow_agent(prompt)
        p = lowercase(prompt)
        if occursin("seed", p)
            return [TK.text(CODE)]
        elseif occursin("medium", p)
            # A ~12-line code block: tall enough (~300px) that the "last
            # message partially visible" re-engage zone is genuinely wide,
            # but well under one viewport (the cap never kicks in).
            return [TK.text("```\n" * join(["reply row $(i)" for i in 1:12], "\n") * "\n```")]
        elseif occursin("burst", p)
            evs = Any[TK.delay(1600)]
            for _ in 1:8
                push!(evs, TK.text("More content arriving while the user is scrolled away. "))
            end
            return evs
        else
            return [TK.text("echo: $(prompt)")]
        end
    end
    s.agent_fn[] = follow_agent

    # ── browser-state probes (read the UI's own client state) ────────────────
    # Every chat pane — including PRIOR soak-server chats kept hidden in the DOM —
    # has its own `.bt-messages` and `.bt-new-msg-pill`. A global `querySelector`
    # can hit a STALE hidden pane's element (this raced the pill asserts: the
    # active pane's `unreadCount` said >0 while a different pane's pill said no
    # glow). Scope every probe to the VISIBLE pane: `.bt-new-msg-pill` is
    # `display:none` until `-visible`, and a backgrounded pane is `display:none`,
    # so `offsetParent !== null` uniquely selects the active, shown element.
    vis_msgs = "[...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent !== null)"
    vis_pill = "[...document.querySelectorAll('.bt-new-msg-pill')].find(e => e.offsetParent !== null)"
    follow_mode() = TK.eval_js(s, "(() => { const c = $vis_msgs; return c ? c.__bt_chat.followMode : null; })()")
    unread()      = TK.eval_js(s, "(() => { const c = $vis_msgs; return c ? c.__bt_chat.unreadCount : 0; })()")
    # A pill found via `offsetParent` is by definition displayed ⇒ `-visible`.
    pill_visible() = TK.eval_js(s, "(() => { const el = $vis_pill; return !!el && el.classList.contains('bt-new-msg-pill-visible'); })()")
    # The pill is visible whenever NOT at the bottom; it only GLOWS (the
    # "New messages" nudge) when there's unread content. Off-bottom with nothing
    # unread it's the plain "Move to bottom" jump button.
    pill_glowing() = TK.eval_js(s, "(() => { const el = $vis_pill; return !!el && el.classList.contains('bt-new-msg-pill-glow'); })()")
    pill_text() = TK.eval_js(s, "(() => { const el = $vis_pill; return el ? (el.textContent || '') : ''; })()")

    # Drive the scroll the way the legacy test did: a `wheel` event arms
    # `_pendingUserScroll`, then setting scrollTop + firing `scroll` makes the
    # chat's own handler classify it as a user-driven scroll and flip followMode
    # off (it's not at the bottom). This fires the exact DOM events the chat's
    # scroll handler listens on, so it works without the custom pan scroller.
    function scroll_up_as_user!()
        TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-messages');
            c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
            c.scrollTop = 0;
            c.dispatchEvent(new Event('scroll', {bubbles: true}));
            return true;
        })()""")
        sleep(0.3)
    end

    @testset "follow mode + new-message pill (black-box)" begin
        # Fresh chat on the shared server so we don't inherit a neighbor's state.
        pid = TK.new_chat(s; title = "FollowPill")

        # Seed a real history: a tall code block that overflows the viewport, so
        # there is a genuine top to scroll to and a bottom to chase. (Replaces
        # the legacy `seed_chat_history!(model, 20)` internal injection.)
        TK.send_message(s, "seed history please")
        @test TK.wait_for(s, "code block rendered",
            "!!document.querySelector('.bt-agent-msg pre')"; timeout = 60) == true
        @test TK.wait_for(s, "viewport overflows",
            "(() => { const c=document.querySelector('.bt-messages'); return !!c && c.scrollHeight > c.clientHeight + 300; })()"; timeout = 10) == true
        # Follow mode pins the newest content at the bottom.
        @test TK.wait_for(s, "pinned at bottom",
            "(() => { const c=document.querySelector('.bt-messages'); return (c.scrollHeight - c.scrollTop - c.clientHeight) < 50; })()"; timeout = 10) == true

        # ── 1. Initial state: followMode=true, no pill ──────────────────────
        @testset "initial: followMode true, no pill, unread 0" begin
            @test follow_mode() == true
            @test Int(unread()) == 0
            @test pill_visible() == false
        end

        # ── 1b. Pill threshold: only when the LAST message is fully out of view ──
        # The pill's visibility criterion is `lastMessageFullyOutOfView()`, NOT
        # the tight AT_BOTTOM_PX check: while any pixel of the last message is
        # still visible there is nothing hidden to jump to, so no pill. Append a
        # SHORT echo bubble under the tall seed block (so there's plenty of
        # scrollback above a small last message), then scroll up in two stages:
        # (a) half the last bubble's off-bottom span — it stays partially
        # visible → NO pill (though followMode disengages), (b) past its full
        # height → pill appears, plain (no glow — nothing unread).
        @testset "pill only when last message fully out of view" begin
            TK.send_message(s, "make the last message short")
            @test TK.wait_for(s, "short echo is the last message + turn done + pinned",
                """(() => {
                    const c = document.querySelector('.bt-messages');
                    const chat = c.__bt_chat;
                    const node = chat.cache.get(chat.totalCount - 1);
                    if (!node || !node.isConnected) return false;
                    if (!node.classList.contains('bt-agent-msg')) return false;
                    if (!(node.textContent || '').includes('echo: make the last message short')) return false;
                    if (c.querySelector('.bt-busy.bt-busy-active')) return false;
                    return (c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                })()"""; timeout = 20) == true
            @test follow_mode() == true
            @test pill_visible() == false
            # `out` = how many px we must scroll UP from the bottom until the
            # last bubble's top edge reaches the visible bottom (fully out).
            out = Float64(TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                const node = chat.cache.get(chat.totalCount - 1);
                return c.getBoundingClientRect().bottom - node.getBoundingClientRect().top;
            })()"""))
            # Tail (50px) + gap + the bubble itself: the halfway point sits
            # beyond AT_BOTTOM_PX (20), so followMode genuinely disengages
            # while the bubble is still partially visible.
            @test out > 60
            # (a) Scroll up HALF the way: clearly off the bottom (followMode
            # off), but the bubble is still partially visible → no pill. Poll a
            # short window so a lagging (wrong) pill update would be caught.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollTop - $(out / 2);
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.3)
            @test follow_mode() == false
            for _ in 1:5
                @test pill_visible() == false
                sleep(0.1)
            end
            @test Int(unread()) == 0
            # (b) Scroll up past the bubble's full height (+margin): now not a
            # single pixel of the last message is visible → plain pill.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollTop - ($(out / 2) + 60);
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            @test TK.wait_for(s, "pill visible once last message fully out",
                "(() => { const el = $vis_pill; return !!el; })()"; timeout = 6) == true
            @test follow_mode() == false
            @test Int(unread()) == 0
            @test pill_glowing() == false
            @test occursin("Move to bottom", String(pill_text()))
        end

        # ── 1c. Flicker guard: layout jitter must not toggle the pill ───────
        # Typing autosizes the composer, which shifts the messages container by
        # ~a keystroke's worth of pixels and fires scroll events. The old
        # razor-thin off-bottom criterion flipped the pill on/off per event.
        # Simulate the jitter directly: bursts of no-op scroll events and small
        # scrollTop wiggles (1px AND 25px — the latter crosses the old
        # AT_BOTTOM_PX=20 boundary) while parked at the bottom → the pill must
        # never show. Conversely, parked far up (pill showing), ±1px jitter must
        # never hide it. The dispatches run synchronously, so sampling the class
        # after each event catches even a single-event flicker.
        @testset "scroll jitter never flickers the pill" begin
            # Back to the bottom as a user scroll → followMode on, pill hidden.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollHeight - c.clientHeight;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.4)
            @test follow_mode() == true
            @test pill_visible() == false
            # Jitter burst at the bottom: the pill must never become visible.
            flickered = TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const shown = () => {
                    const els = [...document.querySelectorAll('.bt-new-msg-pill')];
                    return els.some(e => e.classList.contains('bt-new-msg-pill-visible') && e.offsetParent !== null);
                };
                const max = c.scrollHeight - c.clientHeight;
                let ever = false;
                for (let i = 0; i < 40; i++) {
                    const jitter = (i % 4 === 3) ? 25 : (i % 2);   // 0/1px + occasional 25px
                    c.scrollTop = Math.max(0, max - jitter);
                    c.dispatchEvent(new Event('scroll', {bubbles: true}));
                    if (shown()) ever = true;
                }
                c.scrollTop = max;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return ever;
            })()""")
            @test flickered == false
            sleep(0.3)
            @test pill_visible() == false
            @test follow_mode() == true
            # Now park far up (pill visible) and jitter ±1px: must never hide.
            scroll_up_as_user!()
            @test TK.wait_for(s, "pill visible after scroll-up",
                "(() => { const el = $vis_pill; return !!el; })()"; timeout = 6) == true
            hidden_during_jitter = TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const shown = () => {
                    const els = [...document.querySelectorAll('.bt-new-msg-pill')];
                    return els.some(e => e.classList.contains('bt-new-msg-pill-visible') && e.offsetParent !== null);
                };
                const base = c.scrollTop;
                let everHidden = false;
                for (let i = 0; i < 40; i++) {
                    c.scrollTop = Math.max(0, base + (i % 2));
                    c.dispatchEvent(new Event('scroll', {bubbles: true}));
                    if (!shown()) everHidden = true;
                }
                return everHidden;
            })()""")
            @test hidden_during_jitter == false
            @test pill_visible() == true
            # Leave the pane pinned at the bottom with follow mode on — the
            # streaming testset below starts from that state. Sleep past the
            # 400ms user-driven classification window our synthetic wheel
            # armed, so the next testset's send doesn't get its layout scroll
            # misread as a user scroll landing off-bottom.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollHeight - c.clientHeight;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.6)
            @test follow_mode() == true
            @test pill_visible() == false
        end

        # ── 2. Streaming while at bottom — no pill ──────────────────────────
        @testset "streaming while at bottom doesn't show pill" begin
            TK.send_message(s, "burst at bottom")
            # While we're at the bottom, the chunks chase us down — followMode
            # stays on, nothing is unread, no pill. Wait out the delay + stream.
            @test TK.wait_for(s, "burst arrived",
                "(() => { const c=document.querySelector('.bt-messages'); return c.__bt_chat.totalCount >= 3; })()"; timeout = 20) == true
            sleep(0.6)
            @test follow_mode() == true
            @test Int(unread()) == 0
            @test pill_visible() == false
        end

        # ── 3. User scrolls to top → followMode off; a PLAIN jump pill appears ──
        @testset "scroll-to-top disengages follow mode; plain jump pill shows" begin
            scroll_up_as_user!()
            @test follow_mode() == false
            # The pill is visible whenever we're off the bottom — but with nothing
            # unread yet it's the plain "Move to bottom" form, NOT the glowing
            # "New messages" nudge. Poll for visibility (the scroll→pill update can
            # lag a fixed sleep when the shared browser is loaded) THEN read the
            # plain-state sub-fields, which are set together with visibility.
            @test TK.wait_for(s, "plain jump pill visible",
                "(() => { const el = $vis_pill; return !!el; })()"; timeout = 6) == true
            @test pill_glowing() == false
            @test occursin("Move to bottom", String(pill_text()))
        end

        # ── 4. New chunks while disengaged → pill visible, unread > 0 ────────
        @testset "new content while disengaged surfaces the pill" begin
            # Trigger a burst. The agent holds the turn ~1.6s before streaming,
            # so re-assert the scrolled-up position right before the chunks land
            # (the user's own send doesn't move us — followMode is already off).
            TK.send_message(s, "burst while away")
            scroll_up_as_user!()       # ensure we're parked at the top as it streams
            # Unread content → the pill GLOWS and reads "New messages". Poll for the
            # GLOW class specifically (not just visibility): the unread registration
            # that adds the glow lands a beat after the pill first becomes visible,
            # so gating on `-visible` alone races the glow/text reads below.
            @test TK.wait_for(s, "pill glowing (New messages)",
                "(() => { const el = $vis_pill; return !!el && el.classList.contains('bt-new-msg-pill-glow'); })()"; timeout = 6) == true
            # The chunks didn't yank us back into follow mode...
            @test follow_mode() == false
            # ...and unread counted them.
            @test Int(unread()) > 0
            @test pill_glowing() == true
            @test occursin("New messages", String(pill_text()))
        end

        # ── 5. Click pill → followMode on, scroll to bottom, pill hides ─────
        @testset "clicking the pill re-engages, hides pill, jumps to bottom" begin
            TK.eval_js(s, "(() => { const el = $vis_pill; el && el.click(); })()")
            @test TK.wait_for(s, "followMode re-engaged",
                "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4) == true
            @test TK.wait_for(s, "pill hidden",
                "(() => { return !($vis_pill); })()"; timeout = 4) == true
            @test Int(unread()) == 0
            # Scroll should settle to the bottom (rAF can be throttled offscreen,
            # so poll up to a couple seconds).
            @test TK.wait_for(s, "scroll gap < 50 after pill click",
                """(() => {
                    const c = document.querySelector('.bt-messages');
                    return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                })()"""; timeout = 4) == true
        end

        # ── 6. Scrolling back to the very bottom auto-re-engages ────────────
        @testset "scrolling to the bottom auto-re-engages follow mode" begin
            # Let the prior burst finish streaming before we drive the scroll by
            # hand. A chunk landing mid-gesture grows scrollHeight and races the
            # synthetic scroll-to-bottom, so the handler can sample a position
            # that's no longer within AT_BOTTOM_PX. (The re-engage logic itself is
            # correct — verified directly: a user scroll landing at the bottom
            # flips followMode back on, gap 0, even with this much content.)
            let last = -1, n = -2, tries = 0
                while n != last && tries < 40
                    last = n
                    n = Int(TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.totalCount"))
                    tries += 1
                    sleep(0.3)
                end
            end
            # First disengage.
            scroll_up_as_user!()
            @test follow_mode() == false
            # Now simulate the user scrolling back down: wheel + scrollTop set to
            # the very bottom (scrollHeight - clientHeight) + scroll event. The
            # handler sees a user-driven scroll that landed at the bottom → true.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollHeight - c.clientHeight;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.4)
            @test follow_mode() == true
            @test pill_visible() == false
        end

        # ── 7. Sending a user message from scrollback stays in scrollback ───
        # Strict spec: "always stay at the position the user scrolls to". The
        # user's own bubble appears + counts as unread, the pill stays up, and
        # they have to click the pill (or scroll down) to come back.
        @testset "user message from scrollback does NOT auto-re-engage" begin
            # Use the plain-echo agent so the reply is small + immediate.
            s.agent_fn[] = follow_agent
            scroll_up_as_user!()
            @test follow_mode() == false
            scroll_top_before = TK.eval_js(s, "document.querySelector('.bt-messages').scrollTop")
            TK.send_message(s, "stay where I am")
            # The user's own send registers as unread → the pill stays visible.
            # Poll for it (the unread→pill update can lag a fixed sleep when the
            # shared browser is loaded — this raced intermittently as a bare sleep).
            @test TK.wait_for(s, "pill stays visible after scrollback send",
                "(() => { const el = $vis_pill; return !!el; })()"; timeout = 6) == true
            @test follow_mode() == false
            # ScrollTop shouldn't have jumped to the bottom (generous tolerance
            # for any scroll-anchoring shift as new bottom nodes get added).
            scroll_top_after = TK.eval_js(s, "document.querySelector('.bt-messages').scrollTop")
            @test abs(Int(round(scroll_top_after)) - Int(round(scroll_top_before))) < 200
        end

        # ── 7b. Generous downward re-engage: follow shares the pill boundary ─
        # Re-engage is DIRECTION-AWARE and generous: while follow is off, a
        # DOWNWARD user scroll re-engages the moment any pixel of the last
        # message is visible (exactly when the pill hides — one shared
        # boundary) AND less than one viewport remains to the bottom. The
        # razor-thin AT_BOTTOM_PX disengage is untouched, so an UPWARD peek
        # into the very same zone stays disengaged (asymmetry, tested in 7c).
        @testset "downward scroll into the last-message zone re-engages" begin
            # Let the scrollback-send turn from testset 7 finish so no late
            # append races the hand-driven scrolls below.
            @test TK.wait_for(s, "turn finished",
                "(() => { const c = document.querySelector('.bt-messages'); return !c.querySelector('.bt-busy.bt-busy-active'); })()"; timeout = 20) == true
            # Pin back to the bottom, then make the LAST message a ~300px code
            # block so the "partially visible" zone is genuinely wide — a
            # one-line echo bubble leaves only ~50px between the pill
            # boundary and AT_BOTTOM_PX, too marginal to prove generosity.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollHeight - c.clientHeight;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.4)
            @test follow_mode() == true
            TK.send_message(s, "a medium reply please")
            @test TK.wait_for(s, "medium block is the last message + turn done + pinned",
                """(() => {
                    const c = document.querySelector('.bt-messages');
                    const chat = c.__bt_chat;
                    const node = chat.cache.get(chat.totalCount - 1);
                    if (!node || !node.isConnected) return false;
                    if (!node.querySelector('pre')) return false;
                    if (!(node.textContent || '').includes('reply row 12')) return false;
                    if (c.querySelector('.bt-busy.bt-busy-active')) return false;
                    return (c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                })()"""; timeout = 20) == true
            # `out` = px to scroll up from the very bottom until the block's
            # top reaches the visible bottom (same probe as testset 1b):
            # landing at out/2 puts it half-visible, far beyond AT_BOTTOM_PX.
            out = Float64(TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                const node = chat.cache.get(chat.totalCount - 1);
                return c.getBoundingClientRect().bottom - node.getBoundingClientRect().top;
            })()"""))
            @test out > 100
            # Park far up: follow off, pill visible.
            scroll_up_as_user!()
            @test follow_mode() == false
            @test TK.wait_for(s, "pill visible while parked at top",
                "(() => { const el = $vis_pill; return !!el; })()"; timeout = 6) == true
            # Step 1 (still outside the zone): a downward user scroll landing
            # one-viewport-plus above the bottom must NOT re-engage — the last
            # message shows no pixel there and the gap exceeds the cap.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = (c.scrollHeight - c.clientHeight) - (c.clientHeight + 60);
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.3)
            @test follow_mode() == false
            # Step 2 (into the zone): downward again, landing where the last
            # bubble is partially visible (gap = out/2 < one viewport). The
            # old model needed atBottom (20px); the redesign re-engages here.
            in_zone = TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = (c.scrollHeight - c.clientHeight) - $(out / 2);
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                // Precondition probes, sampled at the event: pixel visible + capped gap.
                const gap = c.scrollHeight - c.scrollTop - c.clientHeight;
                return !chat.lastMessageFullyOutOfView() && gap < c.clientHeight && gap > chat.AT_BOTTOM_PX;
            })()""")
            @test in_zone == true
            @test TK.wait_for(s, "followMode re-engaged by downward zone scroll",
                "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4) == true
            @test TK.wait_for(s, "pill hidden after re-engage",
                "(() => { return !($vis_pill); })()"; timeout = 4) == true
            # The queued chase pins the viewport to the bottom (fires once the
            # user-input recency window lapses; poll, rAF can be throttled).
            @test TK.wait_for(s, "chase settled to bottom after re-engage",
                """(() => {
                    const c = document.querySelector('.bt-messages');
                    return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                })()"""; timeout = 4) == true
            @test Int(unread()) == 0
        end

        # ── 7c. Asymmetry: an upward peek into the same zone stays OFF ──────
        # From the bottom, scroll UP so the last message is still partially
        # visible (inside the re-engage zone, beyond AT_BOTTOM_PX): follow
        # disengages exactly as before and must NOT snap back — the zone only
        # pulls in scrolls moving DOWN. The pill stays hidden too (in-between
        # state: a pixel of the last message still shows).
        @testset "upward peek into the zone stays disengaged (no snap-back)" begin
            @test follow_mode() == true       # pinned at bottom from 7b
            out = Float64(TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                const node = chat.cache.get(chat.totalCount - 1);
                return c.getBoundingClientRect().bottom - node.getBoundingClientRect().top;
            })()"""))
            @test out > 60
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollTop - $(out / 2);
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.3)
            @test follow_mode() == false
            # No snap-back: poll a window — the position must hold (a wrongly
            # queued chase would yank the gap back under AT_BOTTOM_PX).
            for _ in 1:5
                @test follow_mode() == false
                @test pill_visible() == false   # in-between: pixel visible, no pill
                sleep(0.1)
            end
            gap = Float64(TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                return c.scrollHeight - c.scrollTop - c.clientHeight;
            })()"""))
            @test gap > 20
        end

        # ── 7d. Viewport cap: a multi-screen-tall last message can't snap ───
        # With the tall seed block as the LAST message, a downward scroll that
        # lands with the block partially visible but MORE than one viewport of
        # gap must NOT re-engage — the cap keeps a snap from skipping content
        # the user is reading. Scrolling further down, inside one viewport,
        # re-engages as usual.
        @testset "tall last message: gap > viewport blocks re-engage" begin
            # 7c left follow OFF a peek above the bottom — pin back first so
            # the seed below chases into view.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollHeight - c.clientHeight;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            sleep(0.4)
            @test follow_mode() == true
            TK.send_message(s, "seed a tall last message")
            @test TK.wait_for(s, "tall block is the last message + turn done",
                """(() => {
                    const c = document.querySelector('.bt-messages');
                    const chat = c.__bt_chat;
                    const node = chat.cache.get(chat.totalCount - 1);
                    if (!node || !node.isConnected) return false;
                    if (!node.querySelector('pre')) return false;
                    if (c.querySelector('.bt-busy.bt-busy-active')) return false;
                    return (c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                })()"""; timeout = 30) == true
            @test follow_mode() == true
            # The block must be tall enough that "partially visible" and
            # "gap > one viewport" can hold at once (top at mid-viewport ⇒
            # gap ≈ height - viewport/2 + tail > viewport needs height >
            # 1.5 viewports).
            tall_enough = TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                const node = chat.cache.get(chat.totalCount - 1);
                return node.getBoundingClientRect().height > 1.5 * c.clientHeight + 100;
            })()""")
            @test tall_enough == true
            # Doc-coordinate of the tall block's top, measured while pinned at
            # the bottom (the node is guaranteed rendered here — far away the
            # virtual scroller may detach it and rects would read zero).
            node_top_doc = Float64(TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                const node = chat.cache.get(chat.totalCount - 1);
                return node.getBoundingClientRect().top - c.getBoundingClientRect().top + c.scrollTop;
            })()"""))
            # Park far up first (follow off), then scroll DOWN to a position
            # with the block's top half a viewport above the visible bottom:
            # a pixel IS visible, but the gap exceeds one viewport → no
            # re-engage, and a further small downward step doesn't either.
            scroll_up_as_user!()
            @test follow_mode() == false
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = $(node_top_doc) - c.clientHeight / 2;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            # Sample the zone preconditions AFTER refresh has re-rendered the
            # window at the new position (the block is partially visible now,
            # so the helper must see a connected node).
            sleep(0.3)
            over_cap = TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                const gap = c.scrollHeight - c.scrollTop - c.clientHeight;
                return !chat.lastMessageFullyOutOfView() && gap > c.clientHeight;
            })()""")
            @test over_cap == true
            @test follow_mode() == false
            # Small downward step, still beyond the cap → still no re-engage.
            still_over = TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                const chat = c.__bt_chat;
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = c.scrollTop + 30;
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                const gap = c.scrollHeight - c.scrollTop - c.clientHeight;
                return !chat.lastMessageFullyOutOfView() && gap > c.clientHeight;
            })()""")
            @test still_over == true
            for _ in 1:5
                @test follow_mode() == false
                sleep(0.1)
            end
            # Inside the cap the zone applies again: downward to gap ≈ 0.6
            # viewports (block still visible) → re-engage + chase to bottom.
            TK.eval_js(s, """(() => {
                const c = document.querySelector('.bt-messages');
                c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
                c.scrollTop = (c.scrollHeight - c.clientHeight) - Math.floor(c.clientHeight * 0.6);
                c.dispatchEvent(new Event('scroll', {bubbles: true}));
                return true;
            })()""")
            @test TK.wait_for(s, "re-engaged once inside the viewport cap",
                "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4) == true
            @test TK.wait_for(s, "settled to bottom after capped re-engage",
                """(() => {
                    const c = document.querySelector('.bt-messages');
                    return Math.round(c.scrollHeight - c.scrollTop - c.clientHeight) < 50;
                })()"""; timeout = 4) == true
        end

        # ── 8. No JS errors during the whole exercise ───────────────────────
        @test isempty(TK.js_errors(s))
    end
end
