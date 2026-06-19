# Stop / cancel, migrated onto the TestKit harness (real dev_server, real
# worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked, via the `agent=` callback).
#
# The stop feature is critical UX — when the agent is streaming a long response
# the user MUST be able to interrupt. Two trigger paths, same contract:
#
#   1. Click on the `.bt-stop-btn` DOM button.
#   2. Press ESC anywhere in the chat (textarea focused or not).
#
# Both ship `{type:'cancel'}` over the comm Observable, which the Julia side
# turns into a `CancelCommand` → ACP `session/cancel`. The user-visible contract
# the legacy MockTransport test asserted, re-expressed against the real stack:
#
#   - The cancel reaches Julia cleanly — no JS error in the renderer.
#   - `busy_active` clears (the in-flight turn ends).
#   - The partial agent bubble is sealed into the store (an AgentMsg lands —
#     no orphan stream hanging) and stays visible in history.
#   - After cancel the user can immediately send a follow-up — it lands as a
#     new user bubble and a fresh turn streams.
#
# Each turn is held open with a long `delay` so the stop is genuinely mid-flight
# (the prompt is in-flight while we click stop / press ESC). The mock honours the
# real `session/cancel` (the dispatcher stream itself is fire-and-forget, so the
# turn drains rather than truncating mid-frame — the chat-side contract above is
# what matters and is unchanged).

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, delay, end_turn

@testset "chat stop / cancel — stop button + ESC" begin
    # A turn that starts streaming, then holds open ~4s so the cancel lands
    # genuinely mid-flight.
    s = TK.dev_server(; agent = msg -> [
        text("streaming a long reply "),
        delay(4000),
        text("done"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        # The capture-phase delegate that posts {type:'cancel'} is wired only
        # after _setupInputs runs (deferred to a microtask). `_onEscapeKey` is the
        # last listener attached, so its presence is the "inputs are wired" signal.
        TK.wait_for(s, "input handlers wired",
            "typeof document.querySelector('.bt-messages').__bt_chat._onEscapeKey === 'function'";
            timeout = 10)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # ── 1. Stop BUTTON cancels an in-flight prompt ──────────────────────
        TK.send_message(s, "tell me a long story")
        TK.wait_for(s, "agent bubble appears",
            "document.querySelectorAll('.bt-agent-msg').length >= 1"; timeout = 10)
        @assert timedwait(() -> model.busy_active[], 6.0) === :ok "turn never went busy"

        errs_before = length(TK.eval_js(s, "window.__errs || []"))
        TK.click(s, ".bt-stop-btn")
        sleep(0.5)
        # The stop click reaches Julia cleanly — no JS error (broken cancel wiring
        # would throw in the renderer here).
        @test length(TK.eval_js(s, "window.__errs || []")) == errs_before
        # busy_active clears — the cancelled turn ends.
        @assert timedwait(() -> !model.busy_active[], 12.0) === :ok "busy never cleared after stop"
        @test model.busy_active[] == false
        # The partial agent bubble was sealed into the store (no orphan stream).
        @test any(m -> m isa BonitoAgents.AgentMsg, lock(() -> copy(model.msgs_store), model.lock))
        # …and stays visible in history.
        @test TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length") >= 1

        # ── 2. Follow-up after a stop works ─────────────────────────────────
        before_users = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        TK.send_message(s, "ok, something else now")
        TK.wait_for(s, "follow-up user bubble appears",
            "document.querySelectorAll('.bt-user-msg').length >= $(before_users + 1)"; timeout = 15)
        # A fresh turn actually streams after the cancel.
        @assert timedwait(() -> model.busy_active[], 8.0) === :ok "follow-up turn never started"
        # Drain it so the ESC section starts from a clean state.
        TK.click(s, ".bt-stop-btn")
        @assert timedwait(() -> !model.busy_active[], 12.0) === :ok "follow-up never finished"

        # ── 3. ESC cancels an in-flight prompt (no focus required) ──────────
        before_agents = Int(TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length"))
        TK.send_message(s, "another long one please")
        TK.wait_for(s, "new agent bubble appears",
            "document.querySelectorAll('.bt-agent-msg').length >= $(before_agents + 1)"; timeout = 10)
        @assert timedwait(() -> model.busy_active[], 6.0) === :ok "ESC turn never went busy"

        errs_before_esc = length(TK.eval_js(s, "window.__errs || []"))
        # Dispatch ESC on document — must work without anything focused (the
        # "user is reading the stream and hits ESC" scenario).
        TK.eval_js(s, "document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true})); true")
        sleep(0.5)
        @test length(TK.eval_js(s, "window.__errs || []")) == errs_before_esc
        @assert timedwait(() -> !model.busy_active[], 12.0) === :ok "busy never cleared after ESC"
        @test model.busy_active[] == false

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-cancel-final.png"))

        # No JS errors fired across the whole run.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
