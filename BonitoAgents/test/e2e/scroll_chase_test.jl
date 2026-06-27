# Black-box port of the legacy Tier-2g electron test (test_scroll_chase.jl).
#
# The legacy test covered four distinct auto-follow bugs by poking internal
# state (chat_emit, msgs_store, __bt_chat.dispatch({type:'busy_start'})). This
# port keeps the ONE load-bearing invariant the user reported — "the chat keeps
# chasing the bottom while I'm pinned there" — and proves it BLACK-BOX on a real
# `dev_server`, driven purely through the browser. No make_state, no chat_emit,
# no msgs_store; history is seeded by actually sending user messages, and the
# streaming growth is produced by an agent scenario that holds the turn open and
# streams many chunks into ONE bubble (each chunk = an `appendChunk` that grows
# the bubble height → fires the ResizeObserver → must re-scroll).
#
# Invariant under test (the chase): while the user sits AT the bottom (within the
# AT_BOTTOM threshold), as content/height grows the viewport must stay pinned —
# the gap `scrollHeight - scrollTop - clientHeight` must stay below threshold
# every step, NOT lag behind. This is exactly the ResizeObserver-driven re-scroll
# the legacy "streaming many chunks keeps us pinned at the tail" section guarded.
#
# Coverage (each section = one behavioral assertion against BROWSER state — the
# UI's own client state via `.bt-messages.__bt_chat.*` + scroll geometry, which
# is fair game; it's the rendered DOM the user sees, not a Julia internal):
#   1. Overflowing content mounts pinned at the bottom, followMode true.
#   2. Streaming a long burst WHILE pinned keeps the gap under threshold the
#      whole way (the chase): poll the gap as height grows, then re-assert.
#   3. The last agent bubble's bottom edge stays within the viewport (visible).
#   4. The at-bottom threshold holds: a single tall bubble arriving while pinned
#      does NOT disengage follow — we stay pinned, gap < threshold.
#   5. No JS errors during the whole exercise.
@testitem "e2e:scroll_chase" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # AT_BOTTOM_PX-style threshold the chat's atBottom() uses (generous — the
    # legacy test settled on <200 because a single 80-100px bubble must not flip
    # us off-bottom). Same gap formula as follow_pill / scroll_persist.
    AT_BOTTOM_PX = 200

    # A tall fenced code block renders as a <pre> that preserves all its lines,
    # so the messages container genuinely overflows (plain text collapses
    # newlines and wouldn't give us a real scroll range). Mirrors follow_pill.
    CODE = "```\n" * join(["history row $(i) of generated output" for i in 1:90], "\n") * "\n```"

    # Agent scenarios, swapped per phase via `agent_fn`:
    #   "seed …"  → a tall code block (overflows the viewport, gives a bottom to
    #                chase).
    #   "stream …"→ hold the turn open briefly, then stream MANY short chunks
    #                into ONE agent bubble. Each chunk is a distinct `appendChunk`
    #                → grows the bubble height → fires the ResizeObserver. While
    #                we're pinned at the bottom, the chase must re-scroll every
    #                growth so the gap never opens up.
    #   "tall …"  → a single very tall block arriving in one shot (the legacy
    #                "single 80-100px bubble must not flip wasAtBottom" case, scaled
    #                up): tests the at-bottom threshold holds as height jumps.
    #   else      → a plain echo.
    function chase_agent(prompt)
        p = lowercase(prompt)
        if occursin("seed", p)
            return [TK.text(CODE)]
        elseif occursin("stream", p)
            evs = Any[TK.delay(400)]
            for i in 1:40
                push!(evs, TK.text("Streaming chunk $(i): lorem ipsum dolor sit amet, consectetur adipiscing elit. "))
            end
            return evs
        elseif occursin("tall", p)
            block = "```\n" * join(["tail line $(i)" for i in 1:40], "\n") * "\n```"
            return [TK.text(block)]
        else
            return [TK.text("echo: $(prompt)")]
        end
    end
    s.agent_fn[] = chase_agent

    # ── browser-state probes (read the UI's own client state + scroll geometry)──
    follow_mode() = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.followMode")
    # Math.round throughout — Chromium returns fractional scrollHeight/clientHeight
    # under subpixel layout; rounding keeps the Julia-side Int() comparisons clean.
    GAP_JS = "Math.round((() => { const c=document.querySelector('.bt-messages'); return c.scrollHeight - c.scrollTop - c.clientHeight; })())"
    gap()    = Int(TK.eval_js(s, GAP_JS))
    height() = Int(TK.eval_js(s, "Math.round(document.querySelector('.bt-messages').scrollHeight)"))
    # The chase settles within ~200ms, but an offscreen/headless window throttles
    # rAF to ~1 Hz, so a fixed sleep races the throttled chase. Poll the gap.
    at_bottom() = TK.wait_for(s, "pinned at bottom",
        "($GAP_JS) < $AT_BOTTOM_PX"; timeout = 8) == true

    @testset "scroll chase: stay pinned while content grows (black-box)" begin
        # Fresh chat on the shared server so we don't inherit a neighbor's state.
        pid = TK.new_chat(s; title = "ScrollChase")

        # ── 1. Overflowing content mounts pinned at the bottom ──────────────
        @testset "overflowing content lands pinned at the bottom" begin
            TK.send_message(s, "seed history please")
            @test TK.wait_for(s, "code block rendered",
                "!!document.querySelector('.bt-agent-msg pre')"; timeout = 60) == true
            # The container genuinely overflows (real scroll range to chase).
            @test TK.wait_for(s, "viewport overflows",
                "(() => { const c=document.querySelector('.bt-messages'); return !!c && c.scrollHeight > c.clientHeight + 300; })()"; timeout = 10) == true
            # Follow mode pins the newest content at the bottom.
            @test at_bottom()
            @test follow_mode() == true
        end

        # ── 2. Streaming many chunks while pinned keeps us at the tail ──────
        # The core chase invariant: as the streaming bubble grows (ResizeObserver
        # firing on every chunk), the viewport must keep chasing the bottom so the
        # gap NEVER opens past threshold. We sample the gap repeatedly DURING the
        # stream while height climbs, then re-assert at the end.
        @testset "streaming burst stays pinned the whole way (the chase)" begin
            h0 = height()
            TK.send_message(s, "stream a long burst")

            # Wait for the bubble to start (held-back delay then chunks land).
            @test TK.wait_for(s, "stream started",
                "document.querySelector('.bt-messages').__bt_chat.totalCount >= 2"; timeout = 20) == true

            # Sample the gap several times as the height climbs. At each sample the
            # chase must have re-scrolled us back under threshold — if any sample
            # shows a runaway gap, the chase lagged behind the growing content.
            grew = false
            for _ in 1:12
                # Give the chase a poll-window to settle this growth step under the
                # throttled rAF, then assert it landed back at the tail.
                @test TK.wait_for(s, "gap under threshold during stream",
                    "($GAP_JS) < $AT_BOTTOM_PX"; timeout = 6) == true
                if height() > h0 + 100
                    grew = true
                end
                sleep(0.15)
            end
            # The content actually grew (otherwise the chase assertion is vacuous).
            @test grew == true

            # Final settle + assert: pinned at the tail and follow still engaged.
            @test at_bottom()
            @test follow_mode() == true
            @test gap() < AT_BOTTOM_PX

            # ── 3. The last agent bubble's bottom edge is within the viewport ──
            # Not just the numeric gap — the user must actually SEE the tail bubble.
            @test TK.eval_js(s, """(() => {
                const bubbles = document.querySelectorAll('.bt-agent-msg');
                if (bubbles.length === 0) return false;
                const last = bubbles[bubbles.length - 1];
                const r = last.getBoundingClientRect();
                const c = document.querySelector('.bt-messages').getBoundingClientRect();
                // The last bubble's bottom should be at or above the container's
                // bottom (visible), within a generous sub-pixel tolerance.
                return r.bottom <= c.bottom + 50;
            })()""") == true
        end

        # ── 4. At-bottom threshold: a tall bubble arriving while pinned does
        #       NOT disengage the chase ─────────────────────────────────────
        # Legacy bug 3: atBottom() threshold was too tight, so a single tall
        # message flipped wasAtBottom=false and disengaged the chase. While we're
        # pinned, a one-shot tall block must keep us pinned (height jumps, gap
        # stays under threshold, followMode stays true).
        @testset "tall message while pinned keeps the chase engaged" begin
            # Confirm we start this phase pinned.
            @test at_bottom()
            @test follow_mode() == true
            h_before = height()

            TK.send_message(s, "tall block now")
            # The tall block renders as a <pre> containing "tail line N". Assert
            # THAT pre is present — not a count of >= 2 pres: virtual scroll only
            # keeps the visible window in the DOM, and once the tall block lands at
            # the bottom the seed's far-up <pre> is windowed out, so the two are
            # never in the DOM at the same time.
            @test TK.wait_for(s, "tall block rendered",
                "[...document.querySelectorAll('.bt-agent-msg pre')].some(p => (p.innerText||'').includes('tail line'))"; timeout = 20) == true
            # Height jumped (the tall block landed)...
            @test TK.wait_for(s, "height grew from tall block",
                "Math.round(document.querySelector('.bt-messages').scrollHeight) > $(h_before + 100)"; timeout = 10) == true
            # ...and the chase kept us pinned across the jump, NOT disengaged.
            @test at_bottom()
            @test follow_mode() == true
            @test gap() < AT_BOTTOM_PX
        end

        # ── 5. No JS errors during the whole exercise ───────────────────────
        @test isempty(TK.js_errors(s))
    end
end
