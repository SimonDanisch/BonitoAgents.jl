# Black-box port of the legacy `test/electron/test_chat_cancel.jl`.
#
# The stop feature is critical UX: while the agent is streaming a long response
# the user MUST be able to interrupt it. There are TWO trigger paths and they
# must both work:
#
#   1. Click the `.bt-stop-btn` button in the input row.
#   2. Press ESC anywhere (no element needs focus) — the chat installs a
#      document-level `keydown` listener.
#
# Both ship `{type:'cancel'}` over the chat's comm Observable, which the Julia
# side turns into an ACP `session/cancel` notification (`handle_command!
# (::CancelCommand)` → `ACP.cancel!`). A graceful cancel makes the agent wind
# the turn down and resolve the prompt with `stopReason:"cancelled"`; the
# `prompt!` consumer stops coalescing, `run_turn!`'s `finally` clears
# `busy_active`, and `close(::TurnState)` SEALS the partial agent bubble into
# the store instead of dropping it. The invariants the user feels:
#
#   * the streaming bubble STOPS growing (cancel actually reached the agent),
#   * the partial bubble is KEPT (sealed) — not deleted — and finalized
#     (its `.bt-stream-text` span is replaced by rendered markdown), and
#   * a follow-up message after the cancel completes a fresh turn normally
#     ("stop, then ask something else").
#
# The legacy test drove the Julia state machine headless against a custom
# `MockTransport` and read `model.busy_active` / `model.msgs_store` directly.
# Here we prove the SAME invariants BLACK-BOX, end to end on a real
# `dev_server` (real worker + real ACP JSON-RPC over a real mock-agent
# subprocess + real websockets + the live DOM renderer), asserting ONLY on the
# rendered DOM.
#
# To get a deterministic mid-stream window we make the mock stream many short
# `text` chunks separated by small `delay`s, so the turn stays live for a few
# seconds. The mock honors `session/cancel` mid-stream (its stdin reader runs
# concurrently with the streaming turn, flips a `cancelled` flag, and the
# dispatcher-mode prompt loop / sliced `delay` bail out and resolve the prompt
# with `stopReason:"cancelled"`).

