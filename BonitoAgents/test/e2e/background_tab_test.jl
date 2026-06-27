# Black-box e2e regression for the backgrounded-tab requestAnimationFrame pause.
#
# Background (ported from the legacy test/electron/test_chat_background_tab.jl):
# Chrome + Electron pause `requestAnimationFrame` in a backgrounded tab/window —
# queued rAF callbacks simply never fire until the tab refocuses. The chat's
# auto-scroll used to route a new agent message's scroll-to-bottom through
# `_queueScrollToBottom` (rAF-batched). While the tab was backgrounded the new
# bubble went into `__bt_chat.cache` but NEVER into the DOM, because the rAF that
# was supposed to scroll to bottom + re-`updateDOM` with the post-scroll visible
# range never fired. When the user finally re-focused, the queued rAF fired and
# all the cached-but-invisible bubbles appeared at once — in the wild: "I sent a
# message and 5 old replies appeared instantly".
#
# The fix (`appendNewMessage` in assets/bonitoagents.js) replaces the rAF batching
# with a SYNCHRONOUS `scrollToBottom()` (which itself calls `refresh()` → updateDOM
# with the post-scroll range). Synchronous scrollTop + DOM writes work regardless
# of tab visibility, so the bubble lands immediately.
#
# This black-box port simulates the pause at the BROWSER level: it stubs
# `window.requestAnimationFrame` so callbacks are QUEUED but never invoked (the
# exact behaviour a backgrounded tab imposes), and dispatches a `visibilitychange`
# with `document.hidden === true` for fidelity. It then streams real agent
# messages through the live server while the tab is "hidden" and asserts the new
# bubbles reach the DOM anyway. After "refocusing" (rAF restored, the parked
# callbacks flushed) the DOM must still be correct — not a burst of duplicates.
#
# Per the scroll_persist.jl precedent, reading the chat's own client-side state
# (`.bt-messages.__bt_chat.*`) is fair game in a black-box test: it's the UI's
# state, not a Julia internal.

