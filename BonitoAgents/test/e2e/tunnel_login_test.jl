# A server behind a tunnel, end to end (`dev_server(tunnel = true)`): the real
# Authelia, the server's own login gate (tunnel.jl), and in front a stand-in for
# cloudflared that does only what cloudflared does, bring HTTPS for one name to
# the server's plain port. Everything, the login page included, is under that
# one name; the workers come in through the tunnel too.
#
# Own dev server (NOT SharedServer's): the tunnel has to be in front.

@testitem "e2e:tunnel_login" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; tunnel = true)
    b = nothing
    try
        TK.open_browser(z)
        # Nobody gets the dashboard without logging in: the browser lands on the
        # login page, under the dashboard's own name.
        @test TK.wait_for(z, "the login page", "location.pathname.startsWith('/authelia')"; timeout = 30) == true
        @test startswith(TK.page_host(z), "bonito.localhost")

        # Nor does anything else, however it asks, from outside through the tunnel:
        host, port = match(r"https://([^:/]+):(\d+)", z.h.url).captures
        login_page = "302 https://$(host):$(port)/authelia/"
        curl(args...) = read(`curl -sk --resolve $(host):$(port):127.0.0.1 -o /dev/null
                                   -w "%{http_code} %{redirect_url}" $(args)`, String)
        # identity headers a client made up;
        @test startswith(curl("-H", "Remote-User: admin", "-H", "Remote-Groups: admins", z.h.url * "/"), login_page)
        # the routes open to anyone, spelled to lead somewhere else;
        for path in ("/invite/../", "/invite/%2e%2e/", "/install.sh/../", "/invite/..%2f..%2f", "//",
                     "/install.sh?/acp-log", "/w/../acp-log")
            @test startswith(curl("--path-as-is", z.h.url * path), login_page)
        end
        @test startswith(curl(z.h.url * "/install.sh"), "200")

        TK.login!(z)
        @test startswith(TK.page_host(z), "bonito.localhost")
        @test TK.wait_for(z, "the account card",
            "document.body.textContent.includes('Signed in as admin (admin)')"; timeout = 30) == true
        # The dev worker came in through the tunnel with its credential.
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        # What the browser fetched behind the login is its alone: a shared cache
        # in front (Cloudflare's) must not keep it.
        cache = TK.eval_js(z, """fetch(document.querySelector('script[src*="/assets/"]').src)
                                    .then(r => r.headers.get('cache-control'))""")
        @test startswith(cache, "private") && !occursin("public", cache)
        @test isempty(TK.js_errors(z))

        # "Add worker": the command carries the tunnel's address and a credential,
        # and a second machine comes in with it, through the tunnel.
        TK.eval_js(z, "document.querySelector('.bt-install-details').open = true; true")
        TK.click_text(z, "Add worker")
        command = TK.wait_for(z, "the install command",
            "(document.body.textContent.match(/curl -fsSL \\S+\\/install.sh \\| sh -s w-[0-9a-f]+:[0-9a-f]+/) || [false])[0]";
            timeout = 30)
        @test startswith(command, "curl -fsSL $(z.h.url)/install.sh")
        credential = match(r"sh -s (w-[0-9a-f]+:[0-9a-f]+)", command)[1]
        TK.add_worker!(z; name = "through-the-tunnel", credential)
        @test TK.wait_for(z, "the second worker online",
            "document.querySelectorAll('.bt-worker-cell .bt-dot-online').length === 2"; timeout = 120) == true

        # Someone invited, with a passkey in their password manager: the invite
        # page makes their account, and one button signs them in and makes the
        # passkey. No password to copy, no code, no settings page.
        TK.to_settings(z)
        TK.pick_groups!(z, TK.invites_js("sec.querySelector('.bt-group-pick')"), ["lab"])
        TK.click_text(z, "Create invite link")
        link = TK.wait_for(z, "the invite link",
            "(document.body.textContent.match(/https:\\/\\/\\S+?\\/invite\\/[0-9a-f]{64}/) || [false])[0]"; timeout = 30)
        @test startswith(link, z.h.url * "/invite/")
        b = TK.another_browser(z)
        carol_device = TK.add_passkey_device!(b)
        TK.eval_js(b, "location.href = $(repr(link)); true")
        TK.wait_for(b, "the invite form", "!!document.querySelector('form input[name=name]')"; timeout = 30)
        TK.set_input(b, "input[name=name]", "carol")
        TK.set_input(b, "input[name=display_name]", "Carol C")
        TK.click(b, "form button[type=submit]")
        TK.wait_for(b, "the passkey button", "!!document.getElementById('create-passkey')"; timeout = 30)
        # Whoever cannot use a passkey has the password and authenticator, folded away.
        carol = TK.invite_login(b, "carol")
        @test length(carol.password) >= 16
        @test TK.eval_js(b, "!document.querySelector('details').open") == true
        TK.create_passkey_from_invite!(b)
        @test TK.signed_in_as(b) == "Signed in as Carol C (carol); groups: lab."
        @test !any(in(("Accounts", "Invites")), TK.headings(b))
        @test TK.passkeys(b, carol_device) == [(host, "carol")]
        TK.logout!(b)
        TK.passkey_login!(b)
        @test TK.signed_in_as(b) == "Signed in as Carol C (carol); groups: lab."

        # The admin adds a passkey on their account card (Proton Pass, a security
        # key): they stay on the dashboard, and from then on it alone signs in.
        device = TK.add_passkey_device!(z)
        @test TK.reload!(z) == :dashboard           # the page now trusts this machine's CA
        @test TK.wait_for(z, "no passkey yet", "document.querySelector('.bt-passkey-list').textContent.includes('No passkey yet')";
                          timeout = 30) == true
        TK.add_passkey!(z; name = "Proton Pass")
        @test TK.wait_for(z, "the passkey listed", "document.querySelectorAll('.bt-passkey-row').length === 1"; timeout = 30) == true
        @test TK.listed_passkeys(z) == ["Proton Pass"]
        @test TK.passkeys(z, device) == [(host, "admin")]
        TK.logout!(z)
        @test TK.eval_js(z, "location.pathname.startsWith('/authelia')") == true
        TK.passkey_login!(z)
        @test TK.wait_for(z, "the account card",
            "document.body.textContent.includes('Signed in as admin (admin)')"; timeout = 30) == true
        @test TK.wait_for(z, "the passkey used", "document.querySelector('.bt-passkey-row').textContent.includes('last used')";
                          timeout = 30) == true
        # Removed, it is gone from the list.
        TK.eval_js(z, "window.confirm = () => true; document.querySelector('.bt-passkey-row button').click(); true")
        @test TK.wait_for(z, "the passkey removed", "document.querySelector('.bt-passkey-list').textContent.includes('No passkey yet')";
                          timeout = 30) == true

        # The login ends while the tab is open (here: logged out behind its back).
        # The tab says so when it next checks, instead of failing on the next
        # thing it loads. It never reloads itself to the login: that took what
        # was typed with it.
        @test TK.eval_js(z, """fetch('/authelia/api/logout', {method: 'POST',
            headers: {'Content-Type': 'application/json'}, body: '{}'}).then(r => r.status)""") == 200
        @test TK.eval_js(z, "!document.querySelector('.bt-login-ended.bt-conn-open')") == true
        TK.eval_js(z, "document.dispatchEvent(new Event('visibilitychange')); true")
        @test TK.wait_for(z, "the tab saying the login ended",
            "!!document.querySelector('.bt-login-ended.bt-conn-open')"; timeout = 30) == true
        TK.click(z, ".bt-login-ended .bt-conn-reload")   # the login opens in a new tab
        sleep(1)
        @test TK.eval_js(z, "location.pathname") == "/"
        # Logged in again (in "another tab": Authelia's API, same browser), the
        # card goes away by itself once this tab is looked at again.
        TK.api_login!(z)
        TK.eval_js(z, "document.dispatchEvent(new Event('visibilitychange')); true")
        @test TK.wait_for(z, "the card gone once logged in again",
            "!document.querySelector('.bt-login-ended.bt-conn-open')"; timeout = 30) == true
    finally
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end
