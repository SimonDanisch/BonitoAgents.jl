# Shared links behind the Caddy login proxy (`dev_server(proxy = true)`: the
# real Caddy and Authelia). Caddy lets `/s/…` through to anyone and nothing else
# (it cannot tell a share page's websocket from the dashboard's), so:
#
#   1. a markdown link opens for someone who is not logged in, with its image;
#      the paths around it still meet the login;
#   2. an app link opens live for a logged-in viewer.
#
# Own dev server: the proxy has to be in front.
@testitem "e2e:shares_proxy" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    import BonitoAgents as BT
    using Base64: base64decode

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    card(id) = "$VP?.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
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

    z = TK.dev_server(; proxy = true, agent = _ -> [TK.end_turn()])
    b = nothing
    try
        TK.open_browser(z)
        TK.login!(z)
        @test TK.wait_for(z, "the worker online",
            "!!document.querySelector('.bt-worker-cell .bt-dot-online')"; timeout = 60) == true

        cwd = mkpath(joinpath(mktempdir(), "proxyshare"))
        mkpath(joinpath(cwd, "figs"))
        write(joinpath(cwd, "figs", "dot.png"), base64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        write(joinpath(cwd, "report.md"), "# Proxy report\n\n![a dot](figs/dot.png)\n")
        write(joinpath(cwd, "app.jl"), join([
            "using Bonito, Markdown",
            "App() do",
            "    clicks = Observable(0)",
            raw"    more = Bonito.Button(\"more\")",
            "    on(_ -> clicks[] += 1, more.value)",
            raw"    DOM.div(md\"# Proxy app\", more, map(n -> string(\"n=\", n), clicks); class = \"share-probe\")",
            "end"], "\n"))
        TK.new_chat(z; cwd = cwd)
        z.agent_fn[] = _ -> [TK.mcp_call("bt_share"; real_process = true, id = "px-md", path = "report.md"),
                             TK.mcp_call("bt_share"; real_process = true, id = "px-app", path = "app.jl"),
                             TK.end_turn()]
        TK.send_message(z, "share both")
        md_url = TK.wait_for(z, "the markdown link", card_link("px-md"); timeout = 120)
        app_url = TK.wait_for(z, "the app link", card_link("px-app"); timeout = 900)
        @test startswith(md_url, z.h.url * "/s/") && startswith(app_url, z.h.url * "/s/")

        # ── 1. the markdown page, for someone not logged in ─────────────────
        b = TK.another_browser(z)
        TK.eval_js(b, "location.href = $(repr(md_url)); true")
        @test TK.wait_for(b, "the shared page", "document.querySelector('h1')?.textContent === 'Proxy report'";
                          timeout = 60) == true
        @test TK.wait_for(b, "its image",
            "(() => { const i = document.querySelector('img'); return !!i && i.complete && i.naturalWidth === 1; })()";
            timeout = 30) == true

        host, port = match(r"https://([^:/]+):(\d+)", z.h.url).captures
        portal = "302 https://auth.$(host):$(port)/"
        curl(args...) = read(`curl -sk --resolve $(host):$(port):127.0.0.1 -o /dev/null
                                   -w "%{http_code} %{redirect_url}" $(args)`, String)
        @test startswith(curl(md_url), "200")
        # Nothing rides on `/s/` to somewhere else: the portal, or nothing there.
        for path in ("/s/../", "/s/%2e%2e/acp-log", "/s/..%2f..%2facp-log", "/s/../acp-log")
            answer = curl("--path-as-is", z.h.url * path)
            @test startswith(answer, portal) || startswith(answer, "404")
        end
        @test startswith(curl(z.h.url * "/"), portal)

        # ── 2. the app, for a logged-in viewer ──────────────────────────────
        TK.eval_js(z, "location.href = $(repr(app_url)); true")
        @test TK.wait_for(z, "the live app", "!!document.querySelector('.share-probe')"; timeout = 180) == true
        TK.eval_js(z, "document.querySelector('.share-probe button').click(); true")
        @test TK.wait_for(z, "it reacts", "document.querySelector('.share-probe').textContent.includes('n=1')";
                          timeout = 30) == true
    finally
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end
