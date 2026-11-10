# claude-agent-acp 0.101 compacts a chat by itself once it has been idle for 54
# minutes. It sends `/compact` as its own prompt, and nothing on the wire says
# where that ends, so the chat stayed busy, Stop button and all, until the user
# force-closed the connection. The mock replays the real adapter's frames
# (AgentClientProtocol/test/fixtures/claude_idle_compaction_wire.jsonl) after its
# own turn ended, as the adapter sent them.
@testitem "e2e:idle_compaction" setup = [SharedServer] tags = [:e2e] begin
    import JSON
    S = SharedServer
    s = S.server()
    TK = S.TK

    wire = joinpath(@__DIR__, "..", "..", "..", "AgentClientProtocol", "test", "fixtures",
                    "claude_idle_compaction_wire.jsonl")
    frames = [JSON.parse(l) for l in eachline(wire)]
    answered = findlast(f -> f["dir"] == "in" && haskey(get(f["msg"], "result", Dict()), "stopReason"), frames)
    compaction = [f["msg"]["params"]["update"] for f in frames[(answered + 1):end]
                  if get(f["msg"], "method", "") == "session/update"]
    tool_id = first(compaction)["toolCallId"]
    s.agent_fn[] = function (p)
        p == "go idle" || return [TK.text("echo: $(p)"), TK.end_turn()]
        return [TK.text("OK"), TK.post_turn(Any[TK.recorded(u) for u in compaction]; delay_ms = 500),
                TK.end_turn()]
    end
    TK.new_chat(s; title = "IdleCompaction")
    TK.send_message(s, "go idle")

    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    card = "$pane.querySelector('.bt-tool-msg[data-msg-id*=\"$tool_id\"]')"
    busy = "!!$pane.querySelector('.bt-busy.bt-busy-active')"
    @test TK.wait_for(s, "the compaction card, finished",
        "!!$card && !$card.classList.contains('bt-tool-live')"; timeout = 60,
        describe = "$pane.innerText") == true
    @test TK.eval_js(s, "$card.querySelector('.bt-tool-title').textContent") == "Compact conversation"
    # Every frame of it is in (they came within a few ms of each other), and
    # nothing is left running: no busy indicator, so no Stop to press.
    sleep(1)
    @test TK.eval_js(s, busy) == false
    # The next message is an ordinary turn.
    TK.send_message(s, "after it")
    @test TK.wait_for(s, "the next turn answered",
        "$pane.innerText.includes('echo: after it') && !($busy)"; timeout = 60) == true

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
