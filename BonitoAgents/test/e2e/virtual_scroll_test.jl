# Black-box port of the legacy `test/electron/test_virtual_scroll.jl`.
#
# The legacy test seeded 200 messages directly into a `ChatModel.msgs_store`
# and asserted that the chat's VIRTUAL-SCROLL windowing keeps only a small
# slice of those messages live in the DOM at once: scrolling fetches the next
# slice via `msgs.request` (the `requestRange` round-trip) and evicts the
# off-screen nodes, while `totalCount`/`scrollHeight` still reflect the FULL
# history and nothing is lost.
#
# Here we build that long history BLACK-BOX, by DRIVING the app: a "scroll N"
# agent streams N numbered agent bubbles in ONE turn, each separated by a tiny
# tool-call (a content boundary, so the ACP `text!` coalescer opens a fresh
# `AgentMessage`/`.bt-agent-msg` per chunk instead of merging them all into one
# bubble — see AgentClientProtocol `messages.jl::text!`). The first bubble
# carries the `MSG-FIRST` marker and the last carries `MSG-LAST`, so we can
# prove the head/tail of the history survives a scroll to the top / bottom.
# With N = 120 the single turn materialises ~120 agent bubbles + ~120 tool
# bubbles + the user bubble ≈ 240 message nodes — comfortably more than the
# legacy 200 — yet the windowed DOM stays well under 100 nodes.
#
# All introspection is via the chat's own client-side state hung off the
# `.bt-messages` node (`__bt_chat.totalCount`, `scrollHeight`, the `.bt-*-msg`
# node count, `scrollToBottom`/`setFollowMode`) — that's UI state, not a Julia
# internal — exactly like the scroll_persist suite.

