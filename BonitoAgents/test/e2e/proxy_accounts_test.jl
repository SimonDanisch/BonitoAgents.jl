# Accounts, end to end, behind the real Caddy and Authelia (`dev_server(proxy =
# true)`): what an admin does on the Accounts section, and what the person on the
# other end gets, logged in at the same time in a browser of their own. Nothing
# here is set up behind the UI's back; Authelia decides every login.
#
# Own dev servers (NOT SharedServer's): each item needs the proxy in front.

@testitem "e2e:proxy_accounts" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; proxy = true)
    b = nothing
    refused = "Incorrect username or password"
    try
        TK.open_browser(z)
        TK.login!(z)

        # An admin adds an account; its password is shown once.
        password = TK.add_account_ui!(z, "dave"; display_name = "Dave D", groups = "lab")
        @test length(password) >= 16
        @test TK.eval_js(z, TK.accounts_js("""[...sec.querySelectorAll('.bt-admin-table tr')].some(r =>
            r.cells[0]?.textContent.trim() === 'dave' && r.textContent.includes('member') && r.textContent.includes('active'))""")) == true

        # Dave logs in, in a browser of his own, while the admin stays logged in.
        dave = TK.Login("dave", password, TK.seed_totp!(z, "dave"))
        b = TK.another_browser(z)
        TK.login!(b, dave)
        @test TK.signed_in_as(b) == "Signed in as Dave D (dave); groups: lab."
        @test !any(in(("Accounts", "Invites", "Agent adapters")), TK.headings(b))
        @test "Accounts" in TK.headings(z)

        # Made an admin: his open tab closes (an open websocket is never checked
        # again), and the next load comes with the admin's sections.
        TK.account_action!(z, "dave", "Make admin")
        TK.account_status(z, "dave is an admin")
        @test TK.wait_for(b, "dave's tab closed", "document.body.textContent.includes('The link to the server dropped')";
                          timeout = 30) == true
        @test TK.reload!(b) == :dashboard
        @test TK.signed_in_as(b) == "Signed in as Dave D (dave); groups: lab, admins."
        @test "Accounts" in TK.headings(b)
        TK.account_action!(z, "dave", "Make member")
        TK.account_status(z, "dave is a member")
        @test TK.reload!(b) == :dashboard
        @test !("Accounts" in TK.headings(b))

        # A new password from the admin: the old one stops working.
        TK.account_action!(z, "dave", "New password")
        TK.account_status(z, "new password for dave")
        renewed = String(TK.wait_for(z, "dave's new password",
            TK.accounts_js("(sec.querySelector('.bt-admin-secret').textContent.match(/Password for dave, shown only now: (\\S+)/) || [])[1] !== $(TK.json(password)) && " *
                           "sec.querySelector('.bt-admin-secret').textContent.match(/Password for dave, shown only now: (\\S+)/)[1]");
            timeout = 30))
        TK.logout!(b)
        @test occursin(refused, TK.login_refused(b, dave))
        dave = TK.Login("dave", renewed, dave.secret)
        TK.login!(b, dave)
        @test TK.signed_in_as(b) == "Signed in as Dave D (dave); groups: lab."

        # And one of his own, from his account card.
        TK.eval_js(b, """(() => { window.confirm = () => true;
            [...document.querySelectorAll('button')].find(x => x.textContent.trim() === 'New password').click(); return true; })()""")
        own = String(TK.wait_for(b, "his new password",
            "[...document.querySelectorAll('.bt-admin-secret')].map(e => (e.textContent.match(/Your new password, shown only now: (\\S+)/) || [])[1]).find(p => p) || false";
            timeout = 30))
        TK.logout!(b)
        dave = TK.Login("dave", own, dave.secret)
        TK.login!(b, dave)

        # Disabled while his tab is open: the tab closes, and Authelia turns him
        # away from then on.
        TK.account_action!(z, "dave", "Disable")
        TK.account_status(z, "dave disabled; their open tabs were closed")
        @test TK.wait_for(b, "dave's tab closed", "document.body.textContent.includes('The link to the server dropped')";
                          timeout = 30) == true
        @test TK.reload!(b) == :portal
        @test occursin(refused, TK.login_refused(b, dave))
        TK.account_action!(z, "dave", "Enable")
        TK.account_status(z, "dave enabled")
        TK.login!(b, dave)
        @test TK.signed_in_as(b) == "Signed in as Dave D (dave); groups: lab."

        # Two changes at once both reach Authelia. It ignores a change to its
        # users file within half a second of its last reread; the disable used to
        # land in that half second, and Authelia kept letting dave in.
        TK.set_account_groups_ui!(z, "dave", "gpu")
        TK.account_action!(z, "dave", "Disable")
        TK.account_status(z, "dave disabled")
        @test TK.reload!(b) == :portal
        @test occursin(refused, TK.login_refused(b, dave))

        # Removed: gone for Authelia too.
        TK.account_action!(z, "dave", "Remove")
        TK.account_status(z, "dave removed")
        @test !TK.eval_js(z, TK.accounts_js("[...sec.querySelectorAll('.bt-admin-table tr')].some(r => r.cells[0]?.textContent.trim() === 'dave')"))
        @test occursin(refused, TK.login_refused(b, dave))

        # Nobody locks themselves out: the admin cannot disable or demote
        # themselves, and stays logged in.
        TK.account_action!(z, "admin", "Disable")
        @test occursin("you cannot do that to your own account", TK.account_status(z, "your own account"))
        @test TK.reload!(z) == :dashboard
        @test "Accounts" in TK.headings(z)
        @test isempty(TK.js_errors(z))
    finally
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end

