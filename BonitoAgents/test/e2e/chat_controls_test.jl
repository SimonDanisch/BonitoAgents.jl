# Black-box port of the legacy `test/electron/test_chat_controls.jl` (Tier 2d).
#
# Exercises the non-input chat header/composer controls END-TO-END against a
# real `dev_server` + worker + mock agent, driven ONLY through the rendered DOM
# (clicks + eval_js, no server-state introspection):
#
#   • Stop button — present while a turn is streaming, and the busy indicator
#     clears once the turn completes. Clicking stop mid-stream throws no JS
#     error and doesn't wipe the agent bubble.
#   • Sync button (`.bt-header-sync`) — clicking fires its handler cleanly (the
#     legacy `Bonito.notify_observable is not a function` regression) and the
#     label changes away from "Sync".
#   • Session-ended Restart button — a `crash` turn hard-kills the mock agent
#     subprocess (EOFError → `is_session_dead_error` → `session_alive=false`),
#     so the header restart button gains its dead/pulse class
#     (`.bt-header-restart-dead`). Clicking it runs `restart_chat_session!`,
#     which respawns the agent and clears the dead class (chat revived).
#
# Header + composer controls (`.bt-header-sync`, `.bt-header-restart`,
# `.bt-stop-btn`) render PER chatpane, and the shared-server runs many chats at
# once. The TestKit pane-scope shim only scopes message selectors, so here we
# query/click through the VISIBLE pane explicitly (`vpQ` / `vpClick`) to avoid
# matching a hidden, stale pane's button.
@testitem "e2e:chat_controls" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # Visible-pane scoping helpers (JS expression fragments).
    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    vpHas(sel)  = "(() => { const p=$VP; return !!(p && p.querySelector($(repr(sel)))); })()"
    vpText(sel) = "(() => { const p=$VP; const e=p && p.querySelector($(repr(sel))); return e ? (e.innerText||'').trim() : null; })()"
    vpClick(sel) = "(() => { const p=$VP; const e=p && p.querySelector($(repr(sel))); if(!e) return false; e.click(); return true; })()"

    # Branch the agent on the prompt so each section gets the turn shape it
    # needs from a single scripted agent:
    #   "stream" → a long, delay-paced turn that stays live so the stop test has
    #              a window to interrupt (10 chunks × 200ms = ~2s of streaming).
    #   "crash"  → emit one chunk, then hard-kill the mock agent mid-prompt.
    #   else     → a plain echo.
    s.agent_fn[] = function (prompt)
        p = lowercase(prompt)
        if occursin("stream", p)
            evs = Any[TK.text("streaming… ")]
            for i in 1:10
                push!(evs, TK.delay(200))
                push!(evs, TK.text("chunk$i "))
            end
            push!(evs, TK.end_turn())
            return evs
        elseif occursin("crash", p)
            return [TK.text("about to die "), TK.crash()]
        else
            return [TK.text("echo: $(prompt)"), TK.end_turn()]
        end
    end

    pid = TK.new_chat(s; title = "ChatControls")
    @test !isempty(pid)
    TK.clear_js_errors(s)

    @testset "Stop button present while streaming, gone after" begin
        # Both the send and the stop button live permanently in the composer.
        @test TK.eval_js(s, vpHas(".bt-stop-btn")) == true

        TK.send_message(s, "stream please")

        # Streaming actually started: the busy indicator is active AND the agent
        # bubble has landed. `.bt-busy.bt-busy-active` is the live-turn signal
        # (scoped to the visible pane by the TestKit shim).
        @test TK.wait_for(s, "streaming started",
            "(() => { const b=document.querySelector('.bt-busy'); " *
            "return !!b && b.classList.contains('bt-busy-active') && " *
            "document.querySelectorAll('.bt-agent-msg').length >= 1; })()";
            timeout = 30) == true

        # Stop button reachable while streaming.
        @test TK.eval_js(s, vpHas(".bt-stop-btn")) == true
        TK.eval_js(s, vpClick(".bt-stop-btn"))

        # Cancel must not wipe the conversation, and the turn settles: the busy
        # indicator clears (either the cancel lands or the stream drains).
        @test TK.wait_for(s, "streaming ended",
            "(() => { const b=document.querySelector('.bt-busy'); " *
            "return !b || !b.classList.contains('bt-busy-active'); })()";
            timeout = 30) == true
        @test TK.eval_js(s, "!!document.querySelector('.bt-agent-msg')") == true
        @test TK.eval_js(s, vpHas(".bt-stop-btn")) == true
    end

    @testset "Sync button click fires its handler cleanly" begin
        @test TK.eval_js(s, vpHas(".bt-header-sync")) == true
        before_errs = length(TK.js_errors(s))

        @test TK.eval_js(s, vpClick(".bt-header-sync")) == true

        # The sync handler runs server-side (it'll report nothing-to-pull / an
        # error against the test worker), but the click must reach Julia without
        # a JS error — the `notify('__click__')` path the legacy test pinned.
        @test TK.wait_for(s, "sync label changed",
            vpText(".bt-header-sync") * " !== 'Sync'"; timeout = 10) == true
        @test length(TK.js_errors(s)) == before_errs
    end

    @testset "Session-ended Restart: dead → working state → revived (guarded)" begin
        # Healthy to start: the header restart button carries no dead class.
        @test TK.eval_js(s, vpHas(".bt-header-restart")) == true
        @test TK.eval_js(s, vpHas(".bt-header-restart-dead")) == false

        # A crash turn kills the mock agent mid-prompt → the chat flips
        # session_alive=false → the restart button pulses (dead class).
        TK.send_message(s, "crash now")
        @test TK.wait_for(s, "restart button went dead",
            vpHas(".bt-header-restart-dead"); timeout = 30) == true

        # ONE click starts the restart. The button must immediately swap the red
        # dead pulse for the "working" state — visual feedback that it's busy, and
        # what stops a user (or an impatient poll) re-clicking a still-broken-looking
        # button. The dead class is gone while it works.
        @test TK.eval_js(s, vpClick(".bt-header-restart")) == true
        @test TK.wait_for(s, "restart shows working state",
            vpHas(".bt-header-restart-busy"); timeout = 10, interval = 0.05) == true
        @test TK.eval_js(s, vpHas(".bt-header-restart-dead")) == false

        # Guard: extra clicks WHILE the restart is running must be no-ops. A second
        # bring-up would tear down the just-revived session and drop the next
        # prompt. Fire a burst now (still inside the ~1s working window); the clean
        # single revival + echo below prove they were ignored — before the guard,
        # this double-restart raced the send and the "alive?" turn never rendered.
        for _ in 1:3
            TK.eval_js(s, vpClick(".bt-header-restart"))
        end

        # Revived: both the working and dead classes clear, composer live again.
        @test TK.wait_for(s, "restart revived the session",
            "(() => { const p=$VP; if(!p) return false; " *
            "return !p.querySelector('.bt-header-restart-dead') " *
            "&& !p.querySelector('.bt-header-restart-busy'); })()";
            timeout = 60, interval = 0.2) == true
        @test TK.wait_for(s, "composer live after restart",
            "!!document.querySelector('.bt-text-input')"; timeout = 30) == true

        # The session survived the burst of clicks: a fresh turn round-trips.
        TK.send_message(s, "alive?")
        @test TK.wait_for(s, "agent replies after restart",
            "(document.querySelector('.bt-messages').innerText||'').includes('echo: alive?')";
            timeout = 30) == true
    end

    @test isempty(TK.js_errors(s))
end
