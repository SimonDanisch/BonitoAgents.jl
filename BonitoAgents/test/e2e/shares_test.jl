# Shared links, end to end behind a tunnel (`dev_server(tunnel = true)`: the
# real Authelia and the server's own login gate), the way they are deployed:
#
#   1. the agent shares a markdown file and an app file (`bt_share`, the real
#      MCP process on the worker); the second one with a password;
#   2. someone who is NOT logged in opens the markdown link: the page, the image
#      it embeds, a video for `![](clip.mp4)`; the file next to it that the page
#      does not use is not reachable, nor is anything behind the login;
#   3. they open the app link: the password first, then the app live from the
#      worker's share host, and it reacts to a click;
#   4. the owner ends the markdown link in Settings, and it is gone.
#
# Own dev server (NOT SharedServer's): the tunnel has to be in front.
@testitem "e2e:shares" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    import BonitoAgents as BT
    using Base64: base64decode

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    # The link a finished bt_share card names (its body expanded once).
    card_link(id) = """(() => {
        const c = $(card(id)); if (!c) return false;
        const st = c.querySelector('.bt-tool-status')?.textContent || '';
        if (!(st === 'completed' || st === 'failed')) return false;
        const h = c.querySelector('.bt-tool-header');
        if (h && !c.dataset.probeExpanded) {
            c.dataset.probeExpanded = '1';
            if (h.dataset.expanded !== 'true') h.click();
            return false;
        }
        const m = (c.querySelector('.bt-tool-body')?.innerText || '').match(/https:\\/\\/\\S+?\\/s\\/[0-9a-f]{32}\\//);
        return m ? m[0] : false; })()"""

    z = TK.dev_server(; tunnel = true, agent = _ -> [TK.end_turn()])
    b = nothing
    try
        TK.open_browser(z)
        TK.login!(z)
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true
        state = z.h.state

        cwd = mkpath(joinpath(mktempdir(), "sharedproj"))
        mkpath(joinpath(cwd, "figs"))
        write(joinpath(cwd, "figs", "dot.png"), base64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        write(joinpath(cwd, "secret.txt"), "not for the link\n")
        write(joinpath(cwd, "notes.md"), "# Notes\n\nShared from the file panel.\n")
        write(joinpath(cwd, "report.md"), """
            # Quarterly report

            ![a dot](figs/dot.png)

            ![the clip](clip.mp4)

            <script>document.title = 'scripted'</script>
            """)
        write(joinpath(cwd, "app.jl"), join([
            "using Bonito, Markdown",
            "App() do",
            "    clicks = Observable(0)",
            raw"    more = Bonito.Button(\"more\")",
            "    on(_ -> clicks[] += 1, more.value)",
            raw"    DOM.div(md\"\"\"",
            "    # Live report",
            "",
            raw"    $(more) clicks: $(map(n -> string(\"n=\", n), clicks))",
            raw"    \"\"\"; class = \"share-probe\")",
            "end"], "\n"))
        pid = TK.new_chat(z; cwd = cwd)

        # ── 1. the agent shares both ─────────────────────────────────────────
        z.agent_fn[] = _ -> [TK.mcp_call("bt_share"; real_process = true, id = "sh-md", path = "report.md"),
                             TK.mcp_call("bt_share"; real_process = true, id = "sh-app", path = "app.jl",
                                         password = "open sesame"),
                             TK.end_turn()]
        TK.send_message(z, "share the report and the app")
        md_url = TK.wait_for(z, "the markdown link", card_link("sh-md"); timeout = 120)
        # The app is evaluated once before its link is handed out: a share host
        # starts on the worker, then Julia with Bonito in it.
        app_url = TK.wait_for(z, "the app link", card_link("sh-app"); timeout = 900)
        @test startswith(md_url, z.h.url * "/s/") && startswith(app_url, z.h.url * "/s/")
        @test length(state.shares.links[]) == 2

        # The user shares a file themselves: its panel's ↗ makes the link and
        # puts it in the panel's status line.
        notes = joinpath(cwd, "notes.md")
        panel = ".bw-ws-panel[data-panel-id=\"file:$(notes)\"]"
        TK.eval_js(z, """(() => { document.querySelector('.bt-messages').__bt_chat.comm.notify(
            {type: 'edit_file', path: $(TK.json(notes))}); return true; })()""")
        # Wired once the panel's script ran (it marks the active view button).
        @test TK.wait_for(z, "the notes panel with its share button, wired",
            "!!document.querySelector('$(panel) .bt-fv-act[data-fv-action=share]') && " *
            "!!document.querySelector('$(panel) .bt-fv-seg[data-active=\"1\"]')"; timeout = 60) == true
        TK.eval_js(z, "document.querySelector('$(panel) .bt-fv-act[data-fv-action=share]').click(); true")
        notes_url = TK.wait_for(z, "the panel names the link",
            "((document.querySelector('$(panel) .bt-fv-status')?.textContent || '').match(/https:\\/\\/\\S+?\\/s\\/[0-9a-f]{32}\\//) || [false])[0]";
            timeout = 60)
        @test startswith(notes_url, z.h.url * "/s/")
        @test length(state.shares.links[]) == 3
        # No share button where there is nothing to share as a page.
        TK.eval_js(z, """(() => { document.querySelector('.bt-messages').__bt_chat.comm.notify(
            {type: 'edit_file', path: $(TK.json(joinpath(cwd, "secret.txt")))}); return true; })()""")
        secret_panel = ".bw-ws-panel[data-panel-id=\"file:$(joinpath(cwd, "secret.txt"))\"]"
        @test TK.wait_for(z, "the text file's panel", "!!document.querySelector('$(secret_panel) .bt-fv-act')";
                          timeout = 60) == true
        @test TK.eval_js(z, "!document.querySelector('$(secret_panel) .bt-fv-act[data-fv-action=share]')") == true

        # ── 2. the markdown page, for someone not logged in ─────────────────
        b = TK.another_browser(z)
        @test TK.wait_for(b, "not logged in: the login page", "location.pathname.startsWith('/authelia')";
                          timeout = 30) == true
        TK.eval_js(b, "location.href = $(repr(md_url)); true")
        @test TK.wait_for(b, "the shared page", "document.querySelector('h1')?.textContent === 'Quarterly report'";
                          timeout = 60) == true
        @test TK.wait_for(b, "its image, from the worker",
            "(() => { const i = document.querySelector('img'); return !!i && i.complete && i.naturalWidth === 1; })()";
            timeout = 30) == true
        @test TK.eval_js(b, "document.querySelector('video')?.getAttribute('src')") == "clip.mp4"
        # Raw HTML in the file cannot run code.
        @test TK.eval_js(b, "document.title") == "report"
        @test TK.eval_js(b, "fetch('secret.txt').then(r => r.status)") == 404
        @test TK.eval_js(b, "fetch('figs/dot.png').then(r => r.status)") == 200
        # The dashboard is still behind the login.
        @test occursin("/authelia", TK.eval_js(b, "fetch('/').then(r => r.url)"))

        # ── 3. the app: its password, then live ─────────────────────────────
        TK.eval_js(b, "location.href = $(repr(app_url)); true")
        TK.wait_for(b, "the password form", "!!document.querySelector('input[name=password]')"; timeout = 30)
        TK.set_input(b, "input[name=password]", "wrong")
        TK.click(b, "form button[type=submit]")
        @test TK.wait_for(b, "a wrong password refused",
            "document.body.textContent.includes('That password is not right')"; timeout = 30) == true
        TK.set_input(b, "input[name=password]", "open sesame")
        TK.click(b, "form button[type=submit]")
        @test TK.wait_for(b, "the live app", "!!document.querySelector('.share-probe')"; timeout = 120) == true
        @test TK.wait_for(b, "its first state", "document.querySelector('.share-probe').textContent.includes('n=0')";
                          timeout = 30) == true
        TK.eval_js(b, "document.querySelector('.share-probe button').click(); true")
        @test TK.wait_for(b, "it reacts, through the worker", "document.querySelector('.share-probe').textContent.includes('n=1')";
                          timeout = 30) == true
        @test !isempty(state.shares.pages)
        @test isempty(TK.js_errors(b))

        # The file changes: the next visit shows the new version.
        app = joinpath(cwd, "app.jl")
        write(app, replace(read(app, String), "# Live report" => "# Live report v2"))
        TK.eval_js(b, "location.reload(); true")
        @test TK.wait_for(b, "the changed app",
            "(document.querySelector('.share-probe')?.textContent || '').includes('Live report v2')";
            timeout = 180) == true

        # The share host crashes: the next visit starts it again. (It and its
        # Julia sessions lead process groups of their own; killed like an
        # out-of-memory kill would.)
        hosts = [parse(Int, d) for d in readdir("/proc") if all(isdigit, d) &&
                 isfile("/proc/$d/environ") &&
                 occursin("BONITOAGENTS_PROJECT_ID=$(BT.SHARES_PROJECT)\0",
                          try read("/proc/$d/environ", String) catch e; e isa SystemError || rethrow(); "" end)]
        @test !isempty(hosts)
        foreach(pid -> ccall(:kill, Cint, (Cint, Cint), -Cint(pid), 9), hosts)
        foreach(pid -> ccall(:kill, Cint, (Cint, Cint), Cint(pid), 9), hosts)
        @test timedwait(() -> BT.eval_host_ws(state, BT.SHARES_PROJECT, only(keys(state.workers[]))) === nothing, 30) === :ok
        TK.eval_js(b, "location.reload(); true")
        @test TK.wait_for(b, "the app again, from a new share host",
            "(document.querySelector('.share-probe')?.textContent || '').includes('Live report v2')";
            timeout = 300) == true
        TK.eval_js(b, "document.querySelector('.share-probe button').click(); true")
        @test TK.wait_for(b, "and live", "document.querySelector('.share-probe').textContent.includes('n=1')";
                          timeout = 30) == true

        # The gate opens a page's websocket and assets, nothing else: through the
        # tunnel, an unknown session or asset still meets the login.
        host, port = match(r"https://([^:/]+):(\d+)", z.h.url).captures
        curl(path) = read(`curl -sk --resolve $(host):$(port):127.0.0.1 -o /dev/null
                                -w "%{http_code} %{redirect_url}" $(z.h.url * path)`, String)
        login_page = "302 https://$(host):$(port)/authelia/"
        @test startswith(curl("/" * string(BT.uuid4())), login_page)
        @test startswith(curl("/assets/" * "0"^40 * "-x.js"), login_page)
        @test startswith(curl("/s/" * "0"^32 * "/"), "404")

        # ── 4. the owner ends a link in Settings ────────────────────────────
        TK.to_settings(z)
        @test TK.wait_for(z, "all three links listed", "document.querySelectorAll('.bt-shares-table tr').length === 4";
                          timeout = 30) == true
        TK.eval_js(z, """(() => { const row = [...document.querySelectorAll('.bt-shares-table tr')]
            .find(r => r.textContent.includes('report')); [...row.querySelectorAll('button')]
            .find(x => x.textContent === 'End').click(); return true; })()""")
        @test TK.wait_for(z, "two links left", "document.querySelectorAll('.bt-shares-table tr').length === 3";
                          timeout = 30) == true
        # The panel's link opens for anyone too.
        TK.eval_js(b, "location.href = $(repr(notes_url)); true")
        @test TK.wait_for(b, "the notes page", "document.querySelector('h1')?.textContent === 'Notes'";
                          timeout = 30) == true
        # A password set in Settings: asked for from then on; removed, gone again.
        notes_row = "[...document.querySelectorAll('.bt-shares-table tr')].find(r => r.textContent.includes('notes'))"
        function set_password!(pw)
            TK.eval_js(z, """(() => { const r = $(notes_row); const f = r.querySelector('.bt-share-password');
                f.value = $(repr(pw)); [...r.querySelectorAll('button')].find(x => x.textContent === 'Set').click();
                return true; })()""")
        end
        set_password!("second secret")
        @test TK.wait_for(z, "the password is set", "document.body.textContent.includes('password set')";
                          timeout = 30) == true
        TK.eval_js(b, "location.reload(); true")
        @test TK.wait_for(b, "the notes link asks for it", "!!document.querySelector('input[name=password]')";
                          timeout = 30) == true
        TK.set_input(b, "input[name=password]", "second secret")
        TK.click(b, "form button[type=submit]")
        @test TK.wait_for(b, "and opens with it", "document.querySelector('h1')?.textContent === 'Notes'";
                          timeout = 30) == true
        set_password!("")
        @test TK.wait_for(z, "the password is removed", "document.body.textContent.includes('password removed')";
                          timeout = 30) == true
        # A fresh browser, no cookie: the page opens straight away.
        TK.close_browser!(b)
        b = TK.another_browser(z)
        TK.eval_js(b, "location.href = $(repr(notes_url)); true")
        @test TK.wait_for(b, "the notes page, no password", "document.querySelector('h1')?.textContent === 'Notes'";
                          timeout = 30) == true
        TK.eval_js(b, "location.href = $(repr(md_url)); true")
        @test TK.wait_for(b, "the ended link is gone", "document.body.textContent.includes('Link not found')";
                          timeout = 30) == true
        @test isempty(TK.js_errors(z))
    finally
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end
