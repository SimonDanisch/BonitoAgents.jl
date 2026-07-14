# Server-level e2e for "Yolo mode" (autonomous auto-continue).
#
# While Yolo is ON, after each turn ends the app auto-nudges the agent to keep
# working (`YOLO_CONTINUE_PROMPT`) until the agent answers just `no`. The self-
# driving loop is: a turn's finalize (`drain_turn!`) enqueues the next continue
# prompt via `send_message!`, whose own finalize repeats the check — no separate
# loop task. A bare `no` bails (no re-prompt).
#
# Drives the SERVER path (no browser), mirroring cancel_escalation_test /
# resume_eager_bind: own `TK.dev_server(agent=…)`, `state.chat_models[pid]`,
# and assert on `msgs_store`. The mock `agent_fn` is a scripted closure with a
# counter so the continue-prompt replies "still working" once, then "no".
@testitem "e2e:yolo_mode" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
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

    # ── Unit-style checks for the bail normalizer ─────────────────────────────
    @testset "yolo_bail normalizes the bail signal" begin
        @test BA.yolo_bail("no")
        @test BA.yolo_bail("No.")
        @test BA.yolo_bail(" no \n")
        @test BA.yolo_bail("NO!")
        @test !BA.yolo_bail("no, here's more")
        @test !BA.yolo_bail("still working on it")
        @test !BA.yolo_bail("")
    end

    # Count auto-continue prompts that landed in the store.
    yolo_prompts(model) = BA.lock(model.lock) do
        count(m -> m isa BA.UserMsg && occursin(BA.YOLO_CONTINUE_PROMPT, m.text),
            model.msgs_store)
    end

    # Scripted mock: the first user task replies with some text; each Yolo
    # continue-prompt replies "still working on it" the FIRST time and "no" the
    # SECOND time → the loop runs one extra turn then bails.
    continue_count = Ref(0)
    function agent_fn(prompt)
        if occursin(BA.YOLO_CONTINUE_PROMPT, prompt)
            continue_count[] += 1
            if continue_count[] == 1
                return [TK.text("still working on it"), TK.end_turn()]
            else
                return [TK.text("no"), TK.end_turn()]
            end
        else
            return [TK.text("here is the initial result"), TK.end_turn()]
        end
    end

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
        @testset "yolo auto-continues until the agent bails with `no`" begin
            # Arm Yolo through the shared source of truth, with reminders that
            # must ride along on every auto-continue.
            BA.shared(model).yolo[] = true
            BA.shared(model).yolo_reminders[] = reminder

            # Send the user's real task. The task turn finalizes → 1st continue
            # prompt fires; the agent says "still working" → 2nd continue prompt
            # fires; the agent says "no" → bail (no 3rd prompt).
            BA.send_message!(model, BA.UserMsg(model, "do the thing"))

            # (a) At least one continue prompt appeared (auto-continue fired) and
            # (b) eventually EXACTLY two (task→#1, "still working"→#2), then it
            # STOPS growing because the "no" reply bails.
            @test poll_until(() -> yolo_prompts(model) >= 1; timeout = 30)
            @test poll_until(() -> yolo_prompts(model) == 2; timeout = 30)

            # The agent's "still working" reply landed (proves prompt #2 was a
            # real continuation, not a stale re-fire).
            @test poll_until(timeout = 30) do
                BA.lock(model.lock) do
                    any(m -> m isa BA.AgentMsg && occursin("still working", m.text),
                        model.msgs_store)
                end
            end

            # (c) The agent answered "no" → bail. Give the loop ample time to
            # (not) fire a third prompt, then assert the count is frozen at 2.
            @test poll_until(timeout = 30) do
                BA.lock(model.lock) do
                    any(m -> m isa BA.AgentMsg && strip(lowercase(m.text)) == "no",
                        model.msgs_store)
                end
            end
            sleep(3.0)   # a stray auto-continue would fire within this window
            @test yolo_prompts(model) == 2
            @test continue_count[] == 2
            @test !model.busy_active[]   # settled, not stuck in a turn

            # The auto-continue bubbles are marked `auto` (dim/system styling)
            # AND carry the user's reminder text appended to the base prompt.
            @test BA.lock(model.lock) do
                autos = filter(m -> m isa BA.UserMsg &&
                                    occursin(BA.YOLO_CONTINUE_PROMPT, m.text),
                    model.msgs_store)
                !isempty(autos) &&
                    all(m -> m.auto, autos) &&
                    all(m -> occursin(reminder, m.text), autos)
            end
        end

        @testset "toggling Yolo off stops the loop" begin
            # It's off already once the agent bailed (toggle stays on but no
            # re-prompt); flip it off explicitly and confirm a fresh user turn
            # does NOT auto-continue.
            BA.shared(model).yolo[] = false
            before = yolo_prompts(model)
            BA.send_message!(model, BA.UserMsg(model, "another task"))
            @test poll_until(timeout = 30) do
                BA.lock(model.lock) do
                    any(m -> m isa BA.AgentMsg && occursin("initial result", m.text),
                        model.msgs_store)
                end
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
    finally
        close(server)
    end
end
