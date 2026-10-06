@testitem "e2e:queued_messages" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    screenshot_dir = mktempdir(; prefix="bt-queue-ui-")
    s = SharedServer.server()
    s.agent_fn[] = function(prompt)
        occursin("slow", prompt) || return [TK.text("Received: " * prompt), TK.end_turn()]
        hold_ms = occursin("stop", prompt) || occursin("interrupt", prompt) ? 30000 : 4000
        events = Any[TK.text("Working before boundary"), TK.delay(hold_ms),
            TK.bash("echo boundary", "boundary"), TK.delay(4000)]
        # Exercise virtualized history: waiting messages must not be stranded
        # at their submission position behind hundreds of later tool cards.
        if prompt == "slow default"
            append!(events, [TK.bash("echo step $i", "step $i") for i in 1:120])
        end
        append!(events, [TK.text("Finished original turn"), TK.end_turn()])
        events
    end
    pid = TK.new_chat(s; title="Queue UX")
    TK.open_chat(s, pid)
    P = ".bt-chatpane[data-pane-pid=\"$pid\"] "
    q(sel) = "document.querySelector(" * repr(P * sel) * ")"
    allq(sel) = "[...document.querySelectorAll(" * repr(P * sel) * ")]"
    mode(value) = TK.eval_js(s, "$(q(".bt-send-mode-trigger")).click(); " *
        "$(q(".bt-send-mode-option[data-send-mode='$value']")).click(); true")
    waitfor(label, js) = TK.wait_for(s, label, js; timeout=30)
    users = allq(".bt-user-msg") * ".map(e => e.textContent)"
    queue = allq(".bt-queue-item")
    @test waitfor("default send mode", "$(q(".bt-send-mode-trigger"))?.textContent.includes('Queue when done')")

    # An empty desktop composer is one row, even after delivery feedback arrives.
    @test TK.eval_js(s, "$(q(".bt-input-area")).getBoundingClientRect().height <= 90")

    TK.send_message(s, "slow default")
    @test waitfor("first turn streaming", "!!$(q(".bt-stream-text"))")
    TK.eval_js(s, "$(q(".bt-send-mode-trigger")).click(); document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));")
    @test TK.eval_js(s, "$(q(".bt-send-mode-menu")).hidden && $(q(".bt-busy")).classList.contains('bt-busy-active')")
    TK.send_message(s, "queued second")
    TK.send_message(s, "queued third")
    @test waitfor("two pending messages", "$queue.length === 2")
    @test TK.eval_js(s, "!$users.includes('queued second') && !$users.includes('queued third')")
    @test TK.eval_js(s, "$queue.every(e => e.textContent.includes('Waiting until the agent finishes'))")
    @test TK.eval_js(s, "$queue.every(e => e.getBoundingClientRect().height <= 40)")
    TK.screenshot(s, joinpath(screenshot_dir, "queue_pending.png"))
    @test waitfor("queue drained", "$queue.length === 0 && $(q(".bt-messages")).textContent.includes('Received: queued third')")
    @test TK.eval_js(s, "(() => { const t=$(q(".bt-messages")).textContent; return t.indexOf('Finished original turn') < t.indexOf('queued second') && t.indexOf('queued second') < t.indexOf('queued third'); })()")
    @test waitfor("explicit delivery notice", "$(q(".bt-queue-delivery")).textContent.includes('Sent to agent: queued third')")
    @test TK.eval_js(s, "$(allq(".bt-user-msg.bt-queued")).length === 0")

    @test TK.eval_js(s, "$(q(".bt-input-area")).getBoundingClientRect().height <= 90")
    for width in (320, 390)
        TK.emulate_phone(s; width) do
            @test waitfor("compact delivered composer", "$(q(".bt-input-area")).getBoundingClientRect().height <= 125")
            @test TK.eval_js(s, "!$(q(".bt-input-row .bt-queue-delivery")) && !$(q(".bt-queue-jump"))")
            @test TK.eval_js(s, "['.bt-stop-btn','.bt-send-btn'].every(c=>{const r=document.querySelector($(repr(P))+c).getBoundingClientRect();return Math.abs(r.width-r.height)<1;})")
            TK.eval_js(s, "$(q(".bt-send-mode-trigger")).click()")
            @test TK.eval_js(s, "(() => { const r=$(q(".bt-send-mode-menu")).getBoundingClientRect(); return r.width > 0 && r.left >= 0 && r.right <= innerWidth; })()")
            @test TK.eval_js(s, "$(allq(".bt-send-mode-option")).every(e => { const r=e.getBoundingClientRect(); return e.contains(document.elementFromPoint(r.x+r.width/2, r.y+r.height/2)); })")
            TK.screenshot(s, joinpath(screenshot_dir, "queue_menu_$(width).png"))
            TK.eval_js(s, "$(q(".bt-send-mode-option[data-send-mode='next']")).click()")
            @test TK.eval_js(s, "$(q(".bt-send-mode-trigger")).textContent.includes('Queue after message')")
            @test TK.eval_js(s, "(() => {const e=$(q(".bt-send-mode-trigger"));const r=document.createRange();r.selectNodeContents(e);return r.getClientRects().length===1 && getComputedStyle(e).whiteSpace==='nowrap';})()")
            @test TK.eval_js(s, "(() => {const e=$(q(".bt-send-mode-trigger"));return e.scrollWidth<=e.clientWidth+1 && e.scrollHeight<=e.clientHeight+1;})()")
            @test TK.eval_js(s, "$(q(".bt-send-btn")).getBoundingClientRect().bottom <= innerHeight")
            shot = TK.screenshot(s, joinpath(screenshot_dir, "queue_compact_$(width).png"))
            size = TK.run(s.browser[].app, "electron.nativeImage.createFromPath($(TK.json(shot))).getSize()")
            @test abs(size["width"] / size["height"] - width / 844) < 0.002
            mode("done")
        end
    end
    TK.eval_js(s, "$(q(".bt-new-msg-pill"))?.click()")

    TK.send_message(s, "slow stop")
    @test waitfor("stop turn streaming", "!!$(q(".bt-stream-text"))")
    TK.send_message(s, "keep me after stop")
    @test waitfor("queued before stop", "$queue.length === 1")
    TK.eval_js(s, "$(q(".bt-stop-btn")).click()")
    @test waitfor("stop pauses queue", "$queue.length === 1 && $queue[0].dataset.status === 'paused'")
    @test TK.eval_js(s, "!$users.includes('keep me after stop') && $queue[0].textContent.includes('Not sent')")
    @test waitfor("cancel settles", "!$(q(".bt-busy")).classList.contains('bt-busy-active')")
    # A fresh browser page must agree with the live tab about the paused queue.
    TK.eval_js(s, "location.reload()")
    @test waitfor("paused queue survives reload", "$queue.length === 1 && $queue[0].dataset.status === 'paused'")
    @test waitfor("reloaded composer visible", "!!$(q(".bt-text-input"))?.offsetParent && !document.querySelector('[data-bt-settling]')")
    TK.screenshot(s, joinpath(screenshot_dir, "queue_paused.png"))
    TK.emulate_phone(s) do
        @test waitfor("queue fits phone", "$(q(".bt-message-queue")).getBoundingClientRect().width > 0 && $(q(".bt-message-queue")).getBoundingClientRect().right <= window.innerWidth")
        @test TK.eval_js(s, "$(q(".bt-text-input")).getBoundingClientRect().height > 0 && $(q(".bt-text-input")).getBoundingClientRect().bottom <= window.innerHeight")
        @test TK.eval_js(s, "$(q(".bt-input-area")).getBoundingClientRect().height <= 165")
        @test TK.eval_js(s, "(() => { const p=$(q(".bt-new-msg-pill")); return !p?.offsetParent || p.getBoundingClientRect().bottom <= $(q(".bt-input-area")).getBoundingClientRect().top; })()")
        TK.screenshot(s, joinpath(screenshot_dir, "queue_phone.png"))
        TK.eval_js(s, "$(q(".bt-queue-summary")).click()")
        @test TK.eval_js(s, "$(q("[data-queue-action='send']")).getBoundingClientRect().height > 0 && $(q(".bt-queue-item")).open")
    end
    # Viewport changes can leave follow mode off. Rejoin the tail through
    # the same visible control a user clicks before checking live replies.
    TK.eval_js(s, "$(q(".bt-new-msg-pill"))?.click()")
    TK.eval_js(s, "$(q("[data-queue-action='send']")).click()")
    @test waitfor("resend reaches agent", "$queue.length === 0 && $(q(".bt-messages")).textContent.includes('Received: keep me after stop')")

    TK.send_message(s, "slow interrupt")
    @test waitfor("interrupt turn streaming", "!!$(q(".bt-stream-text"))")
    TK.send_message(s, "older queued instruction")
    @test waitfor("old message queued", "$queue.length === 1")
    mode("interrupt")
    TK.send_message(s, "urgent correction")
    @test waitfor("urgent message answered", "$(q(".bt-messages")).textContent.includes('Received: urgent correction')")
    @test TK.eval_js(s, "$queue.length === 1 && $queue[0].dataset.status === 'paused' && !$users.includes('older queued instruction')")
    TK.eval_js(s, "$(q(".bt-queue-summary")).click()")
    TK.eval_js(s, "$(q("[data-queue-action='remove']")).click()")
    @test waitfor("removed pending message", "$queue.length === 0")

    mode("done")
    TK.send_message(s, "slow steer")
    @test waitfor("steering turn streaming", "!!$(q(".bt-stream-text"))")
    mode("next")
    TK.send_message(s, "steering instruction")
    @test waitfor("waiting for boundary", "$queue.length === 1 && $queue[0].dataset.mode === 'next'")
    @test waitfor("steering reaches agent", "$(q(".bt-messages")).textContent.includes('Received: steering instruction')")
    # The original turn still reaches its end: steering did not cancel it.
    @test waitfor("original turn continues", "!$(q(".bt-busy")).classList.contains('bt-busy-active')")
    @test TK.eval_js(s, "(() => {const t=$(q(".bt-messages")).textContent; return t.lastIndexOf('Received: steering instruction') < t.lastIndexOf('Finished original turn');})()")
    @test TK.eval_js(s, "!$(q(".bt-messages")).textContent.includes('ended the turn without a reply')")
    TK.screenshot(s, joinpath(screenshot_dir, "queue_delivered.png"))
end