@testitem "e2e:chat_cancel" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # A "story" prompt streams CHUNKS short tagged chunks, each followed by a
    # small delay — long enough (≈ CHUNKS * DELAY_MS ms) that the test can land
    # a cancel mid-stream. Anything else gets a one-shot fast reply (used for
    # the post-cancel follow-up so it completes immediately).
    # The stream must stay live LONG ENOUGH that the cancel lands before the last
    # chunk — the window is `~CHUNKS * DELAY_MS` minus the harness's round-trip
    # latency to detect mid-stream + ship the cancel. (The actual flake that bit
    # us was NOT the window — it was a global `.bt-stop-btn` resolving to a stale
    # pane, fixed by the `P` pane-scoping below; once the cancel reaches the right
    # chat it lands in well under a second. We still keep a generous window so the
    # cancel comfortably outraces a slow round-trip under nworkers=4 load.) This
    # does NOT slow the test: a successful cancel ends the turn early (after
    # `part2`-ish), so the full duration only runs if the cancel never lands.
    const CHUNKS   = 40
    const DELAY_MS = 400

    function agent_script(prompt)
        p = lowercase(prompt)
        if occursin("story", p)
            evs = Any[]
            for i in 1:CHUNKS
                push!(evs, TK.text("part$(i) "))
                push!(evs, TK.delay(DELAY_MS))
            end
            push!(evs, TK.end_turn())
            return evs
        else
            return [TK.text("followup-done: $(prompt)"), TK.end_turn()]
        end
    end
    s.agent_fn[] = agent_script

    pid = TK.new_chat(s; title = "Cancel")
    TK.open_chat(s, pid)
    # PANE-SCOPE every interaction to THIS chat's pane. SharedServer keeps other
    # test items' chat panes mounted (display:none but still in the DOM), so a
    # GLOBAL `.bt-stop-btn` / `.bt-busy` selector can resolve to a STALE pane.
    # `TK.click`/`querySelector` (unlike `TK.set_input`) do NOT visibility-filter,
    # so the cancel click landed on the wrong (idle) chat's stop button: the
    # streaming chat was never cancelled, ran to completion (`part<CHUNKS>`), and
    # "stream stopped early" failed. This reproduced deterministically even at
    # nworkers=1 once other pane-creating items had run first — it is NOT a
    # timing/load flake. Pin all selectors to this pane via `data-pane-pid`.
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    TK.wait_for(s, "input live",
        "[...document.querySelectorAll('$(P).bt-text-input')].some(e=>e.offsetParent)"; timeout = 15)

    # One cancel scenario: send a long story, wait until we're genuinely
    # mid-stream (the streaming bubble exists AND has accrued a couple of
    # chunks), fire `trigger_cancel`, then assert the four invariants. Returns
    # nothing; asserts inline.
    function run_cancel(label, trigger_cancel)
        # Both send + stop buttons are always in the DOM (CSS toggles which is
        # visible by busy state); the legacy test clicks `.bt-stop-btn`
        # directly. Make sure the chat's input + stop button are present and
        # the ESC handler is wired (`_onEscapeKey` is the last listener
        # `_setupInputs` attaches) before we drive anything.
        @test TK.wait_for(s, "$(label): chat mounted",
            "!!document.querySelector('$(P).bt-text-input') && !!document.querySelector('$(P).bt-stop-btn')";
            timeout = 15) == true
        @test TK.wait_for(s, "$(label): ESC handler wired",
            "(() => { const m = document.querySelector('$(P).bt-messages'); " *
            "return !!m && !!m.__bt_chat && typeof m.__bt_chat._onEscapeKey === 'function'; })()";
            timeout = 15) == true

        # Count agent bubbles already visible so we can refer to "the new one"
        # this turn produces. `VIS` = bubbles in the visible pane.
        VIS = "[...document.querySelectorAll('$(P).bt-agent-msg')].filter(e=>e.offsetParent!==null)"
        n_before = TK.eval_js(s, "$(VIS).length")
        n_before = n_before === nothing ? 0 : Int(n_before)

        # Pane-scoped send: `set_input` already visibility-filters, but pin the
        # send button too so we never click a stale pane's `.bt-send-btn`.
        TK.set_input(s, "$(P).bt-text-input", "tell me a long story please")
        TK.click(s, "$(P).bt-send-btn")

        # Genuinely mid-stream: a NEW agent bubble has accrued a couple of chunks
        # (`part2 `) AND the turn is STILL generating (`.bt-busy-active`). NB:
        # detect "still streaming" via the BUSY indicator, NOT a `.bt-stream-text`
        # span — that span is re-rendered away between chunks as the markdown is
        # re-parsed, so it's absent for almost the whole stream (it is NOT a
        # reliable streaming signal). `part2 ` (trailing space) unambiguously
        # means chunk 2 — it never matches `part20`.
        @test TK.wait_for(s, "$(label): streaming bubble mid-stream",
            "(() => { const b = $(VIS); " *
            "if (b.length <= $(n_before)) return false; " *
            "const busy = document.querySelector('$(P).bt-busy'); " *
            "const generating = !!busy && busy.classList.contains('bt-busy-active'); " *
            "return generating && (b[b.length - 1].innerText||'').includes('part2 '); })()";
            timeout = 30) == true

        # Snapshot the partial text right before we cancel.
        partial = TK.eval_js(s, "(($(VIS)[$(VIS).length - 1] || {}).innerText || '')")
        partial = strip(String(partial === nothing ? "" : partial))
        @test occursin("part2 ", partial)
        # It must be a PARTIAL — the full stream would contain the last chunk
        # (`part<CHUNKS>`); we cancelled well before that.
        @test !occursin("part$(CHUNKS)", partial)

        # Fire the cancel (stop-button click or ESC keydown).
        trigger_cancel()

        # The turn ENDS (sealed): cancel resolves the prompt with
        # `stopReason:"cancelled"`, `run_turn!`'s `finally` clears `busy_active`,
        # so the busy indicator drops `bt-busy-active`. (This replaces the old
        # `.bt-stream-text === null` "sealed" check — that span is transient and
        # not a dependable signal.)
        @test TK.wait_for(s, "$(label): turn ended (busy cleared)",
            "(() => { const el = document.querySelector('$(P).bt-busy'); " *
            "return !!el && !el.classList.contains('bt-busy-active'); })()";
            timeout = 20) == true

        # The partial bubble is KEPT (not deleted) AND did NOT regrow to the full
        # completion — the cancel stopped the stream early (no `part<CHUNKS>`).
        @test TK.wait_for(s, "$(label): partial text retained, stream stopped early",
            "(() => { const b = $(VIS); " *
            "if (b.length <= $(n_before)) return false; " *
            "const t = (b[b.length - 1].innerText || ''); " *
            "return t.includes('part2 ') && !t.includes('part$(CHUNKS)'); })()";
            timeout = 20) == true

        # FOLLOW-UP WORKS: after the cancel the chat is in a clean state and a
        # new message completes a fresh turn end to end. The follow-up agent
        # reply is a distinct, fast one-shot we can match on.
        n_after_cancel = TK.eval_js(s, "$(VIS).length")
        n_after_cancel = n_after_cancel === nothing ? 0 : Int(n_after_cancel)
        TK.set_input(s, "$(P).bt-text-input", "$(label) ping")
        TK.click(s, "$(P).bt-send-btn")
        @test TK.wait_for(s, "$(label): follow-up turn completes after cancel",
            "(() => { const b = $(VIS); " *
            "if (b.length <= $(n_after_cancel)) return false; " *
            "return (b[b.length - 1].innerText || '').includes('followup-done: $(label) ping'); })()";
            timeout = 30) == true
        return nothing
    end

    @testset "BonitoAgents cancel mid-stream (stop button + ESC, sealed partial, follow-up)" begin
        @testset "stop button cancels mid-stream" begin
            run_cancel("stop-click", () -> TK.click(s, "$(P).bt-stop-btn"))
        end

        @testset "ESC key cancels mid-stream (no focus required)" begin
            # Dispatch ESC on document — must work without anything focused,
            # the "user's reading the streaming output and hits ESC" case.
            run_cancel("esc-key", () -> TK.eval_js(s, """
                document.dispatchEvent(new KeyboardEvent('keydown',
                    {key: 'Escape', bubbles: true})); true
            """))
        end
    end

    @test isempty(TK.js_errors(s))
end
