# Black-box port of the legacy `test/electron/test_chat_streaming_sustained.jl`.
#
# The legacy test drove the Julia state machine headless (MockTransport) and
# asserted the two structural streaming invariants the chat must hold across
# MANY turns:
#
#   1. WIRE-ORDER preservation: within a turn, the streamed chunks land in the
#      exact order they were emitted (no reordering).
#   2. NO CROSS-TURN BLEED: a turn's chunks accumulate into its OWN agent bubble
#      only — they never leak into a neighbouring turn's bubble.
#
# Here we prove the SAME invariants BLACK-BOX, end to end on a real `dev_server`
# (real worker + real ACP JSON-RPC + real websockets + the live DOM renderer).
# For each user prompt the mock agent streams many numbered text chunks
# `"t<turn>c1 ", "t<turn>c2 ", …`. The TestKit DSL accumulates the chunks of one
# turn into ONE `.bt-agent-msg` bubble (multiple `TK.text(...)` in a single
# turn = streamed chunks of one message), and each `send_message` is a separate
# turn = a separate bubble. So we can read each bubble's `innerText` and assert:
#
#   * it equals the EXACT in-order concatenation of that turn's chunks
#     (`"t<k>c1 t<k>c2 … t<k>cN "`) — wire order preserved, nothing dropped, and
#   * it contains ONLY its own turn's tag (`"t<k>c"` and no `"t<j>c"`, j≠k) —
#     no cross-turn bleed.
#
# REDUCED COUNTS vs. the legacy 20×200: each `send_message` round-trips a real
# mock-agent subprocess, so we drive 10 turns × 30 chunks. That's still ample to
# exercise ordering across hundreds of streamed chunks and to prove no bleed
# across 10 distinct bubbles, while keeping the suite to a couple of minutes.
#
# VIRTUAL SCROLL AWARENESS: the pane virtualises — parked at the bottom, the
# render window is only `viewport + OVERSCAN·EST_HEIGHT` px deep, and bubbles
# above it are EVICTED from the DOM (that's the designed contract; the
# virtual_scroll suite asserts head-eviction at the tail explicitly). Ten
# 30-chunk bubbles overflow that window, so the earliest turns' bubbles are
# legitimately gone from the DOM by turn ~10. Therefore:
#   * the per-turn "streaming finished" gate keys on the NEWEST visible agent
#     bubble (follow mode pins it in the window), never on an absolute index —
#     an absolute `VIS[k-1]` shifts as soon as one early bubble evicts, and
#     the turn-10 gate then waits forever on a 10th bubble that can't exist
#     (the exact 60 s "turn N bubble complete" soak flake this replaced);
#   * the final order/no-bleed verification SCROLLS each turn's bubble back
#     into the window first (scroll-up → msgs.request → server re-render),
#     which additionally proves the invariants hold across eviction +
#     re-materialisation, not just for the live-streamed nodes.

