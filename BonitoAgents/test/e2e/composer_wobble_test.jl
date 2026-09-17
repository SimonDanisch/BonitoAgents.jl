# Black-box e2e: typing in a MULTI-LINE composer must not disturb the chat.
#
# Exactly two handlers run per keystroke on the composer:
#   1. the inline `oninput` (chat.jl) — `style.height='auto'`, read
#      `scrollHeight`, write `min(scrollHeight, 120)px`
#   2. `onCmdInput` (bonitoagents.js) — a regex on the value, then `acClose()`,
#      which clears an array and removes an absent class. No layout.
#
# (1) is worth pinning down. For a <textarea>, `height:'auto'` is the rows=1
# height, NOT the content height, so the write really does collapse the box to
# its 64px min-height before the measured height goes back on. Reading
# `scrollHeight` between the two writes forces a synchronous layout, so that
# collapse is a real layout state once per character.
#
# What this item measured: it is not an OBSERVABLE one. Both writes land in the
# same task, layout is committed once, and a ResizeObserver on `.bt-messages`
# sees nothing — 0 callbacks over 10 keystrokes with the composer multi-line and
# well above its min-height. The composer also never shrinks while the text only
# grows, and the transcript never moves on a keystroke that didn't resize it.
#
# So the per-keystroke cost that IS real is the forced reflow, not a visible
# resize. Phone-sized because that is where the wobble was reported; the window
# is restored at the end (shared browser, like layout_fixes_test).
@testitem "e2e:composer_wobble" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # Interleave tool rows so the text events don't coalesce into one bubble —
    # we need a transcript that actually overflows.
    function wobble_agent(prompt)
        occursin("seed", lowercase(prompt)) || return [TK.text("echo: $(prompt)")]
        evs = Any[]
        for i in 1:30
            push!(evs, TK.text("marker bubble number $(i) — a short line of prose"))
            push!(evs, TK.tool(kind = "read", title = "probe tool $(i)", id = "wob-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    s.agent_fn[] = wobble_agent

    pid = TK.new_chat(s; title = "Wobble")
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    TK.send_message(s, "seed please")
    @test TK.wait_for(s, "seeded bubbles rendered",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).length >= 5";
        timeout = 60) == true
    @test TK.wait_for(s, "transcript overflows",
        "(() => { const c=[...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent); return !!c && c.scrollHeight > c.clientHeight + 400; })()";
        timeout = 20) == true

    TK.set_window_size(s, 390, 780)
    sleep(1.5)
    @test TK.eval_js(s, "window.innerWidth") <= 480

    # One sample: the composer's height, and the transcript position expressed
    # content-true (the top-visible bubble + its offset from the viewport top),
    # so a spacer rewrite that preserves the reading position does not count as
    # movement and a real shift does.
    SAMPLE = """(() => {
        const c  = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const ta = document.querySelector('$(P).bt-text-input');
        const st = c.scrollTop;
        let top = null;
        const nodes = [...c.querySelectorAll('.bt-user-msg,.bt-agent-msg,.bt-tool-msg')]
            .filter(n => n.offsetParent).sort((a,b) => a.offsetTop - b.offsetTop);
        for (const n of nodes) {
            if (n.offsetTop + n.offsetHeight > st + 4) {
                top = {text: (n.innerText||'').replace(/\\s+/g,' ').slice(0, 40),
                       off: Math.round(n.offsetTop - st)};
                break;
            }
        }
        return { composerH: Math.round(ta.getBoundingClientRect().height),
                 scrollTop: Math.round(st),
                 top };
    })()"""

    TYPE_ONE = """(() => {
        const ta = document.querySelector('$(P).bt-text-input');
        ta.focus();
        ta.value = ta.value + 'x';
        ta.dispatchEvent(new Event('input', {bubbles: true}));
        return true;
    })()"""

    # What does the messages container SEE during a keystroke? Sampling between
    # keystrokes only ever shows the settled height. The auto-resize collapses
    # the textarea to its rows=1/min-height box, forces a layout by reading
    # scrollHeight, then writes the real height back — so a ResizeObserver is
    # the only way to observe the intermediate state.
    setup_ro = TK.eval_js(s, """(() => {
        const c  = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const ta = document.querySelector('$(P).bt-text-input');
        window.__wobRO = [];
        window.__wobObs = new ResizeObserver(es => {
            for (const e of es) window.__wobRO.push(Math.round(e.contentRect.height));
        });
        if (!c || !ta) return { ok: false, hasC: !!c, hasTa: !!ta };
        window.__wobObs.observe(c);
        // Three lines: multi-line, but under the 120px cap so the box really
        // sits above its 64px min-height and has room to collapse.
        ta.focus();
        ta.value = ['first line of the draft','second line of the draft','third line'].join(String.fromCharCode(10));
        ta.dispatchEvent(new Event('input', {bubbles: true}));
        return { ok: true };
    })()""")
    @info "RO probe setup" setup_ro
    sleep(0.8)
    TK.eval_js(s, "window.__wobRO = []; true")
    multi_h = TK.eval_js(s, "Math.round(document.querySelector('$(P).bt-text-input').getBoundingClientRect().height)")
    for _ in 1:10
        TK.eval_js(s, TYPE_ONE)
        sleep(0.12)
    end
    ro = TK.eval_js(s, "window.__wobRO")
    TK.eval_js(s, "window.__wobObs.disconnect(); true")
    @info "container heights the ResizeObserver saw over 10 keystrokes" composer=multi_h observations=ro

    @testset "typing does not resize the messages container" begin
        # The composer height is unchanged across these 10 keystrokes (no line
        # was added), so the transcript's box must never change either. Every
        # entry here is one ResizeObserver callback, and each one runs
        # `sizeTail()` + a tail chase in the real handler.
        @test multi_h > 70            # genuinely above the 64px min-height
        @test isempty(ro)
    end

    # Type from EMPTY, one character at a time, across several wrap boundaries.
    #
    # Not a pre-filled 12-line draft: past the 120px cap `min(scrollHeight, 120)`
    # clamps to a constant and the box is trivially stable. The reported regime
    # is BELOW the cap, where each keystroke re-runs `height:'auto'` → measure →
    # write, and `overflow-y:auto` can put a 6px scrollbar in (or out of) the
    # content box between two measurements — which re-wraps the text and changes
    # the very height being measured.
    samples = Any[]
    for _ in 1:110
        TK.eval_js(s, TYPE_ONE)
        sleep(0.06)
        push!(samples, TK.eval_js(s, SAMPLE))
    end
    hs = [Int(x["composerH"]) for x in samples]
    @info "composer heights while typing" first=hs[1] last=hs[end] distinct=sort(unique(hs))

    # Non-vacuity: if the composer never resized, everything below passes for
    # the wrong reason (wrong viewport, input event not wired, text too short).
    @test length(unique(hs)) >= 2
    @test maximum(hs) > minimum(hs) + 10

    @testset "the composer never shrinks while the text only grows" begin
        # A textarea whose content strictly grows can only need MORE height.
        # A height that goes back down means the two measurements disagreed
        # about the same text — the oscillation the user sees as a wobble,
        # since every one of these resizes the transcript beside it.
        drops = [(i, hs[i - 1], hs[i]) for i in 2:length(hs) if hs[i] < hs[i - 1]]
        isempty(drops) || @info "composer SHRANK while typing" count=length(drops) first_three=first(drops, min(3, length(drops)))
        @test isempty(drops)
    end

    @testset "a keystroke that doesn't resize the composer doesn't move the chat" begin
        moved = Tuple{Int,Any,Any}[]
        for i in 2:length(samples)
            a, b = samples[i - 1], samples[i]
            a["composerH"] == b["composerH"] || continue   # a real resize may move it
            a["top"] === nothing && continue
            b["top"] === nothing && continue
            same = a["top"]["text"] == b["top"]["text"] &&
                   abs(Int(a["top"]["off"]) - Int(b["top"]["off"])) <= 1
            same || push!(moved, (i, a, b))
        end
        isempty(moved) || @info "transcript moved on a no-resize keystroke" count=length(moved) first=moved[1]
        @test isempty(moved)
    end

    TK.set_window_size(s, 1280, 800)
    sleep(1.0)
    s.agent_fn[] = S.default_agent
end
