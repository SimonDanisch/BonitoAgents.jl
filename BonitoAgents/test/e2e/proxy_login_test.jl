# The deployment's login stack, end to end: the real Caddy and the real Authelia
# in front of a dev server (`dev_server(proxy = true)`: Caddy's own certificate
# authority, names under `.localhost`), exactly the configuration the server
# renders for an install. A person gets in through Authelia's form and a one-time
# code; the worker gets in through Caddy with its credential, over TLS.
#
# Own dev servers (NOT SharedServer's): each item needs the proxy in front.

@testitem "e2e:proxy_login" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; proxy = true)
    try
        TK.open_browser(z)
        # Nobody gets the dashboard without logging in: the browser lands on the portal.
        @test TK.wait_for(z, "Authelia's portal", "location.host.startsWith('auth.')"; timeout = 30) == true
        TK.login!(z)
        @test startswith(TK.page_host(z), "bonito.localhost")
        @test TK.wait_for(z, "the account card",
            "document.body.textContent.includes('Signed in as admin (admin)')"; timeout = 30) == true
        @test TK.wait_for(z, "the admin's sections",
            "['Accounts', 'Invites'].every(t => [...document.querySelectorAll('h2')].some(h => h.textContent.trim() === t))") == true
        # The worker reached the server through Caddy, with its credential, over TLS.
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        TK.logout!(z)
        @test startswith(TK.page_host(z), "auth.")
    finally
        close(z)
    end
end

@testitem "e2e:proxy_invite" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; proxy = true)
    try
        TK.open_browser(z)
        TK.login!(z)

        # The admin invites someone into the "lab" group.
        TK.set_input(z, "input[type=text]", "lab"; placeholder = "groups (\"admins\" for an admin)")
        # One click, one invite: each click makes another.
        TK.click_text(z, "Create invite link")
        link = TK.wait_for(z, "the invite link",
            "(document.body.textContent.match(/https:\\/\\/\\S+?\\/invite\\/[0-9a-f]{64}/) || [false])[0]"; timeout = 30)
        @test startswith(link, z.h.url * "/invite/")
        TK.logout!(z)

        # The invite page is open to anyone; it makes the account and shows its password once.
        TK.eval_js(z, "location.href = $(repr(link)); true")
        TK.wait_for(z, "the invite form", "!!document.querySelector('form input[name=name]')"; timeout = 30)
        TK.set_input(z, "input[name=name]", "carol")
        TK.set_input(z, "input[name=display_name]", "Carol C")
        TK.click(z, "form button[type=submit]")
        password = TK.wait_for(z, "the new password", "(document.querySelector('.pw') || {}).textContent || false";
                               timeout = 30)
        @test length(password) >= 16
        # The same link again: used up.
        TK.eval_js(z, "location.href = $(repr(link)); true")
        @test TK.wait_for(z, "the used-up invite", "document.body.textContent.includes('This invite is not valid')";
                          timeout = 30) == true

        # Carol logs in (her authenticator app registered with Authelia) and sees
        # her own account only: no admin sections, and none of the admin's workers.
        carol = TK.Login("carol", password, TK.seed_totp!(z, "carol"))
        TK.eval_js(z, "location.href = $(repr(z.h.url * "/")); true")
        TK.login!(z, carol)
        @test TK.wait_for(z, "carol's account card",
            "document.body.textContent.includes('Signed in as Carol C (carol); groups: lab.')"; timeout = 30) == true
        @test TK.wait_for(z, "the stats strip", "document.body.textContent.includes('/0 workers online')"; timeout = 30) == true
        @test TK.eval_js(z, "[...document.querySelectorAll('h2')].some(h => ['Accounts', 'Invites'].includes(h.textContent.trim()))") == false
        @test TK.eval_js(z, "document.querySelectorAll('.bt-worker-cell').length") == 0
        TK.logout!(z)

        # The admin shares the worker with "lab" on its card.
        TK.eval_js(z, "location.href = $(repr(z.h.url * "/")); true")
        TK.login!(z)
        TK.wait_for(z, "the worker's sharing field", "!!document.querySelector('.bt-worker-cell input[placeholder=groups]')";
                    timeout = 60)
        TK.set_input(z, ".bt-worker-cell input[placeholder=groups]", "lab")
        TK.eval_js(z, """(() => { const el = document.querySelector('.bt-worker-cell input[placeholder=groups]');
            el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return true; })()""")
        @test TK.wait_for(z, "the share saved", "document.querySelector('.bt-worker-cell').textContent.includes('shared')";
                          timeout = 30) == true
        TK.logout!(z)

        # Now carol sees it and may start chats there; managing it stays with the admin.
        TK.eval_js(z, "location.href = $(repr(z.h.url * "/")); true")
        TK.login!(z, carol)
        @test TK.wait_for(z, "the shared worker", "!!document.querySelector('.bt-worker-cell .bt-dot-online')";
                          timeout = 60) == true
        @test TK.eval_js(z, "!!document.querySelector('.bt-worker-cell .bt-card-remove')") == false
        @test TK.eval_js(z, "!!document.querySelector('.bt-worker-cell .bt-card-name-edit')") == false
        @test TK.eval_js(z, "[...document.querySelectorAll('.bt-worker-cell button')].some(b => b.textContent.includes('Project'))") == true
    finally
        close(z)
    end
