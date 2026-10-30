@testitem "e2e:chat_messaging_permissions" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    target = Ref("")
    function agent(prompt)
        # A dev-mode restart can prepend the restored transcript.
        prompt = last(split(prompt, "My new message:\n\n"))
        id = replace(prompt, " " => "-")
        if startswith(prompt, "send ")
            return [TK.mcp_call("bt_chat"; real_process = true, id,
                action = "send", project_id = target[], text = "Peer payload: $prompt"), TK.end_turn()]
        elseif startswith(prompt, "legacy send ")
            return [TK.mcp_call("bt_dev_control"; real_process = true, id,
                op = "send_message", project_id = target[], text = "Peer payload: $prompt"), TK.end_turn()]
        elseif prompt == "list peers"
            return [TK.mcp_call("bt_chat"; real_process = true, id, action = "list"), TK.end_turn()]
        elseif prompt == "block turn"
            return [TK.text("Original work running"), TK.delay(20000), TK.text("Original work finished")]
        end
        return [TK.text("Received: $prompt"), TK.end_turn()]
    end
    s = TK.dev_server(; agent, prompt_queueing = false, active_steering = false)
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    function shows(id, text)
        return """(() => {
            const c=[...$pane.querySelectorAll('.bt-tool-msg[data-msg-id*="$id"]')].at(-1);
            if (!c) return false;
            if (!['completed','failed'].includes(c.querySelector('.bt-tool-status')?.textContent)) return false;
            const h=c.querySelector('.bt-tool-header');
            if (h && !c.dataset.probeExpanded) { c.dataset.probeExpanded='1'; if(h.dataset.expanded!=='true') h.click(); return false; }
            return (c.querySelector('.bt-tool-body')?.innerText || '').includes($(repr(text)));
        })()"""
    end
    attempt(prompt, text) = begin
        TK.send_message(s, prompt)
        id = replace(prompt," "=>"-")
        TK.wait_for(s, "message tool outcome: $prompt", shows(id,text); timeout = 60,
            describe = "$pane.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')?.textContent")
    end
    function devmode(enabled)
        TK.eval_js(s, "(() => { window.confirm=()=>true; const m=$pane.querySelector('.bt-header-menu'); if(!m.classList.contains('bw-menu-open')) m.querySelector('.bw-menu-trigger').click(); m.querySelector('.bt-header-devmode').click(); return true; })()")
        TK.wait_for(s, "dev mode restart settled",
            "$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-on')===$enabled && !$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-busy')"; timeout = 90)
    end
    received(text) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e=>e.textContent.includes($(repr(text))))"
    try
        TK.open_browser(s)
        sender = TK.new_chat(s; title = "Messaging sender")
        @test TK.eval_js(s, "!$pane.querySelector('.bt-header-messaging').classList.contains('bt-cap-on')")
        target[] = TK.new_chat(s; title = "Messaging receiver")
        @test TK.eval_js(s, "!$pane.querySelector('.bt-header-messaging').classList.contains('bt-cap-on')")
        TK.open_chat(s, sender)
        @test attempt("send default off", "Chat messaging is off")
        TK.set_chat_messaging(s)
        @test attempt("send receiver off", "receiving chat")
        TK.open_chat(s, target[])
        @test TK.eval_js(s, "!$pane.textContent.includes('Peer payload:')")
        TK.set_chat_messaging(s)
        TK.open_chat(s, sender)
        @test attempt("list peers", target[])
        @test attempt("send without dev", "queued")
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "normal messaging delivered without dev mode", received("Peer payload: send without dev"); timeout = 30)
        TK.open_chat(s, sender)
        devmode(true)
        @test attempt("legacy send while enabled", "queued")
        devmode(false)
        # Stale model context may remember the old tool. It must fail clearly.
        TK.send_message(s, "legacy send after dev off")
        @test TK.wait_for(s, "stale dev call rejected",
            "($(shows("legacy-send-after-dev-off", "Unknown tool"))) || ($(shows("legacy-send-after-dev-off", "Dev mode is off")))"; timeout = 60)
        @test attempt("send after dev off", "queued")
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "messaging independent of dev toggle", received("Peer payload: send after dev off"); timeout = 30)
        @test TK.eval_js(s, "!$pane.textContent.includes('Peer payload: legacy send after dev off')")
        TK.open_chat(s, sender)
        TK.set_chat_messaging(s, false)
        @test attempt("send after revoke", "Chat messaging is off")
        TK.set_chat_messaging(s)

        TK.open_chat(s, target[])
        TK.send_message(s, "block turn")
        @test TK.wait_for(s, "recipient busy", received("Original work running") * " && !!$pane.querySelector('.bt-busy-active')"; timeout = 30)
        TK.open_chat(s, sender)
        @test attempt("send queued revoke", "queued")
        TK.open_chat(s, target[])
        @test TK.wait_for(s, "peer message actually queued", "[...$pane.querySelectorAll('.bt-queue-item')].some(e=>e.textContent.includes('send queued revoke'))"; timeout = 20)
        TK.set_chat_messaging(s, false)
        paused = "[...$pane.querySelectorAll('.bt-queue-item')].some(e=>e.dataset.status==='paused' && e.textContent.includes('Chat messaging'))"
        @test TK.wait_for(s, "revocation pauses waiting peer input", paused)
        TK.reload!(s)
        @test TK.wait_for(s, "revocation and paused input survive reload", paused; timeout = 30)
        TK.set_chat_messaging(s)
        @test TK.wait_for(s, "original work finishes", received("Original work finished") * " && !$pane.querySelector('.bt-busy-active')"; timeout = 40)
        @test TK.eval_js(s, "!($(received("Peer payload: send queued revoke"))) && $paused")
        TK.eval_js(s, "$pane.querySelector('.bt-queue-item[data-status=paused] [data-queue-action=send]').click(); true")
        @test TK.wait_for(s, "explicit queue-again delivers after opting back in", received("Peer payload: send queued revoke"); timeout = 30)
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-messaging-permission.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
