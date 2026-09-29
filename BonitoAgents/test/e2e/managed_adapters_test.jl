# The agent adapters a server has its workers keep installed, end to end: the
# server declares them (`dev_server(manage_harnesses = true)`), the worker
# installs them itself and reports what it has on its card, an admin changes
# them on the dashboard, and the worker never replaces them under a running chat.
#
# The worker installs from a local Node mirror and npm registry (TestKit's
# `fake_node_dist`, reached through `BONITOAGENTS_NODE_DIST` as a real mirror
# would be): real archives and checksums, an `npm` that installs from a
# directory. BonitoWorker's `test_managed_adapters.jl` installs the real ones.

@testitem "e2e:managed_adapters" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    Sys.isunix() || return
    claude = "@agentclientprotocol/claude-agent-acp"
    codex = "@agentclientprotocol/codex-acp"
    dist = TK.fake_node_dist(; published = Dict(claude => "1.0.0", codex => "2.0.0"))
    # The worker the dev server spawns inherits these.
    saved = Dict(k => get(ENV, k, nothing) for k in ("BONITOAGENTS_NODE_DIST", "BT_FAKE_NPM_REGISTRY"))
    ENV["BONITOAGENTS_NODE_DIST"] = dist.url
    ENV["BT_FAKE_NPM_REGISTRY"] = dist.registry
    z = nothing
    try
        z = TK.dev_server(; manage_harnesses = true, agent = p -> [TK.text("echo: " * p), TK.end_turn()])
        TK.open_browser(z)
        card_note = "(document.querySelector('.bt-worker-cell .bt-worker-update-note:not(.bt-hidden)') || {}).textContent || ''"
        shows(text) = "($(card_note)).includes($(TK.json(text)))"

        # Connected, the worker installs what the server declares, and says so.
        @test TK.wait_for(z, "the installed adapters on the card",
            shows("adapters: claude-agent-acp 1.0.0 · codex-acp 2.0.0 · node 24.9.0"); timeout = 120) == true

        # An admin pins another version on the dashboard; the worker follows.
        adapters_js(expr) = """(() => { const h = [...document.querySelectorAll('h2')].find(h => h.textContent.trim() === 'Agent adapters');
            const sec = h && h.closest('.bt-section').parentElement; if (!sec) return false; return $(expr); })()"""
        function set_version!(label, version)
            ok = TK.eval_js(z, adapters_js("""(() => {
                const row = [...sec.querySelectorAll('.bt-admin-form')].find(r => r.querySelector('.bt-settings-title')?.textContent.trim() === $(TK.json(label)));
                const el = row && row.querySelector('input');
                if (!el) return false;
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, $(TK.json(version)));
                el.dispatchEvent(new Event('input', {bubbles: true})); return true; })()"""))
            ok === true || error("no version field for $(label)")
        end
        save!() = (sleep(0.3); TK.eval_js(z, adapters_js("[...sec.querySelectorAll('button')].find(b => b.textContent.trim() === 'Save').click() || true")))
        set_version!(claude, "0.9.0")
        save!()
        @test TK.wait_for(z, "saved", adapters_js("sec.textContent.includes('saved; connected workers install it')"); timeout = 30) == true
        @test TK.wait_for(z, "the new version on the card", shows("claude-agent-acp 0.9.0"); timeout = 120) == true
        @test "$(claude)@0.9.0" in TK.installs(dist)

        # A running chat holds the adapters: the next change waits until it ends.
        pid = TK.new_chat(z; cwd = mktempdir())
        TK.send_message(z, "hello")
        @test TK.wait_for(z, "the reply", "document.body.textContent.includes('echo: hello')"; timeout = 60) == true
        TK.to_dashboard(z)
        set_version!(claude, "0.8.0")
        save!()
        sleep(10)
        @test !("$(claude)@0.8.0" in TK.installs(dist))
        @test TK.eval_js(z, shows("claude-agent-acp 0.9.0")) == true
        TK.eval_js(z, """(() => { const e = [...document.querySelectorAll('.bt-side-item')].find(x => x.getAttribute('data-project-id') === $(TK.json(pid)));
            e.querySelector('.bt-side-close').click(); return true; })()""")
        @test TK.wait_for(z, "installed once the chat ended", shows("claude-agent-acp 0.8.0"); timeout = 120) == true

        # What cannot be installed is said on the card, with why.
        set_version!("Node", "99")
        save!()
        @test TK.wait_for(z, "the failure on the card",
            shows("adapter install failed: $(dist.url) lists no Node 99 release"); timeout = 120) == true
        # What was installed stays in use.
        @test TK.eval_js(z, shows("claude-agent-acp 0.8.0")) == true
        @test isempty(TK.js_errors(z))
    finally
        z === nothing || close(z)
        close(dist)
        for (k, v) in saved
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end