end

@testitem "e2e:proxy_worker_credentials" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; proxy = true)
    try
        TK.open_browser(z)
        TK.login!(z)
        TK.wait_for(z, "the worker online", "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60)

        # Watch the worker from here on: issuing a credential reloads Caddy, which
        # must not drop the connections it carries (the worker's, this tab's).
        TK.eval_js(z, """(() => { window.__btWentOffline = false;
            window.__btWatch = setInterval(() => { if (document.querySelector('.bt-worker-cell .bt-dot-offline'))
                window.__btWentOffline = true; }, 100); return true; })()""")
        # "Add worker" issues a credential and shows the command that carries it, once.
        TK.eval_js(z, "document.querySelector('.bt-install-details').open = true; true")
        # One click, one credential: each click issues another.
        TK.click_text(z, "Add worker")
        command = TK.wait_for(z, "the install command",
            "(document.body.textContent.match(/BONITOAGENTS_WORKER_CREDENTIAL='w-[0-9a-f]+:[0-9a-f]+'/) || [false])[0]";
            timeout = 30)
        @test occursin("BONITOAGENTS_WORKER_CREDENTIAL='w-", command)
        @test isempty(TK.js_errors(z))
        sleep(6)   # Caddy rereads its file within ~2 s; a dropped worker takes 5 s to return
        @test TK.eval_js(z, "clearInterval(window.__btWatch), window.__btWentOffline") == false
        # Two credentials now: the dev worker's, in use, and the new one, not yet.
        @test TK.wait_for(z, "both credentials listed",
            "document.querySelectorAll('.bt-install-details .bt-admin-table tr').length === 3"; timeout = 30) == true

        # Revoking the dev worker's credential disconnects it, and Caddy keeps it out.
        TK.eval_js(z, """(() => {
            const row = [...document.querySelectorAll('.bt-install-details .bt-admin-table tr')]
                .find(r => r.cells.length > 1 && r.cells[1].textContent !== 'not connected yet' && r.querySelector('button'));
            row.querySelector('button').click(); return true; })()""")
        @test TK.wait_for(z, "the worker offline", "!!document.querySelector('.bt-worker-cell .bt-dot-offline')";
                          timeout = 30) == true
        sleep(8)   # a worker retries every 5 s: it must still be out
        @test TK.eval_js(z, "!!document.querySelector('.bt-worker-cell .bt-dot-offline')") == true
    finally
        close(z)
    end
end
