# Share the rendered output through the same UI the user sees, then open it in
# a browser with no login. Live values must not re-execute their eval source or
# grant access to other results on the same bridge.
@testitem "e2e:share_outputs" setup = [SharedServer] tags = [:e2e] failfast = true begin
    TK = SharedServer.TK
    using Base64: base64decode
    z = TK.dev_server(; tunnel = true, agent = _ -> [TK.end_turn()])
    viewer = nothing
    try
        TK.open_browser(z)
        TK.login!(z)
        @test TK.wait_for(z, "worker online", "!!document.querySelector('.bt-worker-cell .bt-dot-online')";
                          timeout = 60) == true
        cwd = mktempdir()
        env = abspath(joinpath(@__DIR__, "..", "evalenv"))
        write(joinpath(cwd, "notes.md"), "# Shared output\n\nFrom bt_show.\n")
        png = base64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")
        write(joinpath(cwd, "public.png"), png)
        write(joinpath(cwd, "private.png"), png)
        TK.new_chat(z; cwd)
        card(id) = "document.querySelector('.bt-tool-msg[data-msg-id*=\"$(id)\"]')"
        function share_output(id)
            c = card(id)
            @test TK.wait_for(z, "share button for $id", "$(c)?.querySelector('.bt-share-result')?.disabled === false";
                              timeout = 180) == true
            @test TK.eval_js(z, "getComputedStyle($(c).querySelector('.bt-share-copy')).display === 'none'") == true
            TK.eval_js(z, "$(c).querySelector('.bt-share-result').click(); true")
            url = TK.wait_for(z, "link for $id", "$(c)?.querySelector('.bt-share-link')?.getAttribute('href') || false";
                             timeout = 60)
            @test startswith(url, z.h.url * "/s/")
            @test TK.eval_js(z, "!$(c).querySelector('.bt-share-copy').hidden") == true
            @test TK.eval_js(z, "getComputedStyle($(c).querySelector('.bt-share-result')).display === 'none'") == true
            return url
        end
        z.agent_fn[] = _ -> [TK.mcp_call("bt_show"; real_process = true, id = "share-md", path = joinpath(cwd, "notes.md")),
                             TK.mcp_call("bt_show"; real_process = true, id = "share-img", path = joinpath(cwd, "public.png")),
                             TK.end_turn()]
        TK.send_message(z, "show the files")
        md_url = share_output("share-md")
        img_url = share_output("share-img")
        write(joinpath(cwd, "notes.md"), "# Shared output\n\n![Shared image]($(img_url))\n")
        viewer = TK.another_browser(z)
        TK.eval_js(viewer, "location.href = $(TK.json(md_url)); true")
        @test TK.wait_for(viewer, "markdown without login", "document.querySelector('h1')?.textContent === 'Shared output'";
                          timeout = 30) == true
        @test TK.wait_for(viewer, "image without login", "[...document.images].some(i => i.complete && i.naturalWidth === 1)";
                          timeout = 30) == true

        # A private asset is registered on exactly the same eval bridge as the
        # public app. Knowing its URL must still not let the viewer fetch it.
        private_code = "using Bonito; DOM.img(src=Bonito.Asset($(repr(joinpath(cwd, "private.png")))), class=\"private-probe\")"
        app_code = """
            using Bonito
            sleep(1) # the tool body mounts before its result arrives
            share_runs = isdefined(Main, :share_runs) ? share_runs + 1 : 1
            App() do
                n = Observable(0)
                button = Bonito.Button("Increment")
                on(_ -> n[] += 1, button.value)
                DOM.div(DOM.span("evaluations=" * string(share_runs)), button,
                        DOM.span(map(x -> "count=" * string(x), n)),
                        DOM.img(src=Bonito.Asset($(repr(joinpath(cwd, "public.png")))));
                        class="shared-live-probe")
            end
            """
        z.agent_fn[] = _ -> [TK.bt_eval(private_code; env_path = env, real_process = true, id = "private-eval"),
                             TK.bt_eval(app_code; env_path = env, real_process = true, id = "share-app"),
                             TK.end_turn()]
        TK.send_message(z, "display a private image and an app")
        @test TK.wait_for(z, "private image mounted", "!!document.querySelector('.private-probe')?.getAttribute('src')";
                          timeout = 180) == true
        private_url = TK.eval_js(z, "document.querySelector('.private-probe').src")
        @test TK.wait_for(z, "app mounted", "document.querySelector('.shared-live-probe')?.textContent.includes('evaluations=1')";
                          timeout = 180) == true
        app_url = share_output("share-app")
        TK.screenshot(z, joinpath(tempdir(), "bt-share-outputs.png"))
        TK.eval_js(viewer, "location.href = $(TK.json(app_url)); true")
        @test TK.wait_for(viewer, "shared live result without rerunning eval",
            "document.querySelector('.shared-live-probe')?.textContent.includes('evaluations=1')";
            timeout = 90) == true
        TK.click(viewer, ".shared-live-probe button")
        @test TK.wait_for(viewer, "public app reacts", "document.querySelector('.shared-live-probe')?.textContent.includes('count=1')";
                          timeout = 30) == true
        @test TK.wait_for(viewer, "only the public app's asset loads",
            "document.querySelector('.shared-live-probe img')?.naturalWidth === 1"; timeout = 30) == true
        @test TK.eval_js(viewer, "!document.querySelector('.bt-embed-close')") == true
        TK.eval_js(viewer, "location.href = $(TK.json(private_url)); true")
        @test TK.wait_for(viewer, "private image still requires login", "location.pathname.startsWith('/authelia/')";
                          timeout = 30) == true

        # Closing the owner-held result expires its link instead of rerunning it.
        TK.eval_js(z, "$(card("share-app")).querySelector('.bt-embed-close').click(); true")
        TK.eval_js(viewer, "location.href = $(TK.json(app_url)); true")
        @test TK.wait_for(viewer, "closed result explains its lifetime",
            "document.body.textContent.includes('shared result was closed')"; timeout = 30) == true
        TK.to_settings(z)
        @test TK.wait_for(z, "live result listed with file shares",
            "document.querySelector('.bt-shares-table')?.textContent.includes('live result (until its Julia session ends)')";
            timeout = 30) == true
        TK.eval_js(z, """(() => {
            const row = [...document.querySelectorAll('.bt-shares-table tr')].find(r => r.textContent.includes('Julia result'));
            [...row.querySelectorAll('button')].find(b => b.textContent === 'End').click(); return true;
        })()""")
        @test TK.wait_for(z, "result link removed", "!document.querySelector('.bt-shares-table')?.textContent.includes('Julia result')";
                          timeout = 30) == true
        TK.eval_js(viewer, "location.reload(); true")
        @test TK.wait_for(viewer, "revoked result is unavailable", "document.body.textContent.includes('Link not found')";
                          timeout = 30) == true
        @test isempty(TK.js_errors(z))
    catch
        println("Share output test DOM: ", TK.eval_js(z, "document.body.innerText"))
        println("Share output test browser errors: ", TK.js_errors(z))
        rethrow()
    finally
        viewer === nothing || TK.close_browser!(viewer)
        close(z)
    end
end
