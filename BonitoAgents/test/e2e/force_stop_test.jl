# A quiet agent that never closes its prompt and ignores cancel. The spinner
# must have a visible way out, without the user knowing the re-cancel timeout.
@testitem "e2e:force_stop" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    # The pane navigation shows. Not "the first pane that checkVisibility()":
    # every kept-alive pane passes that (it stays laid out under
    # content-visibility: hidden), so the answer depended on pane order.
    visible_pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    pending = "!!($visible_pane)?.querySelector('.bt-cancel-status:not([hidden])')"
    busy = "!!($visible_pane)?.querySelector('.bt-busy-active')"
    says(text) = "($visible_pane)?.textContent.includes($(repr(text))) === true"

    @testset "an ordinary Stop settles without leaving force-stop controls" begin
        s = SharedServer.server()
        s.agent_fn[] = _ -> [TK.text("working quietly"), TK.delay(60000)]
        TK.new_chat(s; title = "GracefulStop")
        TK.send_message(s, "start")
        @test TK.wait_for(s, "the reply starts", says("working quietly"); timeout = 60)
        TK.click(s, ".bt-stop-btn")
        @test TK.wait_for(s, "graceful cancel ends the turn", "!($busy)"; timeout = 30)
        @test TK.eval_js(s, "!($pending)")
    end

    agent(prompt) = occursin("hold the prompt", prompt) ?
        [TK.text("The result is ready."), TK.delay(120000)] : [TK.text("follow-up received")]
    s = TK.dev_server(; agent, ignore_cancel = true)
    try
        TK.open_browser(s)
        TK.new_chat(s; title = "UnresponsiveStop")
        TK.send_message(s, "hold the prompt")
        @test TK.wait_for(s, "text without a prompt completion",
            says("The result is ready."); timeout = 60)
        TK.click(s, ".bt-stop-btn")
        @test TK.wait_for(s, "Stop is acknowledged visibly", pending; timeout = 10)
        @test TK.eval_js(s, busy)
        @test TK.eval_js(s, says("Stopping the agent"))
        # An impatient double-click still asks for graceful cancellation.
        TK.click(s, ".bt-stop-btn")
        @test TK.eval_js(s, busy)

        TK.reload!(s)
        @test TK.wait_for(s, "pending cancellation survives a reload", pending; timeout = 30)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-force-stop.png"))
        # The separate action explicitly requests force, with no hidden 20 s
        # wait or test-only backdating of the cancellation clock.
        TK.click(s, ".bt-force-stop-btn")
        @test TK.wait_for(s, "force stop clears the spinner", "!($busy)"; timeout = 30)
        @test TK.eval_js(s, "!($pending)")
        @test TK.eval_js(s, says("The result is ready."))

        TK.send_message(s, "continue with this correction")
        @test TK.wait_for(s, "the next message reconnects and gets an answer",
            says("follow-up received"); timeout = 90)
        @test TK.wait_for(s, "the follow-up ends normally", "!($busy)"; timeout = 30)
        @test TK.eval_js(s, "!($pending)")
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