# What a member sees, with real chats: their own, never anyone else's, on a
# worker shared with their group; none of the server-wide controls.
@testitem "e2e:proxy_member_isolation" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    z = TK.dev_server(; proxy = true, agent = p -> [TK.text("echo: " * p), TK.end_turn()])
    b = nothing
    private = nothing
    try
        TK.open_browser(z)
        TK.login!(z)
        TK.share_worker_ui!(z, "lab")
        admin_chat = TK.new_chat(z; cwd = mktempdir(; prefix = "admins-chat-"))
        TK.send_message(z, "from the admin")
        @test TK.wait_for(z, "the admin's reply", "document.body.textContent.includes('echo: from the admin')"; timeout = 60) == true
        # Server-wide controls are the admin's.
        @test TK.eval_js(z, "!!document.querySelector('.bt-header-devmode') && !!document.querySelector('.bt-header-remote')") == true

        TK.to_dashboard(z)
        password = TK.add_account_ui!(z, "erin"; groups = "lab")
        erin = TK.Login("erin", password, TK.seed_totp!(z, "erin"))
        b = TK.another_browser(z)
        TK.login!(b, erin)
        @test TK.signed_in_as(b) == "Signed in as erin (erin); groups: lab."
        # The shared worker is there; the admin's chat is not, anywhere.
        @test TK.wait_for(b, "the shared worker", "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        on_page(s, pid) = TK.eval_js(s, "!!document.querySelector('.bt-side-item[data-project-id=\"$(pid)\"]')") === true
        @test !on_page(b, admin_chat)
        @test TK.eval_js(b, "document.body.textContent.includes('admins-chat-')") == false
        @test TK.eval_js(b, "!!document.querySelector('.bt-debug-btn')") == false

        # Her own chat on it.
        erins_chat = TK.new_chat(b; cwd = mktempdir(; prefix = "erins-chat-"))
        TK.send_message(b, "from erin")
        @test TK.wait_for(b, "erin's reply", "document.body.textContent.includes('echo: from erin')"; timeout = 60) == true
        @test TK.eval_js(b, "!!document.querySelector('.bt-header-devmode') || !!document.querySelector('.bt-header-remote')") == false
        @test !on_page(b, admin_chat)

        # The routes keyed by a chat answer her for hers only, and for the
        # admin's as if it did not exist.
        fetch_(s, path) = TK.eval_js(s, "fetch($(TK.json(path))).then(r => r.text().then(t => r.status + ' ' + t.slice(0, 200)))")
        @test startswith(fetch_(b, "/acp-log/$(erins_chat)"), "200")
        @test startswith(fetch_(b, "/acp-log/$(admin_chat)"), "404 unknown project")
        @test startswith(fetch_(b, "/download/$(admin_chat)?path=x.txt"), "404 unknown project")
        @test startswith(fetch_(b, "/attachment/$(admin_chat)?file=a.png"), "404 unknown project")
        index = fetch_(b, "/acp-log")
        @test occursin(erins_chat, index) && !occursin(admin_chat, index)

        # A second worker, the admin's and shared with nobody, added the way a
        # new machine is: with the credential its install command carries.
        TK.eval_js(z, "document.querySelector('.bt-install-details').open = true; true")
        TK.click_text(z, "Add worker")
        credential = String(TK.wait_for(z, "the install command's credential",
            "(document.body.textContent.match(/BONITOAGENTS_WORKER_CREDENTIAL='(w-[0-9a-f]+:[0-9a-f]+)'/) || [false, false])[1]";
            timeout = 30))
        private = TK.add_worker!(z; name = "private", credential)
        card_online(name) = """[...document.querySelectorAll('.bt-worker-cell')].some(c =>
            ((c.querySelector('input.bt-card-name') || {}).value || c.textContent).includes($(TK.json(name)))
            && !!c.querySelector('.bt-dot-online'))"""
        @test TK.wait_for(z, "the private worker online", card_online("private"); timeout = 120) == true
        # Not hers: not on her dashboard, and nowhere her chat could move to. The
        # admin's chat could.
        @test TK.reload!(b) == :dashboard
        @test TK.eval_js(b, "document.querySelectorAll('.bt-worker-cell').length") == 1
        continue_on(s, pid) = begin
            TK.eval_js(s, "document.querySelector('.bt-side-item[data-project-id=\"$(pid)\"]').click(); true")
            TK.wait_for(s, "the chat header", "!!document.querySelector('.bt-chatpane[data-pane-pid=\"$(pid)\"] .bt-menu-trigger')";
                        timeout = 60)
            sleep(1.0)
            String.(TK.eval_js(s, "[...document.querySelectorAll('.bt-chatpane[data-pane-pid=\"$(pid)\"] .bt-menu-continue')].map(b => b.textContent.trim())"))
        end
        @test isempty(continue_on(b, erins_chat))
        @test TK.reload!(z) == :dashboard
        @test continue_on(z, admin_chat) == ["private"]
        TK.to_dashboard(z)

        # The admin sees both chats, and she only hers.
        @test TK.reload!(z) == :dashboard
        @test TK.wait_for(z, "both chats in the admin's sidebar",
            "!!document.querySelector('.bt-side-item[data-project-id=\"$(admin_chat)\"]') && " *
            "!!document.querySelector('.bt-side-item[data-project-id=\"$(erins_chat)\"]')"; timeout = 30) == true
        @test TK.reload!(b) == :dashboard
        @test TK.wait_for(b, "her chat in her sidebar",
            "!!document.querySelector('.bt-side-item[data-project-id=\"$(erins_chat)\"]')"; timeout = 30) == true
        @test !on_page(b, admin_chat)
        @test startswith(fetch_(z, "/acp-log/$(erins_chat)"), "200")
        @test isempty(TK.js_errors(b))
    finally
        private === nothing || TK.kill_worker!(private)
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end
