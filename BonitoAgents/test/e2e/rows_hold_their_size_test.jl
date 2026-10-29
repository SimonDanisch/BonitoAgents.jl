# A row keeps its height when what it shows is swapped, so nothing around it
# moves (and the transcript has nothing to correct for):
#
#   * A live app scrolled far out of view is frozen to a snapshot (the
#     keep-alive limit, `spillApp`). The snapshot used to come in at its own
#     size, an empty box with a Reload button, or the canvas at its pixel size,
#     twice its size on screen on a HiDPI display.
#   * A picture attached to a user message shows as a thumbnail of one height,
#     known before the picture loads. It used to grow from 40 px to the
#     picture's height when the bytes arrived.
#
# Recorded from the moment each row is in the page: every height it has.
@testitem "e2e:rows_hold_their_size" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    env = abspath(joinpath(@__DIR__, "..", "evalenv"))
    napps = 10
    appcode(i) = """using Bonito
        App(() -> DOM.div(DOM.span("SPILL-APP $(i)"); style = "padding:24px;height:90px;background:#eef"))"""
    s.agent_fn[] = p -> begin
        occursin("apps", p) || return [TK.text("ok"), TK.end_turn()]
        evs = Any[]
        for i in 1:napps
            push!(evs, TK.bt_eval(appcode(i); env_path = env, id = "spill-app-$(i)"))
            for j in 1:6     # separate rows (consecutive texts coalesce)
                push!(evs, TK.text("filler $(i).$(j): between the apps, so they scroll out of view"))
                push!(evs, TK.tool(kind = "read", title = "filler $(i).$(j)", id = "spill-fill-$(i)-$(j)"))
            end
        end
        push!(evs, TK.end_turn())
        evs
    end
    pid = TK.new_chat(s; title = "RowsHoldSize")
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    MSGS = "document.querySelector($(TK.json(P * ".bt-messages")))"

    TK.send_message(s, "show me the apps")
    @test TK.wait_for(s, "the last app live", "!!$MSGS?.querySelector('[data-msg-id*=\"spill-app-$(napps)\"]')?.textContent.includes('SPILL-APP $(napps)')";
                      timeout = 180) == true
    @test TK.wait_for(s, "the turn over", "!$MSGS.querySelector('.bt-busy-active')"; timeout = 60) == true
    sleep(1)
    # Every height of every app row and user row from now on, a row from when
    # it is in the page. (While its eval ran, a card grew with its code, output
    # and result: live content at the bottom, followed, not what this is about.)
    TK.eval_js(s, """(() => {
        const m = $MSGS;
        window.__heights = {};
        const ro = new ResizeObserver(es => { for (const e of es) {
            const id = e.target.__probeId;
            const h = Math.round(e.borderBoxSize[0].blockSize);
            if (h > 0) (window.__heights[id] = window.__heights[id] || []).push(h);
        } });
        const seen = new WeakSet();
        let n = 0;
        const scan = () => {
            for (const r of m.querySelectorAll('.bt-tool-msg[data-msg-id*="spill-app-"], .bt-user-msg')) {
                if (seen.has(r)) continue;
                seen.add(r);
                // One key per row node: a queued message is another node than the sent one.
                r.__probeId = r.classList.contains('bt-user-msg')
                    ? 'user-' + (++n) + '-' + (r.textContent || '').slice(0, 40) : r.dataset.msgId;
                ro.observe(r);
            }
        };
        new MutationObserver(scan).observe(m, {childList: true, subtree: true});
        scan();
        return true; })()""")


    # Up through every app and back down: each one is seen, then left far out
    # of view, which is what the keep-alive limit freezes.
    x, y = TK.eval_js(s, "(() => { const r = $MSGS.getBoundingClientRect(); return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)]; })()")
    wheel(dy) = ECT.send_input(s.browser[], "{type: 'mouseWheel', x: $x, y: $y, deltaX: 0, deltaY: $dy, canScroll: true, hasPreciseScrollingDeltas: true}")
    for _ in 1:600
        wheel(120); sleep(0.016)
        TK.eval_js(s, "$MSGS.__bt_chat.block.plo === 0 && $MSGS.scrollTop <= 1") == true && break
    end
    for _ in 1:600
        wheel(-120); sleep(0.016)
        TK.eval_js(s, "$MSGS.__bt_chat.atBottom()") == true && break
    end
    sleep(1)
    state = TK.eval_js(s, "(() => { const ch = $MSGS.__bt_chat; return [$MSGS.querySelectorAll('[data-bt-app]').length, ch.appLru.length, ch.visibleApps.size, $MSGS.querySelectorAll('[data-bt-spilled]').length]; })()")
    @info "apps: [live rows, kept alive, visible, frozen]" state
    @test TK.eval_js(s, "$MSGS.querySelectorAll('[data-bt-spilled]').length") > 0   # some were frozen

    # The picture: 300×200, so it would have grown the row.
    TK.eval_js(s, """(() => {
        const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="#c84"/></svg>';
        const file = new File([svg], 'holds-size.svg', {type: 'image/svg+xml'});
        $MSGS.__bt_chat.attachAddBlob(file, file.type, file.name);
        return true; })()""")
    @test TK.wait_for(s, "the picture queued", "document.querySelectorAll($(TK.json(P * ".bt-attachment-thumb"))).length === 1"; timeout = 10) == true
    TK.send_message(s, "a picture that holds its size")
    @test TK.wait_for(s, "the picture loaded", """(() => {
        const b = [...$MSGS.querySelectorAll('.bt-user-msg')].find(e => (e.textContent || '').includes('holds its size'));
        const img = b && b.querySelector('.bt-user-att-img');
        return !!img && img.complete && img.naturalWidth === 300; })()"""; timeout = 30) == true
    sleep(0.5)

    heights = TK.eval_js(s, "window.__heights")
    apps = [(k, v) for (k, v) in heights if occursin("spill-app-", k)]
    @test length(apps) == napps
    for (k, v) in apps
        @test maximum(v) - minimum(v) <= 1
        maximum(v) - minimum(v) <= 1 || @info "an app row changed height" row = k heights = unique(v)
    end
    # The sent message's row (the last one with that text; a queued one came first).
    pics = sort([(parse(Int, split(k, '-')[2]), v) for (k, v) in heights if occursin("holds its size", k)])
    @test !isempty(pics)
    pic = last(pics)[2]
    @test maximum(pic) - minimum(pic) <= 1
    @test TK.eval_js(s, """[...$MSGS.querySelectorAll('.bt-user-att-img')].pop().getBoundingClientRect().height""") ≈ 120 atol = 1

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
