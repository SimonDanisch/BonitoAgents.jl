# A server on a network it trusts, without the login proxy (`NetworkAuth`,
# `bonito-agents server --host 0.0.0.0`), end to end: the dashboard opens with no
# login, and workers join with the credential "Add worker" issues, checked by the
# server itself. (`dev_server(network = true)` runs it on localhost.)

@testitem "e2e:network_mode" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; network = true, agent = p -> [TK.text("echo: " * p), TK.end_turn()])
    second = stranger = nothing
    try
        # No login: straight to the dashboard, which has no accounts to manage.
        TK.open_browser(z)
        @test TK.wait_for(z, "the dashboard", "!!document.querySelector('.bt-dash')"; timeout = 30) == true
        @test !any(in(("Your account", "Accounts", "Invites")), TK.headings(z))
        # The dev server's own worker came in with its credential.
        @test TK.wait_for(z, "the worker online", "!!document.querySelector('.bt-worker-cell .bt-dot-online')";
                          timeout = 60) == true

        # "Add worker" issues a credential and shows the command that carries it.
        TK.eval_js(z, "document.querySelector('.bt-install-details').open = true; true")
        TK.click_text(z, "Add worker")
        command = String(TK.wait_for(z, "the install command",
            "(document.body.textContent.match(/curl -fsSL \\S+\\/install\\.sh \\| sh -s w-[0-9a-f]+:[0-9a-f]+/) || [false])[0]";
            timeout = 30))
        @test occursin(z.h.url * "/install.sh", command)
        credential = match(r"sh -s (w-[0-9a-f]+:[0-9a-f]+)", command)[1]

        # A machine that runs it joins; one with a made-up credential does not.
        second = TK.add_worker!(z; name = "second", credential)
        stranger = TK.add_worker!(z; name = "stranger", credential = first(split(credential, ':')) * ":" * "0"^48)
        card_online(name) = """[...document.querySelectorAll('.bt-worker-cell')].some(c =>
            ((c.querySelector('input.bt-card-name') || {}).value || '').includes($(TK.json(name)))
            && !!c.querySelector('.bt-dot-online'))"""
        @test TK.wait_for(z, "the second worker online", card_online("second"); timeout = 120) == true
        sleep(5)
        @test TK.eval_js(z, "[...document.querySelectorAll('.bt-worker-cell input.bt-card-name')].some(i => i.value === 'stranger')") == false

        # A chat on it works as on any server.
        TK.new_chat(z; cwd = mktempdir(), worker = "second")
        TK.send_message(z, "hello")
        @test TK.wait_for(z, "the reply", "document.body.textContent.includes('echo: hello')"; timeout = 60) == true

        # Revoking its credential disconnects it, and it stays out.
        TK.to_dashboard(z)
        TK.eval_js(z, "document.querySelector('.bt-install-details').open = true; true")
        TK.eval_js(z, """(() => { const row = [...document.querySelectorAll('.bt-install-details .bt-admin-table tr')]
            .find(r => r.cells.length > 1 && r.cells[1].textContent.includes('second'));
            row.querySelector('button').click(); return true; })()""")
        @test TK.wait_for(z, "the second worker offline", "!($(card_online("second")))"; timeout = 30) == true
        sleep(8)   # a worker retries every 5 s: it must still be out
        @test TK.eval_js(z, card_online("second")) == false
        @test isempty(TK.js_errors(z))
    finally
        second === nothing || TK.kill_worker!(second)
        stranger === nothing || TK.kill_worker!(stranger)
        close(z)
    end
end
