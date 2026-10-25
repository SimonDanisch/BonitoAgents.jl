# The rail's thumb shows where the reader is in every painted frame, also while
# rows above the reader grow and the transcript keeps the reader in place.
#
# A row growing above the viewport (a picture arriving, a body rendering) is
# laid out before the transcript corrects the scroll position for it, and the
# frame's scroll handler ran in between: it placed the thumb for the content as
# it stood uncorrected, some messages earlier. The correction's own scroll event
# comes a frame later, so for one frame at every such row the thumb jumped back
# and forth: the rail "flickered" while scrolling up a long chat whose pictures
# had not been measured yet.
#
# Pictures of their own size, never shown before, so each grows when it loads;
# scrolling up from the bottom brings older rows in above the reader. Sampled
# after each paint: the thumb against where it belongs for what is on screen.
@testitem "e2e:rail_follows_anchor" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    dir = mktempdir()
    n = 100
    pics = map(1:n) do i
        f = joinpath(dir, "pic$(i).svg")
        h = 180 + 7 * (i % 23)
        write(f, """<svg xmlns="http://www.w3.org/2000/svg" width="320" height="$(h)">""" *
                 """<rect width="320" height="$(h)" fill="#$(string(0x335577 + 37i; base = 16, pad = 6)[end-5:end])"/></svg>""")
        f
    end
    fill = Any[]
    for i in 1:n
        push!(fill, TK.text("row $(i): a picture follows"),
              TK.tool(; kind = "other", tool_name = "bt_show", title = "pic$(i).svg",
                      content = [TK.text_block("shown: $(pics[i]) (image/svg+xml, 200B)")], id = "rail-pic-$(i)"))
    end
    push!(fill, TK.end_turn())
    s.agent_fn[] = p -> occursin("fill", p) ? fill : [TK.text("ok"), TK.end_turn()]
    pid = TK.new_chat(s; title = "RailAnchor")
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    MSGS = "document.querySelector($(TK.json(P * ".bt-messages")))"
    TK.send_message(s, "fill it")
    @test TK.wait_for(s, "the last picture", "!!$MSGS?.querySelector('[data-msg-id*=\"rail-pic-$(n)\"] img.bt-media')"; timeout = 90) == true
    # Reopened, so the transcript loads from its tail and older rows come in
    # above the reader while scrolling up.
    TK.eval_js(s, "location.reload(); true")
    @test TK.wait_for(s, "the chat back",
        "!!document.querySelector('.bt-chatpane[data-pane-pid=\"$(pid)\"][data-bt-settled]') && !!$MSGS?.__bt_chat";
        timeout = 60) == true
    @test TK.wait_for(s, "older rows not loaded yet", "$MSGS.__bt_chat.plo > 0"; timeout = 10) == true

    # In each frame as painted: the thumb, and where it belongs for the row at
    # the top of the view. Also counted: the transcript's corrections for rows growing
    # above, so the test knows the case it is about happened.
    TK.eval_js(s, """(() => {
        const m = $MSGS, ch = m.__bt_chat;
        const thumb = m.parentElement.querySelector('.bt-rail-thumb');
        const rail = m.parentElement.querySelector('.bt-rail');
        const desc = Object.getOwnPropertyDescriptor(Element.prototype, 'scrollTop');
        window.__fix = 0;
        Object.defineProperty(m, 'scrollTop', { configurable: true, get() { return desc.get.call(this); },
            set(v) { desc.set.call(this, v); if ((new Error().stack || '').includes('ResizeObserver')) window.__fix++; } });
        window.__frames = []; window.__on = true;
        const sample = () => {
            const [first] = ch.visibleSpan();
            if (first < 0) return;
            const node = ch.cache.get(ch.order[first]);
            const into = node.offsetHeight > 0 ? Math.min(1, Math.max(0, (m.scrollTop - node.offsetTop) / node.offsetHeight)) : 0;
            // The rail's own ends: the last message at the bottom, the first at the top.
            const f = ch.atTail() && ch.atBottom() ? 1 : ch.plo <= 0 && m.scrollTop <= 1 ? 0 :
                Math.min(1, (ch.seqPos(ch.order[first]) + into) / Math.max(1, ch.seqLength() - 1));
            // As drawn: the thumb rides an animation (`placeThumb`), so its
            // computed transform, not its style attribute.
            const t = getComputedStyle(thumb).transform;
            const shown = t === 'none' ? 0 : new DOMMatrixReadOnly(t).m42;
            window.__frames.push([shown, Math.round(f * (rail.clientHeight - thumb.offsetHeight))]);
        };
        // Sampled from an observer made after the transcript's: observers run
        // after layout and before paint, in the order they were made, so this
        // sees the frame as it will be painted, the transcript's corrections
        // included (a later task could change the page before a timer ran).
        const beat = document.createElement('div');
        beat.style.cssText = 'position:fixed;left:0;top:0;height:1px;width:1px;visibility:hidden';
        document.body.appendChild(beat);
        let w = 1;
        new ResizeObserver(() => { if (window.__on) sample(); }).observe(beat);
        const tick = () => { if (!window.__on) return; w = 3 - w; beat.style.width = w + 'px'; requestAnimationFrame(tick); };
        requestAnimationFrame(tick);
        return true; })()""")
    x, y = TK.eval_js(s, "(() => { const r = $MSGS.getBoundingClientRect(); return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)]; })()")
    for _ in 1:400
        ECT.send_input(s.browser[], "{type: 'mouseWheel', x: $x, y: $y, deltaX: 0, deltaY: 120, canScroll: true, hasPreciseScrollingDeltas: true}")
        sleep(0.016)
        TK.eval_js(s, "$MSGS.__bt_chat.plo === 0 && $MSGS.scrollTop <= 1") == true && break
    end
    frames = TK.eval_js(s, "(() => { window.__on = false; return window.__frames; })()")
    off = [fr for fr in frames if abs(fr[1] - fr[2]) > 2]
    @test length(frames) > 50
    @test TK.eval_js(s, "window.__fix") > 0          # rows grew above the reader
    @test isempty(off)                                # and the thumb never showed it
    isempty(off) || @info "frames with the thumb elsewhere than the reader" count = length(off) examples = first(off, 5)

    TK.eval_js(s, "location.reload(); true")         # drops the probes
    @test TK.wait_for(s, "the chat back after the probes", "!!$MSGS?.__bt_chat"; timeout = 60) == true
    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
    rm(dir; recursive = true, force = true)
end
