# Yolo against a provider that has stopped working, in Codex's wire dialect.
#
# 2026-10-22: a Codex account hit its usage limit mid-turn, and Yolo re-prompted
# it 10,294 times, one auto-continue a second for 2 h 35 min. Two things hid the
# failure from every guard. Codex ends a FAILED turn as a plain `end_turn` with
# the failure only in the response's `_meta`, and it compacts the conversation
# first, a `think` tool call that counted as the agent doing work. The mock
# replays the frames captured from codex-acp 2.2.2 against that locked account
# (AgentClientProtocol/test/fixtures/codex_usage_limit_*).
@testitem "e2e:yolo_provider_failure" setup = [SharedServer] tags = [:e2e] begin
    s = SharedServer.server()
    TK = SharedServer.TK
    BA = TK.BT

    continue_prompt(prompt) = occursin(BA.YOLO_CONTINUE_PROMPT, prompt)
    auto_prompts_js = "document.querySelectorAll('.bt-user-msg-auto').length"
    agent_says(text) = "[...document.querySelectorAll('.bt-agent-msg')]" *
                       ".some(e => e.textContent.includes($(repr(text))))"
    # The bar and the notice are per chat pane, and the earlier chat's pane stays
    # mounted under `content-visibility: hidden` (so `offsetParent` can't tell).
    visible(sel) = "[...document.querySelectorAll('$sel')].find(e => e.checkVisibility())"
    yolo_on_js = "($(visible(".bt-yolo-bar"))).classList.contains('bt-yolo-bar-on')"

    # Arms Yolo with its button while the first turn is still running, which is
    # how a user starts the loop: with Yolo armed the composer edits reminders
    # instead of sending.
    next = Ref{Function}(_ -> Any[])
    function start_loop(s, title, task_reply)
        s.agent_fn[] = prompt -> continue_prompt(prompt) ? next[](prompt) : task_reply
        pid = TK.new_chat(s; title)
        TK.send_message(s, "render the movie")
        @test TK.wait_for(s, "the task turn is running",
            agent_says("rendering frames"); timeout = 30)
        TK.click(s, ".bt-yolo-bar")
        @test TK.wait_for(s, "Yolo armed", yolo_on_js; timeout = 10)
        return pid
    end

    @testset "a lost connection preserves Yolo without retrying a dead agent" begin
        next[] = _ -> [TK.crash()]
        start_loop(s, "YoloConnectionLost", [TK.text("rendering frames"), TK.delay(5000),
                                             TK.crash()])
        @test TK.wait_for(s, "the interrupted loop says why it paused",
            agent_says("the agent connection was lost"); timeout = 30)
        @test TK.wait_for(s, "Yolo remains armed", yolo_on_js; timeout = 10)
        @test TK.eval_js(s, auto_prompts_js) == 0
        sleep(3.0)
        @test TK.eval_js(s, auto_prompts_js) == 0

        # A reload cannot turn this into an off toggle, and reconnecting the
        # session must preserve the mode too. Both are normal recovery actions.
        TK.reload!(s)
        @test TK.wait_for(s, "Yolo remains on after reload", yolo_on_js; timeout = 30)
        TK.click(s, ".bt-header-reconnect")
        @test TK.wait_for(s, "the agent reconnected",
            "!![...document.querySelectorAll('.bt-chatpane')].find(e => e.checkVisibility())" *
            "?.querySelector('.bt-header-reconnect.bt-hidden')"; timeout = 60)
        @test TK.eval_js(s, yolo_on_js)
        @test TK.eval_js(s, auto_prompts_js) == 0
    end

    @testset "a usage limit stops the loop at the failed turn" begin
        limit = "You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage " *
                "to purchase more credits or try again at Oct 27th, 2026 2:42 PM."
        # Every nudge would fail at the compaction step, exactly like the live chat.
        next[] = _ -> [TK.codex_compaction(; complete = false),
                       TK.codex_failure("Error running remote compact task: " * limit)]
        start_loop(s, "YoloLimit", [TK.text("rendering frames"), TK.delay(5000),
                                    TK.codex_failure(limit)])

        @test TK.wait_for(s, "the stop names the provider's failure",
            agent_says("Yolo stopped: the turn failed ($limit)"); timeout = 30)
        @test TK.wait_for(s, "Yolo switched itself off", "!($yolo_on_js)"; timeout = 10)
        @test TK.wait_for(s, "the failure is shown as a provider error",
            "(() => { const n = $(visible(".bt-session-notice"));
                      return !!n && n.dataset.severity === 'error' &&
                             n.getAttribute('aria-label') === 'Agent error' &&
                             n.textContent.includes('usage limit'); })()"; timeout = 10)
        # The failed turn was the last one: no auto-continue was ever sent.
        @test TK.eval_js(s, auto_prompts_js) == 0
        sleep(3.0)   # a stray auto-continue would land within this window
        @test TK.eval_js(s, auto_prompts_js) == 0
    end

    @testset "turns that only compact are idle turns" begin
        # Codex compacting before every turn and otherwise doing nothing. The
        # compaction must not count as work, or the idle guard never fires.
        pass = Ref(0)
        next[] = _ -> (pass[] += 1; [TK.codex_compaction(), TK.text("pass $(pass[])")])
        start_loop(s, "YoloCompact", [TK.tool(; kind = "edit", title = "edit scene.jl"),
                                      TK.text("rendering frames"), TK.delay(5000)])

        idle = BA.YOLO_IDLE_LIMIT
        @test TK.wait_for(s, "the idle guard stops the loop",
            agent_says("Yolo stopped: the agent went $idle turns without running a single tool");
            timeout = 60)
        @test TK.wait_for(s, "Yolo switched itself off", "!($yolo_on_js)"; timeout = 10)
        @test TK.eval_js(s, auto_prompts_js) == idle
        sleep(3.0)
        @test TK.eval_js(s, auto_prompts_js) == idle
    end

    @test isempty(TK.js_errors(s))
end
