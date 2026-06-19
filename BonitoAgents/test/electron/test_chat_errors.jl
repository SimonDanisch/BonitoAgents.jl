# ACP error paths, migrated onto the TestKit harness (real dev_server, real
# worker subprocess, real ACP wire, real Electron browser; only the agent's
# behaviour is faked, via the `agent=` callback).
#
# Two distinct failure modes, two distinct user-visible reactions:
#
#   1. The TRANSPORT dies mid-turn (subprocess EOF / socket drop — surfaced as a
#      typed `ConnectionClosed`/`EOFError`/`IOError`, see `is_session_dead_error`)
#      → `run_turn!`'s catch flips `session_alive=false` and stamps `last_error`.
#      The permanent header restart button gains `bt-header-restart-dead` and
#      pulses red; its title attribute carries the underlying error. NO inline
#      error bubble for this branch. busy_active clears in the finally block.
#      Clicking the (pulsing) button calls restart_chat_session! and recovers
#      (session_alive back to true).
#
#   2. A JSON-RPC ERROR REPLY to the prompt (the agent is alive and answered!)
#      → push an inline `[error: …]` AgentMsg bubble so the user sees the failure
#      in line with the conversation. The session stays alive (restart button
#      healthy), and a subsequent send still works.
#
# Sub-test 1 note: in the dev_server topology the chat's transport is the
# WorkerTransport WS to the worker, and the worker (not the chat) owns the ACP
# subprocess — so killing the mock-agent process does NOT promptly surface as a
# session-dead error on the chat's transport within a bounded window. We
# therefore drive the SAME production seam the real transport-death catch hits
# (`chat.session_alive[]=false` + `chat.last_error[]=…`) and assert the full
# user-visible contract (dead button + title + no inline bubble + recovery),
# exactly as the committed `test_chat_controls.jl` restart section does.

using Test
include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK = TestKit
using .TestKit: text, end_turn, error_reply

@testset "ACP error paths — transport death vs. error reply" begin
    # The agent answers an "err …" prompt with a JSON-RPC error (alive-but-
    # failed); any other prompt with a plain reply. Sub-test 1 doesn't need the
    # agent at all (it drives the session-dead seam directly), so a benign
    # default is fine there.
    s = TK.dev_server(; agent = msg -> occursin("err", lowercase(msg)) ?
            [error_reply("model overloaded, please retry")] :
            [text("ok reply"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)

        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        # ── 1. Transport dies mid-turn → dead/pulsing restart button ────────
        @test TK.eval_js(s, "document.querySelector('.bt-header-restart-dead') === null") == true

        # Reproduce the real transport-death catch: session_alive=false with the
        # underlying error text. This is precisely what `is_session_dead_error`
        # → `chat.session_alive[]=false` does on a ConnectionClosed mid-turn.
        model.session_alive[] = false
        model.last_error[]    = "connection closed"

        # The restart button flips to the dead/pulse state.
        TK.wait_for(s, "restart button flips to dead/pulse",
            "document.querySelector('.bt-header-restart-dead') !== null"; timeout = 5)
        # Its title attribute carries the underlying error message.
        TK.wait_for(s, "restart-button title shows the error", """
            (() => {
                const btn = document.querySelector('.bt-header-restart-dead');
                return btn && (btn.getAttribute('title')||'').indexOf('connection closed') !== -1;
            })()
        """; timeout = 5)
        # No inline [error: …] bubble for this branch — the button IS the signal.
        @test TK.eval_js(s, """
            (() => {
                const bs = document.querySelectorAll('.bt-agent-msg');
                return Array.from(bs).some(b => (b.innerText||'').indexOf('[error:') !== -1);
            })()
        """) == false
        @test model.session_alive[] == false

        # Clicking the (pulsing) restart button rebuilds the client and brings
        # session_alive back to true — the button returns to healthy.
        TK.click(s, ".bt-header-restart-dead")
        TK.wait_for(s, "restart button returns to healthy",
            "document.querySelector('.bt-header-restart-dead') === null"; timeout = 30)
        @test model.session_alive[] == true

        # ── 2. JSON-RPC error reply → inline [error: …] bubble ──────────────
        TK.send_message(s, "err: please fail this turn")
        TK.wait_for(s, "inline [error: …] AgentMsg appears", """
            (() => {
                const bs = document.querySelectorAll('.bt-agent-msg');
                return Array.from(bs).some(b => {
                    const t = b.innerText || '';
                    return t.indexOf('[error:') !== -1 && t.indexOf('overloaded') !== -1;
                });
            })()
        """; timeout = 30)
        # The session stays alive — an error REPLY means the agent is fine.
        @test TK.eval_js(s, "document.querySelector('.bt-header-restart-dead') === null") == true
        @test model.session_alive[] == true

        # ── 3. A subsequent send still works after the recoverable error ────
        # The session is alive, so the user can just send again — the retry is
        # accepted and lands as a new user bubble. (Mirrors the original test:
        # it asserts the retry is sent, not the agent's specific reply.)
        before = Int(TK.eval_js(s, "document.querySelectorAll('.bt-user-msg').length"))
        TK.send_message(s, "second try please")
        TK.wait_for(s, "second user bubble appears",
            "document.querySelectorAll('.bt-user-msg').length >= $(before + 1)"; timeout = 15)

        TK.screenshot(s, joinpath(tempdir(), "bt-chat-errors-final.png"))

        # No JS errors fired across the whole run.
        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
