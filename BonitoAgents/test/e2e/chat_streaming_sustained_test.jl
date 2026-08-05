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
            # (first + last chunk present, in order). Gate on the k-th agent
            # bubble (1-based) carrying its turn's last chunk so we don't race
            # the next send against a still-streaming bubble. With CHUNKS chunks
            # per bubble and no tool boundaries the bubbles coalesce, so the
            # k-th `.bt-agent-msg` is exactly turn k's bubble.
            # Gate on the last chunk WITHOUT a trailing space: `innerText`
            # collapses/trims the final whitespace, so the emitted "t<k>c<N> "
            # renders as "…t<k>c<N>" — checking for the trailing space never
            # matches (the chunks DO all arrive; this is a rendering-trim quirk).
            TK.wait_for(s, "turn $(k) bubble complete",
                "(() => { const b = $(VIS)[$(k - 1)]; " *
                "return !!b && (b.innerText||'').includes('t$(k)c$(CHUNKS)'); })()";
                timeout = 60)
        end

        # All TURNS bubbles are live (10 user + 10 agent nodes is far below the
        # virtual-scroll window, so nothing is evicted).
        @test TK.wait_for(s, "all $(TURNS) agent bubbles present",
            "$(VIS).length >= $(TURNS)"; timeout = 30) == true

        for k in 1:TURNS
            # Read the k-th agent bubble's text. Normalise whitespace: innerText
            # may collapse/trim around chunk boundaries, so compare on the
            # single-space-joined token stream.
            raw = TK.eval_js(s,
                "(($(VIS)[$(k - 1)] || {}).innerText || '')")
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
    end

    @test isempty(TK.js_errors(s))
end
