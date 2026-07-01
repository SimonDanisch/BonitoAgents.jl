# Defense-in-depth for the streaming FINALIZE path (client-side, bonitoagents.js).
#
# Two hardening invariants a streamed agent bubble must hold once its
# authoritative `agent_final` has landed:
#
#   1. FINALIZED bubbles ignore late/duplicate chunks. A `chunk` that arrives
#      AFTER `onAgentFinal` (a trailing throttle flush that raced the final, or a
#      duplicate frame for the same id) must NOT repaint the older, shorter
#      cumulative html — the bubble keeps the FINAL text. `onAgentFinal` marks the
#      node `__btFinal`; `appendChunk` early-returns on a finalized node.
#
#   2. An EMPTY final still clears the pending stream. When `agent_final` carries
#      no html (an empty agent message), the node is blanked AND finalized, so a
#      pending throttled flush can't resurrect the streamed text into what should
#      be an empty bubble.
#
# We can't emit a POST-final chunk through the mock agent (its `end` event drives
# the final and the wire is FIFO), so we drive the client handlers DIRECTLY via
# `eval_js` against the live chat instance — exactly the ordering the audit
# flagged (a stray `chunk` reaching `appendChunk` after `onAgentFinal`).

@testitem "e2e:chat_finalize_guard" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # A normal streamed turn: several chunks accumulate into one agent bubble.
    function agent_script(prompt)
        occursin("stream", lowercase(prompt)) &&
            return [TK.text("chunk-a "), TK.text("chunk-b "), TK.end_turn()]
        return [TK.text("Echo: $(prompt)"), TK.end_turn()]
    end
    s.agent_fn[] = agent_script

    pid = TK.new_chat(s; title = "FinalizeGuard")
    TK.open_chat(s, pid)
    TK.wait_for(s, "input live",
        "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 15)

    # The visible pane's chat instance (soak server keeps prior panes hidden in
    # the DOM, so scope to the one that's actually shown). `.bt-messages` carries
    # `__bt_chat` (the BonitoChat) — the test-inspection hook set in `connect`.
    CHAT = "([...document.querySelectorAll('.bt-messages')].find(c => c.offsetParent !== null).__bt_chat)"
    # The last agent bubble in the visible pane (the one we just streamed into).
    VISBUB = "([...document.querySelectorAll('.bt-agent-msg')].filter(b => b.offsetParent !== null).pop())"

    @testset "finalized bubble ignores a late/duplicate chunk" begin
        TK.send_message(s, "stream please")
        # Wait for the streamed bubble to hold both chunks (turn complete).
        @test TK.wait_for(s, "streamed bubble",
            "(() => { const b = $(VISBUB); return !!b && (b.innerText||'').includes('chunk-a') && (b.innerText||'').includes('chunk-b'); })()";
            timeout = 30) == true

        # Drive the finalize + a stray LATE chunk directly against the client.
        # `onAgentFinal` paints the authoritative html and finalizes the node;
        # the following `appendChunk` is the hazard — a stale, shorter cumulative
        # payload for the SAME id that must be dropped.
        got = TK.eval_js(s, """(() => {
            const chat = $(CHAT);
            const bub  = $(VISBUB);
            const id   = bub.dataset.msgId;
            if (!id) return 'NO_ID';
            chat.onAgentFinal({ id, html: '<p>FINAL-AUTHORITATIVE</p>' });
            // Stray late/duplicate chunk for the finalized id (older + shorter).
            chat.appendChunk({ id, html: '<p>STALE-chunk-a </p>' });
            return (bub.innerText || '').trim();
        })()""")
        # The bubble keeps the FINAL text — the late chunk was ignored.
        @test occursin("FINAL-AUTHORITATIVE", String(got))
        @test !occursin("STALE", String(got))

        # And a SECOND stray chunk (duplicate) is still ignored (flag is sticky).
        got2 = TK.eval_js(s, """(() => {
            const chat = $(CHAT);
            const bub  = $(VISBUB);
            chat.appendChunk({ id: bub.dataset.msgId, html: '<p>STALE-again</p>' });
            return (bub.innerText || '').trim();
        })()""")
        @test occursin("FINAL-AUTHORITATIVE", String(got2))
        @test !occursin("STALE", String(got2))
    end

    @testset "empty final clears the pending stream and finalizes" begin
        TK.send_message(s, "stream again")
        @test TK.wait_for(s, "second streamed bubble",
            "(() => { const b = $(VISBUB); return !!b && (b.innerText||'').includes('chunk-b'); })()";
            timeout = 30) == true

        # Simulate a throttled stream payload still pending (a flush that hasn't
        # fired), then land an EMPTY final. The bubble must end up EMPTY + final,
        # NOT resurrected to the stale streamed text — and a subsequent stray
        # chunk stays ignored.
        got = TK.eval_js(s, """(() => {
            const chat = $(CHAT);
            const bub  = $(VISBUB);
            const id   = bub.dataset.msgId;
            if (!id) return 'NO_ID';
            // Arm a pending throttled stream payload (as a live stream would).
            chat._applyStreamHtml(bub, '<p>PENDING-stale-stream</p>');
            // Empty final: no html. Must blank + finalize (clearing the pending).
            chat.onAgentFinal({ id, html: '' });
            // Stray late chunk after the empty final — must be dropped.
            chat.appendChunk({ id, html: '<p>LATE-after-empty</p>' });
            return { text: (bub.innerText || '').trim(), fin: !!bub.__btFinal };
        })()""")
        @test got["fin"] == true
        @test strip(String(got["text"])) == ""
    end

    @testset "final for an evicted/missing node falls back to the DOM" begin
        TK.send_message(s, "stream fallback")
        @test TK.wait_for(s, "third streamed bubble",
            "(() => { const b = $(VISBUB); return !!b && (b.innerText||'').includes('chunk-b'); })()";
            timeout = 30) == true

        # Mirror `onSummaryFinal`'s DOM fallback: an `agent_final` whose id is NOT
        # in `nodeById` (evicted / id mismatch) must not be silently dropped — it
        # paints the last agent bubble by DOM query. Use a bogus id so the
        # `nodeById` lookup misses and the fallback path runs.
        got = TK.eval_js(s, """(() => {
            const chat = $(CHAT);
            const bub  = $(VISBUB);
            const bogus = bub.dataset.msgId + '-not-a-real-id';
            chat.onAgentFinal({ id: bogus, html: '<p>FALLBACK-FINAL</p>' });
            return (bub.innerText || '').trim();
        })()""")
        @test occursin("FALLBACK-FINAL", String(got))
    end

    @test isempty(TK.js_errors(s))
end
