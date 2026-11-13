# Commands and sudo on ANOTHER worker (2026-11-13). The chat lives on worker A and
# its agent names worker B: the command runs on B, is a job in the chat's taskbar
# that the user can stop, and later calls find it by its id alone. A sudo there
# asks in the chat, on a card that names B, and the password goes to B's sudo.
# Without the chat's "Remote julia" switch the call is refused.
#
# Each worker has its own config folder and its jobs inherit it, so a job prints
# where it ran. Only B has the stand-in sudo; A would run the real one, so a
# password is typed only once the stand-in left its mark.
@testitem "e2e:remote_commands" setup=[SharedServer] tags=[:e2e] begin
    if Sys.isunix()
        TK = SharedServer.TK
        password = "letmein-remote"
        dir = mktempdir()
        fake = joinpath(dir, "sudo")
        ran = fake * ".ran"
        write(fake, """#!/bin/sh
            : > "\$0.ran"
            [ "\$1" = -S ] && [ "\$2" = -k ] && [ "\$3" = -- ] || exit 90
            shift 3
            printf '%s' "\$SUDO_PROMPT" >&2
            IFS= read -r pw || { echo "sudo: no password was provided" >&2; exit 1; }
            [ "\$pw" = $password ] || { echo "Sorry, try again." >&2; exit 1; }
            exec "\$@"
            """)
        chmod(fake, 0o755)

        call(tool, card; args...) = TK.mcp_call(tool; id = card, real_process = true,
            arguments = Dict{String,Any}(string(k) => v for (k, v) in args))
        where_job = ["sh", "-c", "echo config=\$BONITOAGENTS_CONFIG_DIR; sleep 300"]
        function agent(prompt)
            prompt == "try b" && return [call("bt_process", "refused-b"; action = "start", id = "remote-0",
                worker = "worker-b", argv = where_job), TK.end_turn()]
            prompt == "start on b" && return [call("bt_process", "start-b"; action = "start", id = "remote-1",
                worker = "worker-b", label = "Remote job", argv = where_job), TK.end_turn()]
            prompt == "status by id" && return [call("bt_process", "status-b"; action = "status", id = "remote-1"),
                TK.end_turn()]
            prompt == "sudo on b" && return [call("bt_sudo", "sudo-b"; id = "root-b", worker = "worker-b",
                label = "Root on B", seconds = 120,
                argv = ["sh", "-c", "echo root-config=\$BONITOAGENTS_CONFIG_DIR"]),
                TK.text("sudo returned"), TK.end_turn()]
            return [TK.text("Received: $prompt"), TK.end_turn()]
        end
        s = TK.dev_server(; agent)

        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        card(id) = "$pane?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
        badge(id) = "($(card(id))?.querySelector('.bt-tool-worker')?.textContent || '')"
        summary_has(id, text) = "!!$(card(id))?.querySelector('.bt-tool-summary')?.textContent.includes($(repr(text)))"
        # A finished card's body shows `text`. Bodies render on expand, so the
        # header is clicked once (a second click would collapse it again).
        card_shows(id, text) = """(() => {
            const c = $(card(id)); if (!c) return false;
            const st = c.querySelector('.bt-tool-status')?.textContent || '';
            if (!(st === 'completed' || st === 'failed')) return false;
            const h = c.querySelector('.bt-tool-header');
            if (h && !c.dataset.probeExpanded) {
                c.dataset.probeExpanded = '1';
                if (h.dataset.expanded !== 'true') h.click();
                return false;
            }
            return (c.querySelector('.bt-tool-body')?.innerText || '').includes($(repr(text))); })()"""
        task = "$pane?.querySelector('.bt-process-task[data-process-id=\"remote-1\"]')"
        prompt_card = "$pane?.querySelector('.bt-prompt-card[data-prompt-kind=\"sudo\"]')"
        says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes($(repr(t))))"
        remote_item = "$pane?.querySelector('.bt-header-menu .bt-header-remote')"
        menu_open = "$pane?.querySelector('.bt-header-menu')?.classList.contains('bw-menu-open') === true"
        try
            TK.open_browser(s)
            TK.new_chat(s; title = "Remote-commands")
            withenv(() -> TK.add_worker!(s; name = "worker-b"), "BONITOAGENTS_SUDO_PROGRAM" => fake)
            config_b = only(s.extra_workers).config
            # The dashboard's worker count isn't on the page while a chat is open.
            b_online() = any(w -> w.name == "worker-b" && w.online[], values(s.h.state.workers[]))
            t0 = time()
            while !b_online() && time() - t0 < 60; sleep(0.1); end
            b_online() || error("worker B never came online")

            @testset "refused while the switch is off" begin
                TK.send_message(s, "try b")
                @test TK.wait_for(s, "the refusal says where the switch is",
                    card_shows("refused-b", "switched OFF"); timeout = 60, describe = "$(card("refused-b"))?.innerText")
                @test TK.eval_js(s, badge("refused-b")) == "⇢ worker-b"
                @test TK.eval_js(s, "!$task")
            end

            TK.eval_js(s, "$pane.querySelector('.bt-header-menu .bw-menu-trigger').click(); true")
            @test TK.wait_for(s, "the ⋯ menu is open", menu_open; timeout = 10)
            TK.eval_js(s, "$remote_item.click(); true")
            @test TK.wait_for(s, "the switch reads on", "$remote_item?.classList.contains('bt-cap-on')"; timeout = 10)

            @testset "a command runs on the worker it names" begin
                TK.send_message(s, "start on b")
                @test TK.wait_for(s, "the job is in the taskbar and ran on B",
                    "!!$task && $task.textContent.includes($(repr("config=" * config_b)))";
                    timeout = 60, describe = "$pane.innerText")
                @test TK.eval_js(s, "$task.dataset.processStatus") == "running"
                @test TK.eval_js(s, "$task.textContent.includes('worker-b')")
                @test TK.eval_js(s, badge("start-b")) == "⇢ worker-b"
                # A later call names the job only; the server finds its worker.
                TK.send_message(s, "status by id")
                @test TK.wait_for(s, "a status by id alone reaches B",
                    card_shows("status-b", "config=" * config_b); timeout = 60, describe = "$(card("status-b"))?.innerText")
                @test TK.eval_js(s, card_shows("status-b", "worker-b"))
                # The user stops it from the taskbar, wherever it runs.
                TK.eval_js(s, "$task.querySelector('.bw-menu-trigger').click(); true")
                TK.eval_js(s, "[...$task.querySelectorAll('.bw-menu-item')].find(b => b.textContent === 'Force kill').click(); true")
                @test TK.wait_for(s, "the kill reached B and the task went", "!$task"; timeout = 30)
            end

            @testset "sudo on the worker it names asks in the chat" begin
                TK.send_message(s, "sudo on b")
                @test TK.wait_for(s, "the password card names worker B",
                    "$prompt_card?.querySelector('.bt-permission-question')?.textContent === 'Password to run as root on worker-b'";
                    timeout = 60, describe = "$pane.innerText")
                @test TK.eval_js(s, badge("sudo-b")) == "⇢ worker-b"
                isfile(ran) || error("the stand-in sudo on worker B didn't run, so no password is typed")
                TK.eval_js(s, """(() => { const c = $prompt_card;
                    c.querySelector('input').value = $(repr(password));
                    c.querySelector('button[type=submit]').click(); return true; })()""")
                @test TK.wait_for(s, "the card goes once answered", "!$prompt_card"; timeout = 30)
                @test TK.wait_for(s, "the command ran as root on B",
                    summary_has("sudo-b", "succeeded"); timeout = 60, describe = "$(card("sudo-b"))?.innerText")
                @test TK.wait_for(s, "the agent got its result", says("sudo returned"); timeout = 30)
                @test TK.wait_for(s, "its output is B's",
                    card_shows("sudo-b", "root-config=" * config_b); timeout = 30, describe = "$(card("sudo-b"))?.innerText")
                @test TK.eval_js(s, "document.documentElement.outerHTML.includes($(repr(password)))") == false
            end
            @test isempty(TK.js_errors(s))
        finally
            close(s)
        end
    end
end
