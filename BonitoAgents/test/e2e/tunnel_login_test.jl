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
            "(document.body.textContent.match(/curl -fsSL \\S+\\/install.sh \\| BONITOAGENTS_WORKER_CREDENTIAL='w-[0-9a-f]+:[0-9a-f]+'/) || [false])[0]";
            timeout = 30)
        @test startswith(command, "curl -fsSL $(z.h.url)/install.sh")
        credential = match(r"'(w-[0-9a-f]+:[0-9a-f]+)'", command)[1]
        TK.add_worker!(z; name = "through-the-tunnel", credential)
        @test TK.wait_for(z, "the second worker online",
            "document.querySelectorAll('.bt-worker-cell .bt-dot-online').length === 2"; timeout = 120) == true

        # Someone invited: the invite page, their account, their first login with
        # an authenticator app confirmed by the code the admin reads them.
        TK.set_input(z, "input[type=text]", "lab"; placeholder = "groups (\"admins\" for an admin)")
        TK.click_text(z, "Create invite link")
        link = TK.wait_for(z, "the invite link",
            "(document.body.textContent.match(/https:\\/\\/\\S+?\\/invite\\/[0-9a-f]{64}/) || [false])[0]"; timeout = 30)
        @test startswith(link, z.h.url * "/invite/")
        b = TK.another_browser(z)
        TK.eval_js(b, "location.href = $(repr(link)); true")
        TK.wait_for(b, "the invite form", "!!document.querySelector('form input[name=name]')"; timeout = 30)
        TK.set_input(b, "input[name=name]", "carol")
        TK.set_input(b, "input[name=display_name]", "Carol C")
        TK.click(b, "form button[type=submit]")
        password = TK.wait_for(b, "the new password", "(document.querySelector('.pw') || {}).textContent || false";
                               timeout = 30)
        TK.eval_js(b, "location.href = $(repr(z.h.url * "/")); true")
        TK.register_authenticator!(z, b, "carol", password)
        @test TK.signed_in_as(b) == "Signed in as Carol C (carol); groups: lab."
        @test !any(in(("Accounts", "Invites")), TK.headings(b))

        # Logged out, it is the login page again.
        TK.logout!(z)
        @test TK.eval_js(z, "location.pathname.startsWith('/authelia')") == true
    finally
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end
