# The user stops a turn while a background Julia run is going. When the run
# ends, the chat must not start a turn with its note ("Background Julia run
# finished …"): the user just pressed Stop. Simon kept seeing exactly that, after
# interrupting a bt_julia_wait. The note waits in the queue ("With your next
# message") and goes out with the user's next message, before it in the
# transcript and in the same prompt. Real BonitoMCP process, real dev_server,
# DOM assertions; what the agent was sent is what the mock agent received.
@testitem "e2e:stop_holds_notes" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    prompts = String[]
    s.agent_fn[] = function (prompt)
        push!(prompts, prompt)
        occursin("start the run", prompt) || return [TK.text("got it"), TK.end_turn()]
        # A run that outlives the turn, then a turn that would wait a long time.
        return [TK.bt_eval("sleep(3); :held_note_run"; real_process = true, background = true, id = "held-run"),
                TK.text("waiting for the run"), TK.delay(120_000), TK.end_turn()]
    end

    pid = TK.new_chat(s; cwd = mktempdir())
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"]"
    auto_notes = "[...document.querySelectorAll('$(P) .bt-user-msg-auto')].map(n => n.innerText)"
    held = "[...document.querySelectorAll('$(P) .bt-queue-item[data-status=held]')]"

    TK.send_message(s, "start the run")
    @test TK.wait_for(s, "the turn waits on its run",
        "(document.querySelector('$(P) .bt-messages')?.innerText || '').includes('waiting for the run')";
        timeout = 60) == true
    TK.click(s, "$(P) .bt-stop-btn")
    @test TK.wait_for(s, "the turn stopped",
        "!document.querySelector('$(P) .bt-busy.bt-busy-active')"; timeout = 30) == true

    @testset "the run's note waits for the user instead of starting a turn" begin
        @test TK.wait_for(s, "the note held in the queue",
            "$(held).some(e => e.innerText.includes('Background Julia run finished'))"; timeout = 90) == true
        @test TK.eval_js(s, "$(held)[0].querySelector('.bt-queue-badge').textContent") == "With your next message"
        @test TK.eval_js(s, auto_notes) == Any[]                  # no turn of its own
        @test length(prompts) == 1                                 # the agent got nothing
        @test TK.eval_js(s, "!document.querySelector('$(P) .bt-busy.bt-busy-active')") == true
    end

    @testset "it goes out with the user's next message" begin
        TK.send_message(s, "carry on")
        @test TK.wait_for(s, "the reply",
            "[...document.querySelectorAll('$(P) .bt-agent-msg')].some(m => m.innerText.includes('got it'))";
            timeout = 60) == true
        @test length(prompts) == 2
        # One prompt: the note, then what the user wrote.
        note_at, msg_at = findfirst("Background Julia run finished", prompts[2]), findfirst("carry on", prompts[2])
        @test note_at !== nothing && msg_at !== nothing && first(note_at) < first(msg_at)
        # In the transcript the note comes first, then the user's message.
        last_two = TK.eval_js(s, """[...document.querySelectorAll('$(P) .bt-user-msg')].slice(-2).map(m =>
            [m.classList.contains('bt-user-msg-auto'), m.innerText])""")
        @test last_two[1][1] == true && occursin("Background Julia run finished", last_two[1][2])
        @test last_two[2][1] == false && occursin("carry on", last_two[2][2])
        @test TK.eval_js(s, "$(held).length") == 0
    end
end