@testitem "e2e:chat_streaming_sustained" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    const TURNS  = 10    # legacy: 20 — reduced; each turn is a real subprocess round-trip
    const CHUNKS = 30    # legacy: 200 — reduced; still hundreds of chunks total

    # "turn <k>" → CHUNKS numbered text chunks, all tagged with the turn number
    # so a bubble can be matched to exactly one turn. Streaming several
    # `TK.text(...)` in ONE turn makes the chat coalesce them into a single
    # agent bubble — the streamed-message accumulation path under test.
    function agent_script(prompt)
        m = match(r"turn (\d+)", lowercase(prompt))
        m === nothing && return [TK.text("Echo: $(prompt)"), TK.end_turn()]
        k = parse(Int, m.captures[1])
        evs = Any[TK.text("t$(k)c$(i) ") for i in 1:CHUNKS]
        push!(evs, TK.end_turn())
        return evs
    end
    s.agent_fn[] = agent_script

    # Exact in-order concatenation a turn-k bubble must equal.
    expected(k) = join(("t$(k)c$(i) " for i in 1:CHUNKS))

    pid = TK.new_chat(s; title = "SustainedStream")
    TK.open_chat(s, pid)
    TK.wait_for(s, "input live",
        "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 15)

    # The soak server keeps PRIOR chats' panes in the DOM (hidden), so a global
    # `.bt-agent-msg` index would point at a stale bubble. Scope every bubble
    # query to the VISIBLE pane (`offsetParent !== null`) — only THIS chat's
    # pane is shown — so `[k-1]` indexes turn k's bubble, not a neighbour's.
    VIS = "[...document.querySelectorAll('.bt-agent-msg')].filter(b => b.offsetParent !== null)"

    @testset "BonitoAgents sustained streaming (order + no cross-turn bleed)" begin
        for k in 1:TURNS
            TK.send_message(s, "turn $(k)")
            # The turn is done once its bubble holds the FULL concatenation
            # (first + last chunk present, in order). Gate on the NEWEST visible
            # agent bubble carrying this turn's last chunk: follow mode pins the
            # streaming bubble inside the render window, while earlier turns'
            # bubbles may already be virtualised away (see header) — so an
            # absolute index would drift, but the last visible bubble is always
            # the live turn's. With CHUNKS chunks per bubble and no tool
            # boundaries the chunks coalesce into that one bubble.
            # Gate on the last chunk WITHOUT a trailing space: `innerText`
            # collapses/trims the final whitespace, so the emitted "t<k>c<N> "
            # renders as "…t<k>c<N>" — checking for the trailing space never
            # matches (the chunks DO all arrive; this is a rendering-trim quirk).
            TK.wait_for(s, "turn $(k) bubble complete",
                "(() => { const v = $(VIS); const b = v[v.length - 1]; " *
                "return !!b && (b.innerText||'').includes('t$(k)c$(CHUNKS)'); })()";
                timeout = 60)
        end

        # Nothing was LOST to virtualisation: the client-side totalCount mirrors
        # the full history (TURNS user + TURNS agent messages), even though only
        # a window of those is materialised in the DOM at any moment. (`__bt_chat`
        # is the chat's own client-side state hung off the `.bt-messages` node —
        # same introspection contract the virtual_scroll suite uses.)
        @test TK.wait_for(s, "totalCount mirrors the full history",
            "(() => { const c = document.querySelector('.bt-messages').__bt_chat; " *
            "return !!c && c.totalCount >= $(2 * TURNS); })()"; timeout = 30) == true

        # Walk the WHOLE conversation top-to-bottom, materialising each turn's
        # bubble through the virtual scroller (scroll-up → msgs.request →
        # server-rendered range) before asserting on it. This proves the two
        # invariants on every turn — including the ones whose live-streamed
        # nodes were evicted at the tail — and exercises the re-materialisation
        # path on top. First disengage follow mode + park at the top (the
        # virtual_scroll idiom: programmatic scrollTop changes fire no 'scroll'
        # event in Electron's offscreen renderer, so dispatch one).
        TK.eval_js(s, """
            (() => { const n = document.querySelector('.bt-messages');
                const ch = n.__bt_chat;
                if (ch) { ch.setFollowMode(false); if (ch._cancelPendingScroll) ch._cancelPendingScroll(); }
                n.scrollTop = 0; n.dispatchEvent(new Event('scroll'));
                return true; })()""")

        for k in 1:TURNS
            # Bring turn k's bubble into the render window: if it's not visible
            # yet, nudge the scroller one step down per poll (turns are in
            # chronological order, so an ascending walk only ever scrolls down).
            # "t<k>c1" is unique to turn k's bubble (no other turn carries it).
            @test TK.wait_for(s, "turn $(k) bubble materialised",
                "(() => { const v = $(VIS); " *
                "if (v.some(b => (b.innerText||'').includes('t$(k)c1'))) return true; " *
                "const n = document.querySelector('.bt-messages'); " *
                "n.scrollTop = Math.min(n.scrollTop + n.clientHeight * 0.6, n.scrollHeight); " *
                "n.dispatchEvent(new Event('scroll')); return false; })()";
                timeout = 30) == true

            # Read turn k's bubble text. Normalise whitespace: innerText may
            # collapse/trim around chunk boundaries, so compare on the
            # single-space-joined token stream.
            raw = TK.eval_js(s,
                "(() => { const b = $(VIS).find(b => (b.innerText||'').includes('t$(k)c1')); " *
                "return b ? (b.innerText||'') : ''; })()")
            got = strip(replace(String(raw === nothing ? "" : raw), r"\s+" => " "))
            want = strip(replace(expected(k), r"\s+" => " "))

            # 1. WIRE ORDER: bubble text equals the exact in-order concatenation.
            @test got == want

            # 2. NO CROSS-TURN BLEED: bubble k carries ONLY turn k's tag.
            @test occursin("t$(k)c1 ", expected(k))            # sanity on the tag scheme
            @test occursin("t$(k)c", got)                      # its own turn is present
            for j in 1:TURNS
                j == k && continue
                @test !occursin("t$(j)c", got)                 # no other turn leaked in
            end
        end

        # Leave the shared pane the way a suite found it: follow mode on,
        # parked at the bottom (the next soak item drives this same pane).
        TK.eval_js(s, """
            (() => { const ch = document.querySelector('.bt-messages').__bt_chat;
                if (ch) { ch.setFollowMode(true); ch.scrollToBottom(); }
                return true; })()""")
    end

    @test isempty(TK.js_errors(s))
end