@testitem "e2e:virtual_scroll" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # How many agent bubbles to stream in the one history-building turn. Each is
    # separated by a tool boundary, so the rendered history is ~2*N + 1 message
    # nodes — a "large history" the virtual window must NOT fully materialise.
    N = 120

    # "scroll N" → N numbered agent text bubbles, each fenced off from the next
    # by a one-line tool call so they DON'T coalesce into a single bubble. The
    # first/last carry stable markers we look for at the top/bottom of history.
    function agent_script(prompt)
        m = match(r"scroll (\d+)", lowercase(prompt))
        m === nothing && return [TK.text("Echo: $(prompt)"), TK.end_turn()]
        n = parse(Int, m.captures[1])
        evs = Any[]
        for i in 1:n
            label = i == 1 ? "MSG-FIRST msg 1" :
                    i == n ? "MSG-LAST msg $(i)" : "msg $(i)"
            push!(evs, TK.text(label))
            # A tiny completed tool between bubbles: closes the current agent
            # message (content boundary) so the next text opens a new bubble.
            i == n || push!(evs, TK.tool(; kind = "execute", title = "step $(i)",
                                         content = [TK.text_block("ok $(i)")]))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    s.agent_fn[] = agent_script

    pid = TK.new_chat(s; title = "VirtualScroll")
    TK.open_chat(s, pid)
    TK.wait_for(s, "input live",
        "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 15)

    # The chat object is hung off the `.bt-messages` node by `connect(node, comm)`
    # in bonitoagents.js as `node.__bt_chat = chat`.
    CHAT = "document.querySelector('.bt-messages').__bt_chat"
    # Every rendered chat bubble (user + agent + tool). The virtual window
    # decides how many of these are live in the DOM at a given scroll position.
    MSG_NODES = "document.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg').length"
    # Total messages the long turn produced: 1 user + N agent + (N-1) tools.
    EXPECTED_TOTAL = 1 + N + (N - 1)

    @testset "BonitoAgents virtual scroll (UI-only)" begin

        @testset "Long history streams in; totalCount mirrors the full model" begin
            TK.send_message(s, "scroll $(N)")
            # The whole burst lands in a few seconds; gate generously on the
            # client-side totalCount reaching the full history.
            @test TK.wait_for(s, "full history streamed",
                "(() => { const c=$CHAT; return c && c.totalCount >= $(EXPECTED_TOTAL); })()";
                timeout = 60) == true
            @test Int(TK.eval_js(s, "$CHAT.totalCount")) == EXPECTED_TOTAL
        end

        @testset "Virtual scroll caps the live DOM far below the total" begin
            # Some bubbles must be materialised...
            @test TK.wait_for(s, "some bubbles materialised",
                "$MSG_NODES > 0"; timeout = 10) == true
            sleep(0.5)  # let the initial scroll-to-bottom + ResizeObserver settle
            n_in_dom = Int(TK.eval_js(s, MSG_NODES))
            @info "virtual scroll DOM node count" n_in_dom total = EXPECTED_TOTAL
            # ...but FAR fewer than the ~240 in the history. If windowing broke
            # we'd see all of them; anything well below 100 proves the window
            # kicked in (a ~600px viewport with EST_HEIGHT≈80 + overscan renders
            # on the order of 15-30 nodes).
            @test n_in_dom > 0
            @test n_in_dom < 100
        end

        @testset "Spacers maintain the full virtual scrollHeight" begin
            # bt-spacer-top + visible bubbles + bt-spacer-bottom add up to the
            # full virtual content height (~EXPECTED_TOTAL * EST_HEIGHT). The
            # browser's scrollHeight therefore reflects ALL messages, not just
            # the windowed slice.
            sh = TK.eval_js(s, "document.querySelector('.bt-messages').scrollHeight")
            @info "virtual scrollHeight" sh
            @test isa(sh, Number) && sh >= 8000
        end

        @testset "Initial scroll position parks at the bottom (newest message)" begin
            # follow-mode pins the newest bubble; MSG-LAST should be live and the
            # container parked within ~200px of the bottom.
            @test TK.wait_for(s, "MSG-LAST near the bottom", """
                (() => {
                    const els = document.querySelectorAll('.bt-agent-msg');
                    return Array.from(els).some(e => (e.innerText||'').includes('MSG-LAST'));
                })()
                """; timeout = 20) == true
            @test TK.eval_js(s, """
                (() => { const c = document.querySelector('.bt-messages');
                    return !!c && (c.scrollHeight - (c.scrollTop + c.clientHeight)) < 200; })()
                """) == true
        end

        @testset "Scroll to top materialises the earliest range; head survives" begin
            # Capture the current top-most rendered bubble so we can prove a
            # DIFFERENT (earlier) bubble surfaces after scrolling up.
            top_before = TK.eval_js(s, """
                (() => { const els = document.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg');
                    return els.length > 0 ? (els[0].innerText||'') : ''; })()
                """)
            # Jump to scrollTop = 0 and dispatch a synthetic 'scroll' event: in
            # Electron's offscreen renderer a programmatic `scrollTop = N`
            # changes the value WITHOUT firing 'scroll', so the chat's _onScroll
            # (and its msgs.request range fetch) would never see the jump.
            # First disengage follow-mode + cancel any pending chase: a prior subtest
            # parks at the bottom, and under OSR's real 60fps that chase rAF would
            # otherwise yank scrollTop straight back off 0 before the head renders
            # (the old ~1.5fps path never fired the chase in time to interfere).
            TK.eval_js(s, """
                (() => { const ch = $CHAT, c = document.querySelector('.bt-messages');
                    if (ch) { ch.setFollowMode(false); if (ch._cancelPendingScroll) ch._cancelPendingScroll(); }
                    if (c) { c.scrollTop = 0; c.dispatchEvent(new Event('scroll')); }
                    return true; })()
                """)
            # A different top bubble must surface (a new, earlier range fetched).
            @test TK.wait_for(s, "earlier top bubble after scroll-up", """
                (() => {
                    const els = document.querySelectorAll('.bt-user-msg, .bt-agent-msg, .bt-tool-msg');
                    return els.length > 0 && (els[0].innerText||'') !== $(TK.json(top_before));
                })()
                """; timeout = 10) == true
            # The very first agent bubble (MSG-FIRST) must be present at the top —
            # no message was lost; the head of the history is still reachable.
            @test TK.wait_for(s, "MSG-FIRST visible at top", """
                (() => { const u = document.querySelectorAll('.bt-agent-msg');
                    return Array.from(u).some(e => (e.innerText||'').includes('MSG-FIRST')); })()
                """; timeout = 10) == true
            # Window still bounded even after fetching the top range.
            @test Int(TK.eval_js(s, MSG_NODES)) < 100
            # And the total never changed — scrolling fetches, it never loses.
            @test Int(TK.eval_js(s, "$CHAT.totalCount")) == EXPECTED_TOTAL
        end

        @testset "Scroll back to the bottom; tail survives" begin
            # Drive the chat's own scroll-to-bottom (the path follow-mode uses),
            # then confirm the newest bubble is back and the head bubble evicted.
            TK.eval_js(s, """
                (() => { const c = $CHAT; c.setFollowMode(true); c.scrollToBottom(); return true; })()
                """)
            @test TK.wait_for(s, "MSG-LAST back at the bottom", """
                (() => { const els = document.querySelectorAll('.bt-agent-msg');
                    return Array.from(els).some(e => (e.innerText||'').includes('MSG-LAST')); })()
                """; timeout = 20) == true
            # MSG-FIRST should have been evicted from the live window again — the
            # head is no longer materialised once we're parked at the tail.
            @test TK.wait_for(s, "MSG-FIRST evicted at the bottom", """
                (() => { const u = document.querySelectorAll('.bt-agent-msg');
                    return !Array.from(u).some(e => (e.innerText||'').includes('MSG-FIRST')); })()
                """; timeout = 10) == true
            @test Int(TK.eval_js(s, MSG_NODES)) < 100
            @test Int(TK.eval_js(s, "$CHAT.totalCount")) == EXPECTED_TOTAL
        end
    end

    @test isempty(TK.js_errors(s))
end
