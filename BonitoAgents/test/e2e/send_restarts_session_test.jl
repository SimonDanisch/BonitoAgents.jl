@testitem "e2e:send_restarts_session" setup = [SharedServer] tags = [:e2e] begin
    # Seen live: the agent process ended ("Session ended · Reconnect"), the user
    # typed "go on", and the message sat in the composer as "Paused · not sent"
    # because the send path reused the dead connection. Sending is the user's
    # whole intent: the send itself brings a new session up and delivers.
    TK = SharedServer.TK
    s = SharedServer.server()
    s.agent_fn[] = prompt -> occursin("die now", prompt) ?
        [TK.text("about to die "), TK.crash()] :
        [TK.text("Received: " * prompt), TK.end_turn()]
    pid = TK.new_chat(s; title = "SendRestarts")
    TK.open_chat(s, pid)
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    q(sel) = "document.querySelector(" * repr(P * sel) * ")"
    allq(sel) = "[...document.querySelectorAll(" * repr(P * sel) * ")]"
    waitfor(label, js; timeout = 60) = TK.wait_for(s, label, js; timeout)
    messages = "($(q(".bt-messages")).textContent || '')"

    TK.send_message(s, "die now")
    @test waitfor("agent died, session ended", "!!$(q(".bt-header-restart-dead"))")

    # Record every state the outbox shows while the message goes out.
    TK.eval_js(s, """(() => {
        window.__btQueueSeen = new Set();
        const pane = $(q(""));
        const seen = () => pane.querySelectorAll('.bt-queue-item')
            .forEach(e => window.__btQueueSeen.add(e.dataset.status));
        new MutationObserver(seen).observe(pane, {subtree: true, childList: true, attributes: true});
        return true; })()""")
    TK.send_message(s, "go on")
    @test waitfor("delivered on a new session", "$messages.includes('Received: go on')")
    @test TK.eval_js(s, "$(allq(".bt-user-msg")).some(e => e.textContent.includes('go on'))")
    @test waitfor("outbox empty", "$(allq(".bt-queue-item")).length === 0")
    @test waitfor("session chip cleared", "!$(q(".bt-header-restart-dead"))")
    @test TK.eval_js(s, "[...window.__btQueueSeen].every(st => st === 'waiting' || st === 'sending')")

    # And the restarted session keeps working for the next message.
    TK.send_message(s, "one more")
    @test waitfor("next message answered", "$messages.includes('Received: one more')")
end
