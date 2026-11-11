# A background subagent holds the answer to the prompt that started it: Claude's
# adapter answers only once the subagent ended and the agent reported on it, or
# when the next prompt comes (AgentClientProtocol/test/fixtures/
# claude_bg_subagent_hold_wire.jsonl). The agent's reply is over long before. On
# 2026-11-11 a chat showed busy for an hour behind such a subagent, and every
# message "for when done" waited for it; the subagent, revived with SendMessage,
# was not in the bar at all.
#
# The mock sends the frames the real adapter sends (TestKit `bg_agent_launch`,
# `send_message_resume`, `reply_result`) and holds the answer (`hold`) until the
# test lets the subagent end. The subagent's transcript is a file the test writes.
#
# Its own server: the held turn and the subagent outlive the item's assertions.
@testitem "e2e:subagent_hold" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    dir = mktempdir()
    transcript = joinpath(dir, "agent-a1b2c3.output")
    first_done, second_done = joinpath(dir, "first.done"), joinpath(dir, "second.done")
    entry(stop) = """{"type":"assistant","message":{"role":"assistant","stop_reason":"$(stop)","content":[{"type":"text","text":"working"}]}}\n"""
    write(transcript, entry("tool_use"))

    agent(p) = occursin("start the helper", p) ? [
            TK.text("Starting the helper."),
            TK.bg_agent_launch("toolu_launch1", "a1b2c3", transcript; description = "helper")...,
            TK.text("It works in the background."),
            TK.reply_result(),
            TK.hold(first_done),
            TK.text("The helper finished."),
            TK.reply_result(origin = "task-notification"),
            TK.end_turn()] :
        occursin("more work", p) ? [
            TK.text("Sending the helper more work."),
            TK.send_message_resume("toolu_resume1", "a1b2c3")...,
            TK.text("It runs again."),
            TK.reply_result(),
            TK.hold(second_done),
            TK.text("The helper finished again."),
            TK.reply_result(origin = "task-notification"),
            TK.end_turn()] :
        [TK.text("echo: " * p), TK.reply_result(), TK.end_turn()]

    s = TK.dev_server(agent = agent)
    try
        TK.open_browser(s)
        TK.new_chat(s; title = "HoldChat")
        row = "[...document.querySelectorAll('.bt-taskbar-slot')].find(r => (r.textContent || '').includes('helper'))"
        idle = "!document.querySelector('.bt-busy.bt-busy-active')"
        said(t) = "document.body.textContent.includes($(TK.json(t)))"

        # The reply is over: the chat is free while the helper works, and the
        # helper is in the bar.
        TK.send_message(s, "start the helper")
        @test TK.wait_for(s, "the helper in the bar", "!!($row)"; timeout = 60) == true
        @test TK.wait_for(s, "the reply", said("It works in the background."); timeout = 60) == true
        @test TK.wait_for(s, "the chat free while the helper works", idle; timeout = 30) == true
        @test TK.eval_js(s, "!!($row)") == true

        # A message for when the agent is done goes out now, not after the helper.
        TK.send_message(s, "are you there")
        @test TK.wait_for(s, "the answer while the helper works", said("echo: are you there"); timeout = 30) == true
        @test TK.eval_js(s, "!!($row)") == true
        @test TK.wait_for(s, "the chat free again", idle; timeout = 30) == true

        # The helper ends; its slot waits for the agent's word, and the next turn
        # of ours ends that wait.
        open(io -> write(io, entry("end_turn")), transcript, "a")
        @test TK.wait_for(s, "the helper's end seen",
            "(($row)?.textContent || '').includes('waiting for the agent')"; timeout = 30) == true
        write(first_done, "")

        # Revived with SendMessage: the same card is back in the bar while it
        # runs, and the chat is free again once the reply is over.
        TK.send_message(s, "more work")
        @test TK.wait_for(s, "the reply to the revival", said("It runs again."); timeout = 60) == true
        @test TK.wait_for(s, "the revived helper in the bar", "!!($row)"; timeout = 30) == true
        @test TK.wait_for(s, "the chat free while the revived helper works", idle; timeout = 30) == true
        sleep(3)                         # the bar's 1 Hz loop: the old run's end must not count
        @test TK.eval_js(s, "!!($row)") == true
        @test TK.eval_js(s, "document.querySelectorAll('.bt-tool-msg[data-msg-id*=\"toolu_launch1\"]').length") == 1

        # Its run ends: the agent reports in a turn of its own, and the slot goes.
        open(io -> write(io, entry("end_turn")), transcript, "a")
        @test TK.wait_for(s, "the revived helper's end seen",
            "(($row)?.textContent || '').includes('waiting for the agent')"; timeout = 30) == true
        write(second_done, "")
        @test TK.wait_for(s, "the agent's report", said("The helper finished again."); timeout = 60) == true
        @test TK.wait_for(s, "the revived helper out of the bar", "!($row)"; timeout = 60) == true
        @test TK.wait_for(s, "the chat idle at the end", idle; timeout = 30) == true
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
