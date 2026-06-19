# Clean cancel, migrated onto the TestKit harness (real dev_server, real worker
# subprocess, real ACP wire, real Electron browser; only the agent's behaviour
# is faked via the `agent=` callback).
#
# Cancel-correctness, part 1: when the agent HONORS the cancel, the turn ends
# cleanly and FAST, the session STAYS ALIVE (no force-close escalation), and any
# chunks streamed AFTER the cancel are discarded — they must never reach the
# bubble (the "cancelled response stuck behind tokens" wedge).
#
# We drive it through the REAL stop path a user takes: the agent streams a few
# "before" chunks, then holds the turn open with a `delay`; mid-delay we click
# `.bt-stop-btn`, which ships `{type:'cancel'}` → CancelCommand → ACP
# session/cancel. After the delay the mock streams "AFTER" chunks (fire-and-
# forget on the dispatcher); the chat-side fast-discard must drop them. The
# bubble ends with the before-text only, busy clears, the session is alive, and
# the partial bubble is sealed into history.

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
const BT = BonitoAgents
using .TestKit: text, delay, end_turn

@testset "clean cancel: post-cancel chunks discarded, session alive, busy clears" begin
    # before-chunks → hold open (the cancel lands here) → after-chunks (must be
    # dropped) → end. The hold is long enough (~4s) to click stop mid-flight.
    s = TK.dev_server(; agent = msg -> [
        text("BEFORE1 "), text("BEFORE2 "), text("BEFORE3 "),
        delay(4000),
        text("AFTER1 "), text("AFTER2 "), text("AFTER3 "),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        # The capture-phase delegate that posts {type:'cancel'} is wired only
        # after _setupInputs runs (deferred to a microtask). `_onEscapeKey` is
        # the last listener attached, so its presence is the "inputs wired" gate.
        TK.wait_for(s, "input handlers wired",
            "typeof document.querySelector('.bt-messages').__bt_chat._onEscapeKey === 'function'";
            timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        TK.send_message(s, "stream then I cancel")
        # The before-chunks render and the turn is genuinely in-flight (busy).
        @test TK.wait_for(s, "before chunks rendered",
            "document.body.textContent.indexOf('BEFORE3') !== -1"; timeout = 20) == true
        @assert timedwait(() -> model.busy_active[], 8.0) === :ok "turn never went busy"

        # Cancel mid-flight via the real stop button. It must reach Julia cleanly
        # (a broken wiring would throw in the renderer here).
        errs_before = length(TK.eval_js(s, "window.__errs || []"))
        TK.click(s, ".bt-stop-btn")
        sleep(0.5)
        @test length(TK.eval_js(s, "window.__errs || []")) == errs_before

        # Graceful cancel that the agent HONORS: busy clears FAST and the session
        # STAYS ALIVE (no force-close — that's reserved for a wedged turn).
        @assert timedwait(() -> !model.busy_active[], 12.0) === :ok "busy never cleared after cancel"
        @test model.busy_active[] == false
        @test model.session_alive[] == true

        # The partial bubble was sealed into the store (no orphan stream) and
        # stays visible in history.
        @test any(m -> m isa BT.AgentMsg, lock(() -> copy(model.msgs_store), model.lock))
        @test TK.eval_js(s, "document.querySelectorAll('.bt-agent-msg').length") >= 1

        # Fast-discard: the AFTER chunks streamed post-cancel must NOT have
        # rendered. Give the mock's delay time to fire its after-chunks first, so
        # we'd catch them if they leaked. Assert on BOTH the DOM and the store.
        sleep(2.0)
        @test TK.eval_js(s, "document.body.textContent.indexOf('AFTER') === -1") == true
        am = first(m for m in lock(() -> copy(model.msgs_store), model.lock) if m isa BT.AgentMsg)
        @test occursin("BEFORE", am.text)
        @test !occursin("AFTER", am.text)

        # The session stayed usable: a follow-up streams a fresh turn.
        users_before = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        s.agent_fn[] = _ -> [text("FOLLOWUP "), end_turn()]
        TK.send_message(s, "still alive?")
        @test TK.wait_for(s, "follow-up user bubble",
            "document.querySelectorAll('.bt-user-msg').length >= $(users_before + 1)"; timeout = 15) == true
        @test TK.wait_for(s, "follow-up response streams",
            "document.body.textContent.indexOf('FOLLOWUP') !== -1"; timeout = 20) == true
        @assert timedwait(() -> !model.busy_active[], 12.0) === :ok "follow-up never settled"

        TK.screenshot(s, joinpath(tempdir(), "bt-clean-cancel-final.png"))
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
