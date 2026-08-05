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
#      false; pill still hidden (nothing unread yet).
#   4. new chunks while disengaged → pill visible + unreadCount > 0, and the
#      chunks DON'T yank follow back on.
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
    follow_mode() = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.followMode")
    unread()      = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.unreadCount")
    pill_visible() = TK.eval_js(s, """(() => {
        const el = document.querySelector('.bt-new-msg-pill');
        return el ? el.classList.contains('bt-new-msg-pill-visible') : false;
    })()""")

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

        # ── 3. User scrolls to top → followMode off, pill stays hidden ──────
        @testset "scroll-to-top disengages follow mode" begin
            scroll_up_as_user!()
            @test follow_mode() == false
            # Nothing new has arrived yet, so the pill is still hidden.
            @test pill_visible() == false
        end

        # ── 4. New chunks while disengaged → pill visible, unread > 0 ────────
        @testset "new content while disengaged surfaces the pill" begin
            # Trigger a burst. The agent holds the turn ~1.6s before streaming,
            # so re-assert the scrolled-up position right before the chunks land
            # (the user's own send doesn't move us — followMode is already off).
            TK.send_message(s, "burst while away")
            scroll_up_as_user!()       # ensure we're parked at the top as it streams
            # Pill must surface once the held-back chunks arrive.
            @test TK.wait_for(s, "pill visible",
                "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible') !== null"; timeout = 6) == true
            # The chunks didn't yank us back into follow mode...
            @test follow_mode() == false
            # ...and unread counted them.
            @test Int(unread()) > 0
        end

        # ── 5. Click pill → followMode on, scroll to bottom, pill hides ─────
        @testset "clicking the pill re-engages, hides pill, jumps to bottom" begin
            TK.eval_js(s, "document.querySelector('.bt-new-msg-pill.bt-new-msg-pill-visible').click()")
            @test TK.wait_for(s, "followMode re-engaged",
                "document.querySelector('.bt-messages').__bt_chat.followMode === true"; timeout = 4) == true
            @test TK.wait_for(s, "pill hidden",
                """(() => {
                    const el = document.querySelector('.bt-new-msg-pill');
                    return !el || !el.classList.contains('bt-new-msg-pill-visible');
                })()"""; timeout = 4) == true
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
            sleep(0.8)
            @test follow_mode() == false
            # The user's own send registered as unread → pill stays visible.
            @test pill_visible() == true
            # ScrollTop shouldn't have jumped to the bottom (generous tolerance
            # for any scroll-anchoring shift as new bottom nodes get added).
            scroll_top_after = TK.eval_js(s, "document.querySelector('.bt-messages').scrollTop")
            @test abs(Int(round(scroll_top_after)) - Int(round(scroll_top_before))) < 200
        end

        # ── 8. No JS errors during the whole exercise ───────────────────────
        @test isempty(TK.js_errors(s))
    end
end