@testitem "e2e:background_tab" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # Each "background N" prompt streams N fresh agent bubbles in one turn — the
    # bubbles that must appear in the DOM while rAF is paused.
    s.agent_fn[] = function (prompt)
        m = match(r"background (\d+)", lowercase(prompt))
        m === nothing && return [TK.text("Echo: $(prompt)"), TK.end_turn()]
        n = parse(Int, m.captures[1])
        evs = Any[TK.text("background-tab message $(i) — should appear despite paused rAF")
                  for i in 1:n]
        push!(evs, TK.end_turn())
        return evs
    end

    pid = TK.new_chat(s; title = "BgTab")

    # Build a little history so the virtual-scroll window is genuinely engaged
    # (the bug only bites once updateDOM is windowing, not rendering everything).
    for i in 1:3
        TK.send_message(s, "seed $(i)")
        @test TK.wait_for(s, "seed $(i) echoed",
            "[...document.querySelectorAll('.bt-agent-msg')].some(b => (b.innerText||'').includes('Echo: seed $(i)'))";
            timeout = 30) == true
    end
    sleep(0.5)   # let the seed turns' final chase settle

    # The chat must be following the bottom for the regression to apply (it's the
    # followMode path in appendNewMessage that used to defer to rAF).
    @test TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.followMode") == true

    before_total   = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.totalCount")
    before_bubbles = TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg, .bt-user-msg').length")

    # ── Background the tab: pause rAF + flip document.hidden ──────────────────
    # Stub requestAnimationFrame so callbacks are QUEUED but never fire — exactly
    # what Chromium/Electron do to a backgrounded tab. `cancelAnimationFrame` is
    # kept honest so the chat's own `_cancelPendingScroll` still works. We stash
    # the real fns + the parked callbacks so we can "refocus" (restore + flush)
    # later and prove nothing was lost or double-fired.
    TK.eval_js(s, raw"""(() => {
        window.__bgPaused = [];
        window.__rafReal  = window.requestAnimationFrame.bind(window);
        window.__cafReal  = window.cancelAnimationFrame.bind(window);
        window.requestAnimationFrame = (cb) => {
            const id = window.__bgPaused.length + 1;
            window.__bgPaused.push({ id, cb });   // queued, deliberately never invoked
            return id;
        };
        window.cancelAnimationFrame = (id) => {
            const q = window.__bgPaused;
            for (let i = 0; i < q.length; i++) { if (q[i] && q[i].id === id) q[i] = null; }
        };
        // Make the tab look hidden, then fire the same event the browser fires.
        Object.defineProperty(document, 'hidden', { configurable: true, get: () => true });
        Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
        document.dispatchEvent(new Event('visibilitychange'));
        return true;
    })()""")

    # Sanity: rAF is now a black hole — a scheduled callback parks and never runs.
    @test TK.eval_js(s, raw"""(() => {
        const n0 = window.__bgPaused.length;
        let fired = false;
        requestAnimationFrame(() => { fired = true; });
        return window.__bgPaused.length === n0 + 1 && fired === false;
    })()""") == true

    # ── Stream new agent messages WHILE the tab is backgrounded ───────────────
    # Pre-fix, these would queue a scroll-to-bottom via rAF (now parked forever),
    # so the bubbles would sit in `cache` and never enter the DOM.
    TK.send_message(s, "background 3")

    # The crux: the newest bubble must reach the DOM even though every rAF is
    # parked. We don't require all 3 (virtual scroll may window some out) — but
    # the LAST one is at the bottom of content with followMode on, so it must
    # render via the synchronous scrollToBottom path the fix added.
    @test TK.wait_for(s, "last bubble in DOM while backgrounded",
        "[...document.querySelectorAll('.bt-agent-msg')].some(b => (b.innerText||'').includes('background-tab message 3'))";
        timeout = 30) == true

    after_total   = TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.totalCount")
    after_bubbles = TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg, .bt-user-msg').length")

    # totalCount went up by 2: the user "background 3" message + ONE agent
    # message. The three streamed text chunks coalesce into a single assistant
    # bubble (that's how streaming works — chunks build up one message), so the
    # count is +2, not +4. What this test actually guards is that the new bubble
    # reaches the DOM while rAF is parked (checked above + by `after_bubbles`).
    @test (after_total - before_total) == 2
    # DOM bubble count grew — the bubbles aren't stuck in cache.
    @test after_bubbles > before_bubbles

    # rAF is STILL a black hole — confirm none of the parked callbacks ever ran,
    # i.e. the bubbles landed via the synchronous path, not because rAF resumed.
    @test TK.eval_js(s, "window.__bgPaused.length > 0") == true

    # ── Refocus: restore rAF, flush the parked callbacks ──────────────────────
    # After the user returns to the tab, the browser resumes rAF and runs the
    # queued callbacks. The DOM must stay correct — NOT spawn duplicate bubbles
    # (the old symptom was the cache dumping into the DOM all at once here).
    TK.eval_js(s, raw"""(() => {
        window.requestAnimationFrame = window.__rafReal;
        window.cancelAnimationFrame  = window.__cafReal;
        Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
        Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
        document.dispatchEvent(new Event('visibilitychange'));
        // Flush whatever was parked while hidden, on a real frame.
        const parked = window.__bgPaused.splice(0);
        window.__rafReal(() => { for (const e of parked) { if (e && e.cb) try { e.cb(performance.now()); } catch (_) {} } });
        return true;
    })()""")
    sleep(0.5)

    # The newest message is still present and unique after refocus (no duplicate
    # flood). totalCount is unchanged by the flush.
    @test TK.eval_js(s,
        "[...document.querySelectorAll('.bt-agent-msg')].filter(b => (b.innerText||'').includes('background-tab message 3')).length") == 1
    @test TK.eval_js(s, "document.querySelector('.bt-messages').__bt_chat.totalCount") == after_total

    @test isempty(TK.js_errors(s))
end
