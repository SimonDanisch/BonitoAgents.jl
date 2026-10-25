# Opt-in: real Codex credentials and a managed adapter with active-only steering.
# CODEX_AGENT_ACP may point at an isolated copy patched by BonitoWorker for the
# test. The sending peer is mocked; the receiver and its ACP wire are real.
@testitem "e2e:codex_steering_real" setup = [SharedServer] tags = [:e2e, :real] begin
    TK = SharedServer.TK
    if get(ENV, "BT_REAL_CODEX", "") != "1"
        @test_skip "Set BT_REAL_CODEX=1 to exercise a real Codex receiver"
    else
        target = Ref("")
        correction = "Keep running both sleep commands already requested. Change only your final reply to exactly CODEX_STEER_OK."
        agent(p) = [TK.mcp_call("bt_dev_control"; real_process = true, op = "send_message",
            project_id = target[], text = correction, id = "real-peer-send"), TK.text("Coordination sent")]
        s = TK.dev_server(; agent)
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes($(repr(t))))"
        idle = "!$pane.querySelector('.bt-busy-active')"
        pick(category, text) = TK.eval_js(s, "(() => { const w=[...$pane.querySelectorAll('.bt-msearch')].find(w => " *
            "w.querySelector('.bt-msearch-trigger')?.textContent.trim().startsWith('$category:')); " *
            "const item=[...w.querySelectorAll('.bt-msearch-item')].find(e => e.textContent.trim().toLowerCase() === $(repr(lowercase(text))) || e.dataset.label?.includes($(repr(lowercase(text))))); " *
            "if (!item) return false; item.click(); return true; })()")
        try
            TK.open_browser(s)
            sender = TK.new_chat(s; title = "Coordination sender")
            TK.eval_js(s, "window.confirm=()=>true; $pane.querySelector('.bt-header-menu .bt-menu-trigger').click(); " *
                "$pane.querySelector('.bt-header-devmode').click()")
            @test TK.wait_for(s, "sender has coordination tools",
                "$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-on')"; timeout = 60)
            target[] = TK.new_chat(s; title = "Real Codex receiver")
            TK.switch_agent(s, "Codex")
            @test TK.wait_for(s, "Codex connected", "$pane.querySelector('.bt-header-provider-pick .bt-msearch-value')?.textContent === 'Codex' && " *
                "$pane.querySelector('.bt-msearch-item[data-label*=\"agent-full-access\"]') !== null"; timeout = 120)
            @test pick("permissions", "Full access")
            @test pick("model", "gpt-6.1-sol")
            @test pick("effort", "low")
            TK.send_message(s, "Use the shell tool to execute these commands sequentially, in separate tool calls: " *
                "sleep 8, then sleep 8. After both complete reply with exactly CODEX_ORIGINAL_DONE. " *
                "Do not repeat the final reply beforehand, and do not write files or do other work.")
            @test TK.wait_for(s, "real Codex is executing a command",
                "[...$pane.querySelectorAll('.bt-tool-msg')].some(e => e.textContent.includes('sleep 8')) && !($idle)"; timeout = 120)
            TK.open_chat(s, sender)
            TK.send_message(s, "coordinate now")
            @test TK.wait_for(s, "peer tool sent the correction", says("Coordination sent"); timeout = 90)
            TK.open_chat(s, target[])
            @test TK.wait_for(s, "the correction leaves the queue during Codex's original turn",
                "[...$pane.querySelectorAll('.bt-user-msg')].some(e => e.textContent.endsWith($(repr(correction))) && e.textContent.includes('Sent at (server UTC):')) && !($idle)"; timeout = 30)
            @test TK.eval_js(s, "!($(says("CODEX_ORIGINAL_DONE")))")
            TK.screenshot(s, joinpath(tempdir(), "bonitoagents-real-codex-steered.png"))
            @test TK.wait_for(s, "Codex applies the correction and finishes",
                "$(says("CODEX_STEER_OK")) && $idle"; timeout = 120)
            @test TK.eval_js(s, "!$pane.querySelector('.bt-queue-item')")
            TK.reload!(s)
            @test TK.wait_for(s, "real completion stays idle after reload",
                "$(says("CODEX_STEER_OK")) && $idle"; timeout = 60)
            TK.send_message(s, "Use the shell tool to run sleep 30, then reply CODEX_SHOULD_BE_STOPPED. Do not do other work.")
            @test TK.wait_for(s, "a real cancelable command runs",
                "[...$pane.querySelectorAll('.bt-tool-msg')].some(e => e.textContent.includes('sleep 30')) && !($idle)"; timeout = 120)
            TK.eval_js(s, "$pane.querySelector('.bt-stop-btn').click()")
            @test TK.wait_for(s, "Stop cancels the real turn", idle; timeout = 30)
            TK.send_message(s, "Reply with exactly CODEX_FOLLOW_UP_OK. Do not use any tools.")
            @test TK.wait_for(s, "the real session answers after Stop",
                "$(says("CODEX_FOLLOW_UP_OK")) && $idle"; timeout = 120)

            # A quiet MCP call has no stream/tool completion boundary at which
            # to deliver. Both input sources must wake it before its minute ends.
            TK.send_message(s, "Call the bt_wait MCP tool with seconds=60 and reason=CODEX_WAIT_USER. " *
                "After it returns reply exactly CODEX_WAIT_USER_ORIGINAL. Do not use other tools.")
            @test TK.wait_for(s, "real Codex enters bt_wait for user input",
                "[...$pane.querySelectorAll('.bt-tool-msg')].some(e => e.textContent.includes('bt_wait')) && !($idle)"; timeout = 120)
            TK.eval_js(s, "$pane.querySelector('.bt-send-mode-trigger').click(); " *
                "$pane.querySelector(\"[data-send-mode='next']\").click()")
            TK.send_message(s, "End the wait and reply exactly CODEX_WAIT_USER_OK instead. Do not call further tools.")
            @test TK.wait_for(s, "real Codex acts on user input before the wait expires",
                "$(says("CODEX_WAIT_USER_OK")) && $idle"; timeout = 20)
            @test TK.eval_js(s, "!($(says("CODEX_WAIT_USER_ORIGINAL")))")

            TK.send_message(s, "Call the bt_wait MCP tool with seconds=60 and reason=CODEX_WAIT_PEER. " *
                "After it returns reply exactly CODEX_WAIT_PEER_ORIGINAL. Do not use other tools.")
            @test TK.wait_for(s, "real Codex enters bt_wait for peer input",
                "[...$pane.querySelectorAll('.bt-tool-msg')].filter(e => e.textContent.includes('bt_wait')).length === 2 && !($idle)"; timeout = 120)
            TK.eval_js(s, "$pane.querySelector('.bt-yolo-bar').click()")
            @test TK.wait_for(s, "real receiver has YOLO enabled",
                "$pane.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')"; timeout = 10)
            correction = "End the wait and reply exactly CODEX_WAIT_PEER_OK instead. Do not call further tools."
            TK.open_chat(s, sender)
            TK.send_message(s, "wake the waiting peer")
            @test TK.wait_for(s, "second peer correction sent",
                "[...$pane.querySelectorAll('.bt-agent-msg')].filter(e => e.textContent.includes('Coordination sent')).length === 2"; timeout = 90)
            TK.open_chat(s, target[])
            @test TK.wait_for(s, "real Codex in YOLO acts on peer input before the wait expires",
                says("CODEX_WAIT_PEER_OK"); timeout = 20)
            @test TK.eval_js(s, "!($(says("CODEX_WAIT_PEER_ORIGINAL")))")
            @test TK.eval_js(s, "$pane.querySelector('.bt-yolo-bar').classList.contains('bt-yolo-bar-on')")
            TK.eval_js(s, "$pane.querySelector('.bt-stop-btn').click()")
            @test TK.wait_for(s, "Stop after waking the YOLO wait", idle; timeout = 30)
            @test isempty(TK.js_errors(s))
        finally
            close(s)
        end
    end
end
