# Typing in a growing draft must preserve the transcript's reading position.
# Native field sizing avoids the old collapse/measure/restore cycle; these
# rendered-geometry checks also cover real wrap boundaries and viewport changes.
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

    # Every scroll of the transcript from the resize on.
    TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent);
        window.__narrowT0 = performance.now();
        window.__narrowLast = null;
        c.addEventListener('scroll', () => { window.__narrowLast = performance.now(); });
        return true;
    })()""")
    TK.set_window_size(s, 390, 780)
    sleep(1.5)
    @test TK.eval_js(s, "window.innerWidth") <= 480

    # The narrower column wraps each row taller than the height stored for it
    # at the old width. The row at the edge of the render window then entered
    # and left on every scroll event, each time moving the pinned bottom by the
    # difference: the transcript scrolled twice a frame, for good.
    @testset "the pinned transcript comes to rest after the window narrows" begin
        @test TK.wait_for(s, "a second without a scroll",
            "performance.now() - (window.__narrowLast ?? window.__narrowT0) > 1000"; timeout = 15) == true
        @test TK.eval_js(s, """(() => {
            const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent);
            return c.__bt_chat.followMode && c.scrollHeight - c.scrollTop - c.clientHeight <= 1;
        })()""") == true
    end

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
        visualViewport.dispatchEvent(new Event('resize'));
        visualViewport.dispatchEvent(new Event('resize'));
        return true;
    })()"""

    # Observe the transcript's viewport during edits that keep the same number
    # of lines. Native sizing should leave it alone.
    setup_ro = TK.eval_js(s, """(() => {
        const c  = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
        const ta = document.querySelector('$(P).bt-text-input');
        window.__wobRO = [];
        window.__wobObs = new ResizeObserver(es => {
            for (const e of es) window.__wobRO.push(Math.round(e.contentRect.height));
        });
        if (!c || !ta) return { ok: false, hasC: !!c, hasTa: !!ta };
        window.__wobObs.observe(c);
        visualViewport.dispatchEvent(new Event('resize'));
        // Three lines sit above the minimum height, below the growth cap.
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
        @test multi_h > 70            # above the one-line minimum
        @test isempty(ro)
    end

    # Keep typing through wrap boundaries below the cap, where a real line
    # addition should grow the composer without ever shrinking it.
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
