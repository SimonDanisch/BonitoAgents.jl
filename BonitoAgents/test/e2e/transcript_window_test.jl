# The transcript holds one contiguous block of messages, loaded from the newest
# end: a chat opens on its last rows at once, scrolling up loads older rows
# above the reader without moving what they read, the block stays bounded, and
# the rail (a scrollbar by message count) jumps anywhere in the conversation.
#
# The long history is built by DRIVING the app: a "scroll N" agent streams N
# numbered agent bubbles in one turn, each fenced off by a tiny tool call (a
# content boundary, so the ACP `text!` coalescer opens a fresh bubble per
# chunk). The first carries `MSG-FIRST`, the last `MSG-LAST`.

@testitem "e2e:transcript_window" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    N = 150
    TOTAL = 1 + N + (N - 1)          # the user bubble, N agent bubbles, N-1 tools
    MAX_WINDOW = 160                 # bonitoagents.js: rows the block keeps

    function agent_script(prompt)
        m = match(r"scroll (\d+)", lowercase(prompt))
        m === nothing && return [TK.text("Echo: $(prompt)"), TK.end_turn()]
        n = parse(Int, m.captures[1])
        evs = Any[]
        for i in 1:n
            push!(evs, TK.text(i == 1 ? "MSG-FIRST msg 1" : i == n ? "MSG-LAST msg $(i)" : "msg $(i)"))
            i == n || push!(evs, TK.tool(; kind = "execute", title = "step $(i)",
                                         content = [TK.text_block("ok $(i)")]))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    s.agent_fn[] = agent_script

    pid = TK.new_chat(s; title = "TranscriptWindow")
    TK.open_chat(s, pid)
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    C = "document.querySelector($(TK.json(P * ".bt-messages")))"
    CHAT = "$C.__bt_chat"
    ROWS = "$C.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg').length"
    has(text) = "[...$C.querySelectorAll('.bt-agent-msg')].some(e => (e.innerText || '').includes($(TK.json(text))))"
    # The first row whose box reaches into the viewport: its text and its
    # distance from the viewport top.
    TOP_ROW = """(() => { const c = $C;
        for (const e of c.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg')) {
            if (e.offsetParent === null) continue;
            if (e.offsetTop + e.offsetHeight > c.scrollTop + 4)
                return [(e.innerText || '').slice(0, 60), Math.round(e.offsetTop - c.scrollTop)];
        }
        return null; })()"""

    @testset "a long history streams in; the block keeps the newest rows" begin
        TK.send_message(s, "scroll $(N)")
        @test TK.wait_for(s, "the whole turn",
            "(() => { const c = $CHAT; return !!c && c.block.count >= $(TOTAL); })()"; timeout = 60) == true
        @test TK.wait_for(s, "MSG-LAST at the bottom", has("MSG-LAST"); timeout = 20) == true
        @test Int(TK.eval_js(s, ROWS)) <= MAX_WINDOW
        @test TK.eval_js(s, "$CHAT.atBottom()") == true
    end

    @testset "a reopened chat starts from its newest rows and loads no more than it shows" begin
        TK.navigate(s, "/")
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "MSG-LAST", has("MSG-LAST"); timeout = 20) == true
        # The pane arrived with its newest rows; nothing downloads the rest.
        sleep(3)
        @test Int(TK.eval_js(s, ROWS)) < 120
        @test !TK.eval_js(s, has("MSG-FIRST"))
    end

    # Opening a chat re-renders the workspace, which then re-asserted the
    # pane's old scroll offset every frame for 20 frames (seconds in a hidden
    # window, whose frames run at 1 Hz). With the pane there at once, the
    # reader's first scroll landed in that window and was undone.
    @testset "a scroll right after opening is kept" begin
        TK.navigate(s, "/")
        TK.open_chat(s, pid)
        @test TK.wait_for(s, "the newest rows", "!!$CHAT && $CHAT.block.order.length > 0"; timeout = 20) == true
        top = TK.eval_js(s, """(() => { const c = $C, ch = $CHAT;
            ch.setFollowMode(false); ch.cancelPendingScroll();
            c.scrollTop = Math.max(0, c.scrollHeight - c.clientHeight - 400);
            c.dispatchEvent(new Event('scroll'));
            return $TOP_ROW; })()""")
        sleep(2)
        after = TK.eval_js(s, """(() => { const c = $C;
            const e = [...c.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg')]
                .find(e => (e.innerText || '').slice(0, 60) === $(TK.json(top[1])));
            return e ? Math.round(e.offsetTop - c.scrollTop) : null; })()""")
        @test after !== nothing && abs(after - top[2]) <= 1
        @test TK.eval_js(s, "$CHAT.followMode") == false
    end

    @testset "scrolling up reaches the first message without moving what is read" begin
        TK.eval_js(s, "(() => { const c = $CHAT; c.setFollowMode(false); c.cancelPendingScroll(); return true; })()")
        moved = Int[]
        for _ in 1:20
            TK.eval_js(s, has("MSG-FIRST")) && break
            # To the top, what is read there, and the block's first position,
            # in one synchronous step: nothing can load in between. The scroll
            # event is dispatched by hand (the offscreen renderer fires none
            # for a programmatic write); the older rows arrive after it.
            top, plo = TK.eval_js(s, """(() => { const c = $C; c.scrollTop = 0;
                const top = $TOP_ROW, plo = $CHAT.block.plo;
                c.dispatchEvent(new Event('scroll'));
                return [top, plo]; })()""")
            TK.wait_for(s, "older rows", "$CHAT.block.plo < $(plo)"; timeout = 10)
            sleep(0.2)
            # The row that was at the top is still there, at the same spot.
            after = TK.eval_js(s, """(() => { const c = $C;
                const e = [...c.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg')]
                    .find(e => (e.innerText || '').slice(0, 60) === $(TK.json(top[1])));
                return e ? Math.round(e.offsetTop - c.scrollTop) : null; })()""")
            push!(moved, after === nothing ? 9999 : abs(after - top[2]))
            @test Int(TK.eval_js(s, ROWS)) <= MAX_WINDOW
        end
        @test TK.eval_js(s, has("MSG-FIRST")) == true
        @test !isempty(moved) && all(<=(1), moved)
        @test !TK.eval_js(s, has("MSG-LAST"))            # dropped: the block stays bounded
    end

    @testset "the rail names a message and jumps to it" begin
        label = TK.drag_rail!(s, 0.5)
        m = match(r"^Message (\d+) of (\d+)$", label)
        @test m !== nothing
        @test parse(Int, m[2]) == TOTAL
        k = parse(Int, m[1])
        @test abs(k - TOTAL / 2) <= 10
        # Message k (1-based) is store index k-1: odd indices are agent
        # bubbles "msg i" with i = (index + 1) / 2, even ones the tools between.
        want = (k - 1) ÷ 2 + 1
        @test TK.wait_for(s, "the jump", """(() => { const c = $C;
            const shown = [...c.querySelectorAll('.bt-agent-msg')].filter(e => e.offsetParent &&
                e.offsetTop + e.offsetHeight > c.scrollTop && e.offsetTop < c.scrollTop + c.clientHeight)
                .map(e => +((e.innerText || '').match(/msg (\\d+)/) || [0, -1])[1]);
            return shown.some(i => Math.abs(i - $(want)) <= 2); })()"""; timeout = 15) == true
        @test TK.eval_js(s, "$CHAT.followMode") == false
    end

    @testset "a new message waits while history is read; the pill brings it" begin
        TK.send_message(s, "hello there")
        @test TK.wait_for(s, "the jump pill",
            "!!document.querySelector($(TK.json(P * ".bt-new-msg-pill-visible")))"; timeout = 20) == true
        sleep(1)
        @test !TK.eval_js(s, has("Echo: hello there"))
        TK.click(s, P * ".bt-new-msg-pill")
        @test TK.wait_for(s, "the reply at the bottom",
            "$(has("Echo: hello there")) && $CHAT.atBottom()"; timeout = 20) == true
        @test TK.eval_js(s, "$CHAT.followMode") == true
    end

    @testset "Home and End go to the ends of the conversation" begin
        # A press in the transcript (its left padding, clear of every row)
        # gives it the keys and leaves the composer.
        x, y = TK.eval_js(s, "(() => { const r = $C.getBoundingClientRect(); return [Math.round(r.left + 3), Math.round(r.top + r.height / 2)]; })()")
        ctx = s.browser[]
        TK.ECT.send_input(ctx, "{type: 'mouseDown', x: $x, y: $y, button: 'left', clickCount: 1}")
        TK.ECT.send_input(ctx, "{type: 'mouseUp', x: $x, y: $y, button: 'left', clickCount: 1}")
        TK.eval_js(s, "document.activeElement && document.activeElement.blur(); true")
        TK.press_key!(s, "Home")
        @test TK.wait_for(s, "the first message at the top",
            "$(has("MSG-FIRST")) && $C.scrollTop <= 1"; timeout = 15) == true
        @test TK.eval_js(s, "$CHAT.block.plo") == 0
        @test TK.eval_js(s, "$CHAT.followMode") == false
        TK.press_key!(s, "End")
        @test TK.wait_for(s, "the last message at the bottom",
            "$(has("Echo: hello there")) && $CHAT.atBottom()"; timeout = 15) == true
        @test TK.eval_js(s, "$CHAT.followMode") == true
    end

    @test isempty(TK.js_errors(s))
end
