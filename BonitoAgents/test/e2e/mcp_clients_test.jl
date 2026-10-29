@testitem "e2e:mcp_clients" setup=[SharedServer] tags=[:e2e] begin
    TK = SharedServer.TK
    evalenv = abspath(joinpath(@__DIR__, "..", "evalenv"))
    altenv = abspath(joinpath(@__DIR__, "..", "altenv"))
    call(tool, client, id; args...) = TK.mcp_call(tool; real_process=true, client, id, args...)
    inspect(client) = call("bt_dev_inspect", client, "inspect-$client"; section="chats")
    agent(prompt) = prompt == "start clients" ? [
        call("bt_julia_eval", "main", "main-run"; env_path=evalenv, background=true, anonymous=true,
            code="println(\"Main started\"); sleep(300); :main_done"),
        call("bt_julia_eval", "peer", "peer-run"; env_path=altenv, background=true, anonymous=true,
            code="println(\"Peer started\"); sleep(300); :peer_done"),
        inspect("third"), inspect("main"), inspect("peer"),
        TK.text("All clients connected")] : prompt == "probe again" ? [
        call("bt_dev_inspect", "third", "after-stop"; section="projects"), TK.text("Probe answered")] :
        [TK.end_turn()]
    s = TK.dev_server(; agent)
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    card(id) = "$pane.querySelector('.bt-tool-msg[data-msg-id*=\"$id\"]')"
    live(id) = "$(card(id))?.classList.contains('bt-tool-live')===true"
    slot(id) = "$pane.querySelector('.bt-taskbar-slot[data-task-id=\"$id\"]')"
    stopped(id) = "$(card(id))?.querySelector('.bt-tool-summary')?.textContent.includes('interrupted')"
    try
        TK.open_browser(s)
        TK.new_chat(s)
        TK.eval_js(s, "$pane.querySelector('.bt-header-menu .bw-menu-trigger').click(); true")
        TK.eval_js(s, "window.confirm=()=>true; $pane.querySelector('.bt-header-devmode').click(); true")
        @test TK.wait_for(s, "dev tools enabled", "$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-on') && !$pane.querySelector('.bt-header-devmode').classList.contains('bt-cap-busy')"; timeout=90)
        TK.send_message(s, "start clients")
        @test TK.wait_for(s, "all three MCP clients can call the server",
            "$pane.textContent.includes('All clients connected') && !$pane.querySelector('.bt-busy-active')"; timeout=120)
        for name in ("main", "peer", "third")
            @test TK.eval_js(s, "$(card("inspect-$name"))?.querySelector('.bt-tool-status')?.textContent==='completed'")
        end
        @test TK.wait_for(s, "diagnostics report three coexisting clients", """(() => {
            const c=$(card("inspect-third")), h=c?.querySelector('.bt-tool-header');
            if(h && h.dataset.expanded!=='true') { h.click(); return false; }
            return /"mcp_?clients"\\s*:\\s*3\\s*[,}]/.test(c?.querySelector('.bt-tool-body')?.innerText || '');
        })()"""; timeout=20, describe="$(card("inspect-third"))?.outerHTML.slice(-4000)")
        @test TK.eval_js(s, "$(live("main-run")) && $(live("peer-run"))")
        @test TK.eval_js(s, "$(slot("main-run")).querySelector('.bt-taskbar-slot-stop').click(); true")
        @test TK.wait_for(s, "Stop reaches the main client's r1", stopped("main-run"); timeout=20)
        @test TK.eval_js(s, live("peer-run")) # the peer also calls its own run r1
        TK.send_message(s, "probe again")
        @test TK.wait_for(s, "another client keeps making server requests",
            "$pane.textContent.includes('Probe answered') && $(card("after-stop"))?.querySelector('.bt-tool-status')?.textContent==='completed'"; timeout=30)
        @test TK.eval_js(s, "$(slot("peer-run")).querySelector('.bt-taskbar-slot-stop').click(); true")
        @test TK.wait_for(s, "Stop reaches the peer client's r1", stopped("peer-run"); timeout=20)
        @test isempty(TK.js_errors(s))
        TK.screenshot(s, joinpath(tempdir(), "bonitoagents-mcp-clients.png"))
    finally
        close(s)
    end
end
