# Queueing a message typed while the agent is still working.
#
# Sending mid-turn must not race the running turn: the bubble is stored, dimmed
# and badged with its position, and only prompted once the turn ahead of it
# ends. The user-visible contract:
#
#   * a mid-turn send renders `.bt-queued` with a position label — "next up"
#     for the first, "queued · #2" behind it (`queueLabel` in bonitoagents.js,
#     surfaced by `.bt-user-msg.bt-queued::after { content: attr(...) }`),
#   * the labels RE-NUMBER in place as the queue drains, and
#   * pressing stop means stop: the queue does not survive a cancel and start
#     a fresh turn the user never asked for.
#
# Asserted on the rendered DOM, so it covers the whole path — `send_message!`
# stamping `queue_pos`, the `user_requeue` wire message, and the CSS. The label
# is read from `dataset.queueLabel` rather than the ::after box because
# pseudo-element text is not in the DOM.

@testitem "e2e:queued_messages" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK

    # "slow" keeps a turn live long enough to land two more sends behind it;
    # anything else answers in one shot so the drain is quick.
    const CHUNKS   = 30
    const DELAY_MS = 400

    function agent_script(prompt)
        if occursin("slow", lowercase(prompt))
            evs = Any[]
            for i in 1:CHUNKS
                push!(evs, TK.text("chunk$(i) "))
                push!(evs, TK.delay(DELAY_MS))
            end
            push!(evs, TK.end_turn())
            return evs
        end
        return [TK.text("done: $(prompt)"), TK.end_turn()]
    end
    s.agent_fn[] = agent_script

    pid = TK.new_chat(s; title = "Queue")
    TK.open_chat(s, pid)
    # Pane-scope every selector: SharedServer leaves other items' panes mounted
    # (hidden but in the DOM), so a global `.bt-queued` can resolve to a stale one.
    P = ".bt-chatpane[data-pane-pid=\"$(pid)\"] "
    @test TK.wait_for(s, "chat mounted",
        "[...document.querySelectorAll('$(P).bt-text-input')].some(e=>e.offsetParent)";
        timeout = 15) == true

    # Labels of the queued bubbles, in DOM order.
    labels_js = "[...document.querySelectorAll('$(P).bt-user-msg.bt-queued')]" *
                ".map(e => e.dataset.queueLabel || '')"

    TK.send_message(s, "slow one please")
    @test TK.wait_for(s, "turn is live",
        "!!document.querySelector('$(P).bt-stream-text')"; timeout = 20) == true

    # Two sends behind the running turn.
    TK.send_message(s, "second message")
    TK.send_message(s, "third message")

    # Snapshot every user bubble's classes + label. Reported on failure so a
    # mismatch says WHAT rendered instead of just "timed out".
    snap_js = "[...document.querySelectorAll('$(P).bt-user-msg')].map(e => " *
              "({t: (e.innerText||'').slice(0,20), q: e.classList.contains('bt-queued'), " *
              "l: e.dataset.queueLabel || null}))"
    # Sample directly rather than via wait_for, which THROWS on timeout and so
    # would skip the diagnostic that explains the failure.
    samples = Any[]
    for i in 1:6
        push!(samples, TK.eval_js(s, snap_js))
        sleep(0.5)
    end
    @info "user bubbles over 3s after two mid-turn sends" samples
    @test any(sn -> any(b -> b["q"] === true, sn), samples)

    @test TK.wait_for(s, "both queued with positions",
        "JSON.stringify($(labels_js)) === JSON.stringify(['next up','queued · #2'])";
        timeout = 10) == true

    shot = joinpath(tempdir(), "queued_messages.png")
    TK.screenshot(s, shot)
    @info "queued bubbles rendered" screenshot = shot

    # Stop. The running turn ends, and the queue must NOT roll on into turns the
    # user never asked for — "stop" is about the chat, not just this one turn.
    TK.eval_js(s, "(() => { const b=[...document.querySelectorAll('$(P).bt-stop-btn')]" *
                  ".find(e=>e.offsetParent!==null); if(b) b.click(); })()")

    # Sample rather than wait_for: it throws on timeout, which would skip every
    # assertion after it and hide what actually happened.
    post = Any[]
    for i in 1:24
        push!(post, TK.eval_js(s, "(() => ({" *
            "busy: (() => { const b = document.querySelector('$(P).bt-busy'); " *
            "return !!b && b.classList.contains('bt-busy-active'); })(), " *
            "labels: $(labels_js), " *
            "ran2: document.querySelector('$(P).bt-messages').innerText.includes('done: second message'), " *
            "chunks: (document.querySelector('$(P).bt-messages').innerText.match(/chunk\\d+/g)||[]).length}))()"))
        sleep(0.5)
    end
    @info "state over 12s after stop" first = post[1] last = post[end]
    @test post[end]["busy"] === false
    # The queued prompts never ran...
    @test post[end]["ran2"] === false
    # ...and their text is still on screen, marked, not silently deleted.
    @test post[end]["labels"] == ["not sent", "not sent"]
    TK.screenshot(s, joinpath(tempdir(), "queued_messages_after_stop.png"))
end
