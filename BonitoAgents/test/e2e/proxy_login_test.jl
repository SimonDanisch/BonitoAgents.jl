# The deployment's login stack, end to end: the real Caddy and the real Authelia
# in front of a dev server (`dev_server(proxy = true)`: Caddy's own certificate
# authority, names under `.localhost`), exactly the configuration the server
# renders for an install. A person gets in through Authelia's form and a one-time
# code; the worker gets in through Caddy with its credential, over TLS.
#
# Own dev servers (NOT SharedServer's): each item needs the proxy in front.

@testitem "e2e:proxy_login" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    using HTTP
    z = TK.dev_server(; proxy = true)
    try
        TK.open_browser(z)
        # Nobody gets the dashboard without logging in: the browser lands on the portal.
        @test TK.wait_for(z, "Authelia's portal", "location.host.startsWith('auth.')"; timeout = 30) == true

        # Nor does anything else, however it asks. From outside, through Caddy:
        host, port = match(r"https://([^:/]+):(\d+)", z.h.url).captures
        portal = "302 https://auth.$(host):$(port)/"
        curl(args...) = read(`curl -sk --resolve $(host):$(port):127.0.0.1 -o /dev/null
                                   -w "%{http_code} %{redirect_url}" $(args)`, String)
        # identity headers a client made up;
        @test startswith(curl("-H", "Remote-User: admin", "-H", "Remote-Groups: admins",
                              "-H", "X-BonitoAgents-Proxy: forged", z.h.url * "/"), portal)
        # the routes open to anyone, spelled to lead somewhere else;
        for path in ("/invite/../", "/invite/%2e%2e/", "/install.sh/../", "/invite/..%2f..%2f", "//")
            @test startswith(curl("--path-as-is", z.h.url * path), portal)
        end
        # a worker without its credential, or with a wrong one.
        @test startswith(curl(z.h.url * "/w"), "401")
        @test startswith(curl("-u", "w-nope:wrong", z.h.url * "/w"), "401")
        @test startswith(curl(z.h.url * "/install.sh"), "200")
        # And the server itself, past the proxy: whatever a request claims, no identity.
        direct = HTTP.get("http://127.0.0.1:$(z.h.state.auth.config.port)/",
                          ["Remote-User" => "admin", "Remote-Groups" => "admins"]; status_exception = false)
        @test occursin("This server answers only through its login proxy", String(direct.body))

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
    b = nothing
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
        invites_js(expr) = """(() => { const h = [...document.querySelectorAll('h2')].find(h => h.textContent.trim() === 'Invites');
            const sec = h.closest('.bt-section').parentElement; return $(expr); })()"""
        invite_rows = invites_js("[...sec.querySelectorAll('.bt-admin-table tr')].filter(r => r.querySelector('button')).length")
        @test TK.wait_for(z, "the open invite listed", "$(invite_rows) === 1"; timeout = 30) == true

        # A second invite, revoked before anyone uses it.
        TK.click_text(z, "Create invite link")
        second = TK.wait_for(z, "the second link",
            "(() => { const m = document.body.textContent.match(/https:\\/\\/\\S+?\\/invite\\/[0-9a-f]{64}/); " *
            "return m && m[0] !== $(TK.json(link)) && m[0]; })()"; timeout = 30)
        @test TK.wait_for(z, "two open invites", "$(invite_rows) === 2"; timeout = 30) == true
        TK.eval_js(z, invites_js("""(() => { const rows = [...sec.querySelectorAll('.bt-admin-table tr')].filter(r => r.querySelector('button'));
            rows[rows.length - 1].querySelector('button').click(); return true; })()"""))
        @test TK.wait_for(z, "the invite revoked", "document.body.textContent.includes('invite revoked')"; timeout = 30) == true
        @test TK.wait_for(z, "one open invite", "$(invite_rows) === 1"; timeout = 30) == true
        # How long an invite lasts is a number of days, at least one.
        TK.set_input(z, "input[type=text][size='3']", "0")
        TK.click_text(z, "Create invite link")
        @test TK.wait_for(z, "the refusal", "document.body.textContent.includes('valid for: a number of days, at least 1')";
                          timeout = 30) == true

        # Carol, in a browser of her own, not logged in: the revoked link leads
        # nowhere; hers opens the invite page, which makes the account and shows
        # its password once.
        b = TK.another_browser(z)
        TK.eval_js(b, "location.href = $(repr(second)); true")
        @test TK.wait_for(b, "the revoked invite", "document.body.textContent.includes('This invite is not valid')";
                          timeout = 30) == true
        TK.eval_js(b, "location.href = $(repr(link)); true")
        TK.wait_for(b, "the invite form", "!!document.querySelector('form input[name=name]')"; timeout = 30)
        TK.set_input(b, "input[name=name]", "carol")
        TK.set_input(b, "input[name=display_name]", "Carol C")
        TK.click(b, "form button[type=submit]")
        carol = TK.invite_login(b, "carol")
        @test length(carol.password) >= 16
        # The same link again: used up.
        TK.eval_js(b, "location.href = $(repr(link)); true")
        @test TK.wait_for(b, "the used-up invite", "document.body.textContent.includes('This invite is not valid')";
                          timeout = 30) == true

        # Her first login, with the password and the authenticator her invite page
        # showed: no mail, no code to pass on. She sees her own account only: no
        # admin sections, none of the admin's workers.
        TK.eval_js(b, "location.href = $(repr(z.h.url * "/")); true")
        TK.login!(b, carol)
        @test TK.signed_in_as(b) == "Signed in as Carol C (carol); groups: lab."
        @test TK.wait_for(b, "the stats strip", "document.body.textContent.includes('/0 workers online')"; timeout = 30) == true
        @test !any(in(("Accounts", "Invites", "Agent adapters")), TK.headings(b))
        @test TK.eval_js(b, "document.querySelectorAll('.bt-worker-cell').length") == 0

        # The admin shares the worker with "lab" on its card. Carol sees it and
        # may start chats there; managing it stays with the admin.
        TK.share_worker_ui!(z, "lab")
        @test TK.reload!(b) == :dashboard
        @test TK.wait_for(b, "the shared worker", "!!document.querySelector('.bt-worker-cell .bt-dot-online')";
                          timeout = 60) == true
        @test TK.eval_js(b, "!!document.querySelector('.bt-worker-cell .bt-card-remove')") == false
        @test TK.eval_js(b, "!!document.querySelector('.bt-worker-cell .bt-card-name-edit')") == false
        @test TK.eval_js(b, "[...document.querySelectorAll('.bt-worker-cell button')].some(b => b.textContent.includes('Project'))") == true
        # And her authenticator keeps working: out and in again with it.
        TK.logout!(b)
        TK.login!(b, carol)
        @test TK.signed_in_as(b) == "Signed in as Carol C (carol); groups: lab."
    finally
        b === nothing || TK.close_browser!(b)
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
