# Force-close is the LAST resort for a genuinely wedged agent, migrated onto the
# TestKit harness (real dev_server, real worker subprocess, real ACP wire, real
# Electron browser; only the agent's behaviour is faked via the `agent=`
# callback). The force-close escalation must be:
#   • never automatic on a timer — that races legitimate cold/resumed cancels
#     (honor latency 6–18s+) and a premature mid-turn teardown leaves an orphaned
#     tool_use that wedges every future resume (a doom loop);
#   • never triggered by an impatient double-click — that's the same trap;
#   • triggered ONLY by a deliberate re-cancel after the agent has had a real
#     chance (≥ CANCEL_ESCALATE_WAIT) and the turn is still busy.
#
# WHAT IS UNIT vs e2e:
#   • The escalation TIMING PREDICATE — "escalate iff a first cancel was stamped,
#     the wait has elapsed, and we're still busy" — is a pure boolean over
#     (first_at, now, busy). That's a direct unit test, no chat/agent/transport.
#   • The user-visible BEHAVIOUR — graceful first cancel (busy stays on a wedged
#     turn), a double-click stays graceful, and a DELIBERATE re-cancel past the
#     wait force-closes (session dies, last_error set) — is agent-driven (needs a
#     real in-flight, wedged turn), so it's a DOM/state e2e against the live model
#     and its real ACP client reached via `s.h.state`.
#
# MIGRATION NOTE: the old fixture was a `MockTransport` whose responder completed
# bring-up then ignored `session/prompt` + `session/cancel` (the shape of a hung
# agent on a live connection). Those fake transports are deleted. We reproduce the
# SAME server-visible shape over the real stack: the mock agent HOLDS the turn
# open with a long `delay` (a plain sleep that does not answer `session/cancel`
# mid-hold — exactly a wedged, non-honoring turn), so the turn stays busy across
# the first cancel + double-click. We then backdate the real client's
# `conn.cancel_at` past CANCEL_ESCALATE_WAIT and re-cancel; the deliberate
# re-cancel force-closes the live ACP client → the wedged loop breaks → busy
# clears, the session is dead, and `last_error` is set. The hold (~15 s) is long
# enough to span the whole escalation sequence while the turn is genuinely held.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, delay, end_turn

# ── Pure unit test: the escalation timing predicate ─────────────────────────
# Mirror the boolean computed in `handle_command!(::CancelCommand)`:
#     escalate = first_at > 0 && (now - first_at) ≥ CANCEL_ESCALATE_WAIT && busy
# A re-cancel escalates ONLY when a first cancel was stamped, the wait has fully
# elapsed, AND the turn is still busy. No chat, no agent, no transport.
should_escalate(first_at, now, busy) =
    first_at > 0 && (now - first_at) ≥ BT.CANCEL_ESCALATE_WAIT && busy

@testset "escalation timing predicate (unit)" begin
    W = BT.CANCEL_ESCALATE_WAIT
    now = 1_000_000.0

    # First cancel of the turn: nothing stamped yet ⇒ never escalates.
    @test should_escalate(0.0, now, true) == false

    # Impatient double-click: first cancel stamped a moment ago, well within the
    # wait ⇒ graceful, no escalation, even though still busy.
    @test should_escalate(now - 0.2, now, true) == false
    @test should_escalate(now - (W - 1.0), now, true) == false

    # Deliberate re-cancel: the agent had its full chance (≥ wait) and is STILL
    # busy ⇒ escalate.
    @test should_escalate(now - (W + 1.0), now, true) == true

    # Same elapsed time, but the turn already settled (not busy) ⇒ no force-close
    # of a turn that's no longer running.
    @test should_escalate(now - (W + 1.0), now, false) == false
end

# ── DOM/state e2e: graceful, double-click safe, force only on deliberate ─────
@testset "cancel: graceful, double-click safe, force only on deliberate re-cancel (e2e)" begin
    # A wedged turn: streams a tag, then HOLDS open ~15 s without answering the
    # cancel — long enough to span the whole escalation sequence.
    s = TK.dev_server(; agent = msg -> [text("working… "), delay(15000), text("done"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        TK.send_message(s, "hello?")
        @assert timedwait(() -> model.busy_active[], 8.0) === :ok "turn never went busy"
        c = BT.client(model.agent)
        @test c !== nothing

        # FIRST cancel — graceful. The held turn ignores it; busy STAYS (no
        # auto-teardown), the session stays alive.
        BT.handle_command!(model, nothing, BT.CancelCommand())
        @test timedwait(() -> !model.busy_active[], 2.0) === :timed_out
        @test model.session_alive[] == true

        # RAPID second cancel (impatient double-click, well within the wait) —
        # STILL graceful. Must not force-close a turn that might be about to honor.
        BT.handle_command!(model, nothing, BT.CancelCommand())
        @test timedwait(() -> !model.busy_active[], 2.0) === :timed_out
        @test model.session_alive[] == true

        # DELIBERATE re-cancel: simulate the agent having had its full chance by
        # backdating the first-cancel stamp past the escalation wait. NOW a
        # re-cancel force-closes the live ACP client → the wedged turn's loop
        # tears down → busy clears, the session is dead, last_error is set.
        @atomic c.conn.cancel_at = time() - (BT.CANCEL_ESCALATE_WAIT + 1.0)
        BT.handle_command!(model, nothing, BT.CancelCommand())
        @test timedwait(() -> !model.busy_active[], 8.0) === :ok
        @test model.session_alive[] == false
        @test !isempty(model.last_error[])

        # The force-close itself must not have thrown into the renderer.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
