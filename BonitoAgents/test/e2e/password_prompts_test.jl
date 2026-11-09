@testitem "e2e:password_prompts" setup=[SharedServer] tags=[:e2e] begin
    import Sockets
    if Sys.isunix()
        TK = SharedServer.TK
        password = "letmein-e2e"
        dir = mktempdir()
        # Stands in for sudo: the worker can't be given a real one in a test. It
        # prompts with SUDO_PROMPT and reads one line, as `sudo -S` does. It leaves a
        # mark first, and the test types a password only once that is there.
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

        # A throwaway sshd on loopback, with a passphrase on the key, when there is one.
        sshd = something(Sys.which("sshd"), isfile("/usr/sbin/sshd") ? "/usr/sbin/sshd" : nothing, Some(nothing))
        keys = mktempdir()
        port = let l = Sockets.listen(Sockets.IPv4(0x7f000001), 0)
            p = Int(Sockets.getsockname(l)[2]); close(l); p
        end
        daemon = nothing
        if sshd !== nothing && Sys.which("ssh-keygen") !== nothing
            run(pipeline(`ssh-keygen -q -t ed25519 -N "" -f $keys/host_key`; stdout = devnull))
            run(pipeline(`ssh-keygen -q -t ed25519 -N "hunter2" -f $keys/user_key`; stdout = devnull))
            cp("$keys/user_key.pub", "$keys/authorized_keys")
            write("$keys/sshd_config", """
                Port $port
                ListenAddress 127.0.0.1
                HostKey $keys/host_key
                AuthorizedKeysFile $keys/authorized_keys
                PidFile none
                UsePAM no
                StrictModes no
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                """)
            daemon = run(pipeline(`$sshd -D -e -f $keys/sshd_config`; stdout = devnull, stderr = devnull); wait = false)
        end

        sudo_call(card, id) = TK.mcp_call("bt_sudo"; id = card, real_process = true,
            arguments = Dict{String,Any}("id" => id, "argv" => ["sh", "-c", "echo ran-as-root"],
                                         "label" => "Root job", "seconds" => 120))
        function agent(prompt)
            prompt == "sudo please" && return [sudo_call("sudo-call", "root-1"), TK.text("sudo returned"), TK.end_turn()]
            prompt == "sudo refused" && return [sudo_call("sudo-refused", "root-2"), TK.text("refusal returned"), TK.end_turn()]
            prompt == "ssh please" && return [TK.mcp_call("bt_ssh"; id = "ssh-call", real_process = true,
                arguments = Dict{String,Any}("id" => "master-1", "destination" => "127.0.0.1", "seconds" => 120,
                    "options" => ["Port=$port", "IdentityFile=$keys/user_key", "IdentitiesOnly=yes",
                                  "UserKnownHostsFile=$keys/known_hosts"])),
                TK.text("ssh returned"), TK.end_turn()]
            prompt == "sudo on the server" && return [TK.mcp_call("bt_sudo"; id = "remote-sudo", real_process = true,
                arguments = Dict{String,Any}("id" => "remote-root-1", "ssh" => "master-1", "seconds" => 120,
                    "argv" => ["sh", "-c", "echo ran-on-the-server"], "label" => "Server job")),
                TK.text("remote sudo returned"), TK.end_turn()]
            return [TK.text("Received: $prompt"), TK.end_turn()]
        end
        # The worker reads which sudo to run when it starts.
        s = withenv(() -> TK.dev_server(; agent), "BONITOAGENTS_SUDO_PROGRAM" => fake)
        pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
        prompt_card(kind) = "$pane.querySelector('.bt-prompt-card[data-prompt-kind=\"$kind\"]')"
        tool_card(id) = "$pane.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
        summary_has(id, text) = "!!$(tool_card(id))?.querySelector('.bt-tool-summary')?.textContent.includes($(repr(text)))"
        says(t) = "[...$pane.querySelectorAll('.bt-agent-msg')].some(e => e.textContent.includes($(repr(t))))"
        # What a user does: type into the card's field and press its main button.
        # A sudo card gets the password only from the stand-in.
        function sudo_answer(card, text)
            isfile(ran) || error("the stand-in sudo didn't run, so no password is typed")
            rm(ran)
            answer(card, text)
        end
        answer(card, text) = TK.eval_js(s, """(() => { const c = $card;
            c.querySelector('input').value = $(repr(text));
            c.querySelector('button[type=submit]').click(); return true; })()""")
        try
            TK.open_browser(s)
            TK.new_chat(s; title = "Passwords")

            @testset "sudo asks in the chat and runs once answered" begin
                TK.send_message(s, "sudo please")
                @test TK.wait_for(s, "the password card names the command",
                    "$(prompt_card("sudo"))?.querySelector('.bt-prompt-job')?.textContent === \"sh -c 'echo ran-as-root'\"";
                    timeout = 90, describe = "$pane.innerText")
                # The card is the job's state, not an event: a reload shows it again.
                TK.reload!(s)
                @test TK.wait_for(s, "the card is back after a reload", "!!$(prompt_card("sudo"))"; timeout = 30)
                # A long worker name wraps inside the card.
                @test TK.eval_js(s, "(() => { const t = $(prompt_card("sudo")).querySelector('.bt-permission-question'); return t.scrollWidth <= t.clientWidth; })()")
                TK.screenshot(s, joinpath(tempdir(), "bonitoagents-sudo-prompt.png"))
                sudo_answer(prompt_card("sudo"), password)
                @test TK.wait_for(s, "the card goes once answered", "!$(prompt_card("sudo"))"; timeout = 30)
                @test TK.wait_for(s, "the sudo call reports the command's success",
                    summary_has("sudo-call", "succeeded"); timeout = 60, describe = "$(tool_card("sudo-call"))?.innerText")
                @test TK.wait_for(s, "the agent got its result", says("sudo returned"); timeout = 30)
                @test TK.eval_js(s, "$(tool_card("sudo-call")).querySelector('.bt-tool-title').textContent") ==
                      "Run as root: Root job"
                # Nothing on the page holds the password.
                @test TK.eval_js(s, "document.documentElement.outerHTML.includes($(repr(password)))") == false
            end

            @testset "a refusal fails the job" begin
                TK.send_message(s, "sudo refused")
                @test TK.wait_for(s, "a second card", "!!$(prompt_card("sudo"))"; timeout = 60)
                TK.eval_js(s, "[...$(prompt_card("sudo")).querySelectorAll('button')].find(b => b.textContent === 'Deny').click(); true")
                @test TK.wait_for(s, "the refused call failed",
                    summary_has("sudo-refused", "failed"); timeout = 60, describe = "$(tool_card("sudo-refused"))?.innerText")
                @test TK.eval_js(s, "!$(prompt_card("sudo"))")
            end

            if daemon !== nothing
                @testset "ssh asks each question in the chat" begin
                    TK.send_message(s, "ssh please")
                    @test TK.wait_for(s, "the host key question",
                        "!!$(prompt_card("secret"))?.querySelector('.bt-prompt-text')?.textContent.includes('authenticity of host')";
                        timeout = 60, describe = "$pane.innerText")
                    @test TK.eval_js(s, "$(prompt_card("secret")).querySelector('.bt-prompt-job').textContent.endsWith('-- 127.0.0.1')")
                    TK.screenshot(s, joinpath(tempdir(), "bonitoagents-ssh-prompt.png"))
                    answer(prompt_card("secret"), "yes")
                    @test TK.wait_for(s, "the passphrase question",
                        "!!$(prompt_card("secret"))?.querySelector('.bt-prompt-text')?.textContent.includes('passphrase')";
                        timeout = 30, describe = "$pane.innerText")
                    answer(prompt_card("secret"), "hunter2")
                    @test TK.wait_for(s, "the connection is up",
                        summary_has("ssh-call", "connected"); timeout = 60, describe = "$(tool_card("ssh-call"))?.innerText")
                    @test TK.wait_for(s, "the master is a job in the taskbar",
                        "!!$pane.querySelector('.bt-process-task[data-process-id=\"master-1\"]')"; timeout = 30)
                    @test TK.eval_js(s, "document.documentElement.outerHTML.includes('hunter2')") == false
                end

                @testset "sudo on the server goes through that connection" begin
                    rm(ran; force = true)
                    TK.send_message(s, "sudo on the server")
                    @test TK.wait_for(s, "the card names the server",
                        "$(prompt_card("sudo"))?.querySelector('.bt-permission-question')?.textContent === 'Password to run as root on 127.0.0.1'";
                        timeout = 60, describe = "$pane.innerText")
                    @test TK.eval_js(s, "$(prompt_card("sudo")).querySelector('.bt-prompt-where').textContent.startsWith('through ssh from')")
                    TK.screenshot(s, joinpath(tempdir(), "bonitoagents-remote-sudo-prompt.png"))
                    sudo_answer(prompt_card("sudo"), password)
                    @test TK.wait_for(s, "the remote command ran",
                        summary_has("remote-sudo", "succeeded"); timeout = 60, describe = "$(tool_card("remote-sudo"))?.innerText")
                    @test TK.eval_js(s, "document.documentElement.outerHTML.includes($(repr(password)))") == false
                end
            end
            @test isempty(TK.js_errors(s))
        finally
            close(s)
            daemon === nothing || kill(daemon)
        end
    end
end
