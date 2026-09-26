# Server-level e2e for "Yolo mode" (autonomous auto-continue).
#
# While Yolo is ON, after each turn ends the app auto-nudges the agent to keep
# working (`YOLO_CONTINUE_PROMPT`). The sentinel does NOT end the loop: it asks
# to, and the app puts `YOLO_CONFIRM_PROMPT` ("are you really done?") back to the
# agent — only the answer to THAT ends it. The self-driving loop is: a turn's
# finalize (`finish_turn!`) enqueues the next prompt via `send_message!`, whose
# own finalize repeats the check — no separate loop task.
#
# Drives the SERVER path (no browser for the loop itself), mirroring
# cancel_escalation_test / resume_eager_bind: own `TK.dev_server(agent=…)`,
# `state.chat_models[pid]`, and assert on `msgs_store`. The mock `agent_fn` is a
# scripted closure that replies per prompt KIND, which is what makes the two-step
# protocol observable from outside.
@testitem "e2e:yolo_mode" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    TK = TestKit
    BA = TestKit.BT

    function poll_until(cond; timeout = 30.0, interval = 0.1)
        t0 = time()
        while time() - t0 < timeout
            cond() && return true
            sleep(interval)
        end
        return false
    end

    # The bail signal itself is covered by `unit:yolo_bail`; duplicating it here
    # is how the two drifted apart (this file asserted the old exact-match rule
    # long after the implementation had moved on). Pin only the one fact this
    # e2e depends on: the sentinel the mock replies with really does bail.
    @testset "the sentinel this test replies with is the bail signal" begin
        @test BA.yolo_bail(BA.YOLO_DONE_SENTINEL)
        @test !BA.yolo_bail("still working on it")
    end

    # Count the app's own prompts in the store, by kind.
    prompts(model, needle) = BA.lock(model.lock) do
        count(m -> m isa BA.UserMsg && occursin(needle, m.text), model.msgs_store)
    end
    yolo_prompts(model)    = prompts(model, BA.YOLO_CONTINUE_PROMPT)
    confirm_prompts(model) = prompts(model, BA.YOLO_CONFIRM_PROMPT)
    agent_said(model, needle) = BA.lock(model.lock) do
        any(m -> m isa BA.AgentMsg && occursin(needle, m.text), model.msgs_store)
    end

    # Scripted mock. `script` is swapped per scenario; every reply is chosen from
    # the prompt KIND (task / continue / confirm), so each scenario reads as the
    # conversation it is testing.
    kind(prompt) = occursin(BA.YOLO_CONFIRM_PROMPT, prompt)  ? :confirm  :
                   occursin(BA.YOLO_CONTINUE_PROMPT, prompt) ? :continue : :task
    seen = Dict{Symbol,Int}()
    script = Ref{Function}((k, n) -> [TK.text("here is the initial result")])
    function agent_fn(prompt)
        k = kind(prompt)
        n = (seen[k] = get(seen, k, 0) + 1)
        return script[](k, n)
    end
    reset_script!(f) = (empty!(seen); script[] = f)

    server = TK.dev_server(; agent = agent_fn)
    try
        state = server.h.state
        @test poll_until(() -> !isempty(state.workers[]); timeout = 30)
        wid = first(keys(state.workers[]))

        pres = BA.create_project_from_worker!(state, wid, mktempdir();
            name = "yolo", start_session = true)
        model = nothing
        @test poll_until(timeout = 30) do
            model = get(state.chat_models, pres.id, nothing)
            model !== nothing
        end

        reminder = "stay focused on the login bug"
        @testset "the sentinel asks to stop; the CONFIRM answer stops" begin
            # task → "…result"                    → continue #1
            # continue #1 → "still working"       → continue #2
            # continue #2 → sentinel              → confirm #1  (NOT a stop)
            # confirm #1 → sentinel               → loop ends
            reset_script!() do k, n
                k === :task && return [TK.text("here is the initial result")]
                k === :continue && n == 1 && return [TK.text("still working on it")]
                return [TK.text(BA.YOLO_DONE_SENTINEL)]
            end

            # Arm Yolo through the shared source of truth, with reminders that
            # must ride along on every auto-continue.
            BA.shared(model).yolo[] = true
            BA.shared(model).yolo_reminders[] = reminder
            BA.send_message!(model, BA.UserMsg(model, "do the thing"))

            # (a) The loop ran, (b) the sentinel on turn 2 bought a CONFIRM
            # question rather than an exit, and (c) it all settles there.
            @test poll_until(() -> yolo_prompts(model) >= 1; timeout = 30)
            @test poll_until(() -> yolo_prompts(model) == 2; timeout = 30)
            @test poll_until(() -> confirm_prompts(model) == 1; timeout = 30)
            @test agent_said(model, "still working")

            sleep(3.0)   # a stray auto-continue would fire within this window
            @test yolo_prompts(model) == 2
            @test confirm_prompts(model) == 1
            @test seen[:continue] == 2 && seen[:confirm] == 1
            @test !model.busy_active[]        # settled, not stuck in a turn
            @test BA.shared(model).yolo[]     # a clean finish leaves Yolo armed
            @test BA.shared(model).yolo_state.phase === :work   # state reset

            # Both prompt kinds are marked `auto` (dim/system styling) AND carry
            # the user's reminders — "done" is measured against the same
            # reminders in the confirm round as in the work rounds.
            @test BA.lock(model.lock) do
                autos = filter(m -> m isa BA.UserMsg &&
                                    (occursin(BA.YOLO_CONTINUE_PROMPT, m.text) ||
                                     occursin(BA.YOLO_CONFIRM_PROMPT, m.text)),
                    model.msgs_store)
                length(autos) == 3 && all(m -> m.auto, autos) &&
                    all(m -> occursin(reminder, m.text), autos)
            end
        end

        @testset "the sentinel is not a way out of work" begin
            # The live failure this protects against: an agent mid-investigation
            # writes the sentinel to end its turn. Answering the confirm question
            # by RUNNING A TOOL is "no, there was more" — whatever the turn's
            # closing line says.
            #
            # task → "…result"        → continue #1
            # continue #1 → sentinel  → confirm #1
            # confirm #1 → tool + sentinel  → NOT a stop → continue #2
            # continue #2 → sentinel  → confirm #2
            # confirm #2 → sentinel (nothing else) → loop ends
            reset_script!() do k, n
                k === :task && return [TK.text("here is the initial result")]
                k === :confirm && n == 1 &&
                    return [TK.tool(; kind = "edit", title = "one more fix"),
                            TK.text(BA.YOLO_DONE_SENTINEL)]
                return [TK.text(BA.YOLO_DONE_SENTINEL)]
            end
            base_c, base_k = yolo_prompts(model), confirm_prompts(model)
            BA.send_message!(model, BA.UserMsg(model, "do more things"))

            # The tool-answer turn must be followed by a further CONTINUE prompt:
            # that is the loop refusing the escape.
            @test poll_until(() -> confirm_prompts(model) == base_k + 1; timeout = 30)
            @test poll_until(() -> yolo_prompts(model) == base_c + 2; timeout = 30)
            @test poll_until(() -> confirm_prompts(model) == base_k + 2; timeout = 30)
            sleep(3.0)
            @test yolo_prompts(model) == base_c + 2
            @test confirm_prompts(model) == base_k + 2
            @test seen[:confirm] == 2 && seen[:continue] == 2
            @test BA.shared(model).yolo[]
        end

        @testset "a repeating agent that never works stops the loop" begin
            # The live runaway: the provider answered every prompt with
            # "You've hit your weekly limit · resets …" and the loop re-sent for
            # hours. Three identical replies with no tool call in between ends it
            # — and switches Yolo OFF, so the user's next message doesn't walk
            # straight back in.
            limit = "You've hit your weekly limit · resets Sep 13, 1pm"
            reset_script!((k, n) -> [TK.text(limit)])
            base_c, base_k = yolo_prompts(model), confirm_prompts(model)
            BA.send_message!(model, BA.UserMsg(model, "keep going please"))

            @test poll_until(timeout = 60) do
                agent_said(model, "Yolo stopped") && !BA.shared(model).yolo[]
            end
            @test agent_said(model, "same answer 3 times")
            @test agent_said(model, "Yolo switched off")
            @test yolo_prompts(model) == base_c + 2   # bounded, not endless
            @test confirm_prompts(model) == base_k    # never claimed to be done
            sleep(3.0)
            @test yolo_prompts(model) == base_c + 2
            @test !BA.shared(model).yolo[]
        end

        @testset "a refused turn stops the loop and disarms" begin
            reset_script!() do k, n
                k === :task && return [TK.text("here is the initial result")]
                return [TK.text("I won't do that"), TK.end_turn(; stopReason = "refusal")]
            end
            BA.shared(model).yolo[] = true
            base_c = yolo_prompts(model)
            BA.send_message!(model, BA.UserMsg(model, "try again"))

            @test poll_until(timeout = 60) do
                agent_said(model, "the agent refused the turn")
            end
            @test poll_until(() -> !BA.shared(model).yolo[]; timeout = 10)
            @test yolo_prompts(model) == base_c + 1   # one nudge, then stop
            sleep(3.0)
            @test yolo_prompts(model) == base_c + 1
        end

        @testset "toggling Yolo off stops the loop" begin
            reset_script!((k, n) -> [TK.text("here is the initial result")])
            BA.shared(model).yolo[] = false
            before = yolo_prompts(model)
            BA.send_message!(model, BA.UserMsg(model, "another task"))
            @test poll_until(timeout = 30) do
                agent_said(model, "initial result")
            end
            sleep(2.0)
            @test yolo_prompts(model) == before   # no new continue prompts
        end

        # Count user bubbles in the store (queued or landed — a rogue send
        # shows up either way).
        user_msgs(model) = BA.lock(model.lock) do
            count(m -> m isa BA.UserMsg, model.msgs_store)
        end

        @testset "lock-in: SendCommand while Yolo is ON writes reminders, never sends" begin
            # While Yolo is armed the composer's send path (Enter / the lock-in
            # button — the SAME wire event, `{type: 'send'}` → SendCommand) is
            # reinterpreted SERVER-SIDE as "lock in these reminders". No user
            # message may slip through — enforced in the handler, not the UI.
            BA.shared(model).yolo[] = true
            before = user_msgs(model)
            BA.handle_command!(model, nothing,
                BA.SendCommand("  focus on X  ", Any[]))
            @test BA.shared(model).yolo_reminders[] == "focus on X"   # stripped
            sleep(2.0)   # a rogue send would enqueue/land within this window
            @test user_msgs(model) == before
            @test BA.lock(model.lock) do
                !any(m -> m isa BA.UserMsg && occursin("focus on X", m.text),
                    model.msgs_store)
            end
        end

        @testset "with Yolo OFF the same SendCommand really sends" begin
            BA.shared(model).yolo[] = false
            before = user_msgs(model)
            BA.handle_command!(model, nothing,
                BA.SendCommand("send this for real", Any[]))
            @test poll_until(timeout = 30) do
                BA.lock(model.lock) do
                    any(m -> m isa BA.UserMsg && m.text == "send this for real",
                        model.msgs_store)
                end
            end
            @test user_msgs(model) == before + 1
            # The reminders survive untouched — only the yolo-armed path writes them.
            @test BA.shared(model).yolo_reminders[] == "focus on X"
            # Let the echo turn settle so the DOM smoke below starts quiet.
            @test poll_until(() -> !model.busy_active[]; timeout = 30)
        end

        @testset "composer DOM: yolo bar toggles the input into reminders mode" begin
            TK.open_browser(server)
            TK.open_chat(server, pres.id)

            # New composer structure: the yolo bar sits in the controls column
            # above the send/stop pair; the input starts in normal (blue) mode.
            @test TK.eval_js(server, "!!document.querySelector('.bt-yolo-bar')") == true
            @test TK.eval_js(server, "!!document.querySelector('.bt-send-btn')") == true
            @test TK.eval_js(server, "!!document.querySelector('.bt-stop-btn')") == true
            @test TK.eval_js(server,
                "document.querySelector('.bt-text-input').classList.contains('bt-text-input-yolo')") == false

            # Type a draft, then arm Yolo via the bar: the input switches to the
            # reminders editor (mode class + prefill with the current reminders)
            # and the send button becomes the lock-in variant.
            TK.eval_js(server, """(() => {
                const i = document.querySelector('.bt-text-input');
                i.value = 'my draft'; return true; })()""")
            TK.click(server, ".bt-yolo-bar")
            @test TK.wait_for(server, "input in yolo mode",
                "document.querySelector('.bt-text-input').classList.contains('bt-text-input-yolo')";
                timeout = 10) == true
            @test poll_until(() -> BA.shared(model).yolo[]; timeout = 10)
            @test TK.wait_for(server, "reminders prefilled",
                "document.querySelector('.bt-text-input').value === 'focus on X'";
                timeout = 10) == true
            @test TK.wait_for(server, "lock-in button styling",
                "document.querySelector('.bt-send-btn').classList.contains('bt-send-btn-yolo')";
                timeout = 10) == true
            @test TK.eval_js(server,
                "(document.querySelector('.bt-text-input').getAttribute('placeholder')||'').includes('lock in')") == true
            @test TK.wait_for(server, "yolo bar armed",
                "document.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')";
                timeout = 10) == true

            # Disarm: everything reverts — mode class gone, draft restored.
            TK.click(server, ".bt-yolo-bar")
            @test TK.wait_for(server, "input back in normal mode",
                "!document.querySelector('.bt-text-input').classList.contains('bt-text-input-yolo')";
                timeout = 10) == true
            @test poll_until(() -> !BA.shared(model).yolo[]; timeout = 10)
            @test TK.wait_for(server, "draft restored",
                "document.querySelector('.bt-text-input').value === 'my draft'";
                timeout = 10) == true
            @test TK.eval_js(server,
                "document.querySelector('.bt-send-btn').classList.contains('bt-send-btn-yolo')") == false

            # The old header controls from the first Yolo pass are gone.
            @test TK.eval_js(server, "!!document.querySelector('.bt-header-yolo')") == false
            @test TK.eval_js(server, "!!document.querySelector('.bt-header-yolo-reminders')") == false

            @test isempty(TK.js_errors(server))
        end

        # LAST: this one kills the mock agent's session on purpose.
        @testset "a turn that FAILS stops the loop and disarms" begin
            # Out of credits, transport gone, model unavailable: the turn throws
            # instead of ending. The loop used to return silently and stay armed;
            # now it says why and switches itself off, because the next nudge
            # would hit exactly the same wall.
            reset_script!() do k, n
                k === :task && return [TK.text("here is the initial result")]
                return [TK.crash()]
            end
            BA.shared(model).yolo[] = true
            base_c = yolo_prompts(model)
            BA.send_message!(model, BA.UserMsg(model, "one more time"))

            @test poll_until(timeout = 60) do
                agent_said(model, "the turn failed")
            end
            @test agent_said(model, "Yolo switched off")
            @test poll_until(() -> !BA.shared(model).yolo[]; timeout = 10)
            # The browser is still open from the DOM testset: switching off is
            # something the USER sees, not just server state.
            @test TK.wait_for(server, "yolo bar disarmed by the failed turn",
                "!document.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')";
                timeout = 10) == true
            @test yolo_prompts(model) == base_c + 1   # the nudge that died, no more
            sleep(3.0)
            @test yolo_prompts(model) == base_c + 1
        end
    finally
        close(server)
    end
end
