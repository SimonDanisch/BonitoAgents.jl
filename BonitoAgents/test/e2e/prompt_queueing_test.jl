# A separate steering API does not permit overlapping session/prompt requests.
# The installed adapter used one completion waiter per underlying turn: a
# second prompt replaced the first waiter, leaving the chat busy after the
# reply ended, with no active agent turn left for Stop to interrupt.
@testitem "e2e:prompt_queueing" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    agent(prompt) = if occursin("original task", prompt)
        [TK.text("Working before the boundary"), TK.delay(3000),
         TK.bash("echo boundary", "boundary"), TK.delay(3000),
         TK.text("Original task finished")]
    elseif occursin("cancel this task", prompt)
        [TK.text("Waiting for Stop"), TK.delay(60000)]
    else
        [TK.text("Received: " * prompt)]
    end
    s = TK.dev_server(; agent, prompt_queueing = false)
    try
        TK.open_browser(s)
        pid = TK.new_chat(s; title = "Separate steering API")
        pane = "document.querySelector('.bt-chatpane[data-pane-pid=\"$pid\"]')"
        says(text) = "$pane.textContent.includes($(repr(text)))"
        idle = "!$pane.querySelector('.bt-busy-active')"
        TK.send_message(s, "original task")
        @test TK.wait_for(s, "the first reply streams", says("Working before the boundary"); timeout = 60)
        TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
            "$pane.querySelector(\"[data-send-mode='next']\").click()")
        TK.send_message(s, "queued correction")
        @test TK.wait_for(s, "unsupported overlapping prompts stay queued",
            "$pane.querySelector('.bt-queue-item')?.textContent.includes('does not advertise steering') === true";
            timeout = 15)
        @test TK.wait_for(s, "both messages finish without a stranded prompt",
            "$(says("Received: queued correction")) && $idle"; timeout = 30)
        @test TK.eval_js(s, "(() => { const t=$pane.textContent; " *
            "return t.indexOf('Original task finished') < t.indexOf('Received: queued correction'); })()")
        @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
        TK.reload!(s)
        @test TK.wait_for(s, "the completed chat stays idle after reload",
            "$pane && $(says("Received: queued correction")) && $idle"; timeout = 30)

        # Both entry points must still cancel an actual running turn normally.
        for stop in ("$pane.querySelector('.bt-stop-btn').click()",
                     "document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}))")
            TK.send_message(s, "cancel this task")
            @test TK.wait_for(s, "another turn is active", "!($idle)"; timeout = 30)
            TK.eval_js(s, stop)
            @test TK.wait_for(s, "ordinary cancellation settles", idle; timeout = 30)
        end
        TK.send_message(s, "follow-up after Stop")
        @test TK.wait_for(s, "the session remains usable",
            "$(says("Received: follow-up after Stop")) && $idle"; timeout = 30)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-prompt-queueing.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
