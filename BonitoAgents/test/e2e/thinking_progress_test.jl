# While the model thinks without streaming its thoughts, claude-agent-acp
# (patched by BonitoWorker until a release has it) sends Claude Code's estimate
# of the tokens thought so far, about once a second. The reasoning line under
# the last message shows it in place of the busy dots, so a long think reads as
# progress and not as a stalled agent; the model's output ends it.
@testitem "e2e:thinking_progress" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    s.agent_fn[] = p -> occursin("think", p) ?
        [TK.usage(1300, 200000; thinking_tokens = 150), TK.delay(1500),
         TK.usage(2500, 200000; thinking_tokens = 1200), TK.delay(2500),
         TK.text("THE-ANSWER after thinking"), TK.end_turn()] :
        [TK.text("ok"), TK.end_turn()]
    pid = TK.new_chat(s; title = "ThinkingProgress")
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    q(css) = "document.querySelector($(TK.json(P * css)))"
    LINE = q(".bt-thinking")
    COUNT = q(".bt-thinking-count")

    TK.send_message(s, "think hard")
    @test TK.wait_for(s, "the first estimate",
        "$(LINE).classList.contains('bt-thinking-active') && $(COUNT).textContent === '150 tokens'"; timeout = 20) == true
    @test TK.eval_js(s, "getComputedStyle($(LINE)).display !== 'none'") == true
    # One sign of life at a time: the busy dots step aside.
    @test TK.eval_js(s, "$(q(".bt-busy")).classList.contains('bt-busy-suppressed')") == true
    @test TK.wait_for(s, "the estimate grows", "$(COUNT).textContent === '1.2k tokens'"; timeout = 10) == true

    # The answer ends it.
    @test TK.wait_for(s, "the answer", "$(q(".bt-messages")).textContent.includes('THE-ANSWER')"; timeout = 20) == true
    @test TK.wait_for(s, "the line gone",
        "!$(LINE).classList.contains('bt-thinking-active') && $(COUNT).textContent === ''"; timeout = 10) == true

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
