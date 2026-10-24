# Sidebar navigation changes the visible pane/tab/label, never panel placement.
# Moving the workspace twice and then reordering cached chat fragments forced
# several synchronous layouts per switch and reset the chats' scroll positions.
@testitem "e2e:workspace_navigation" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    TK = S.TK
    s = S.server()
    cwd = mktempdir()
    path = joinpath(cwd, "navigation.jl")
    write(path, "const NAVIGATION = 42\n")
    s.agent_fn[] = _ -> [
        TK.text(join(("Paragraph $(i): " * "read this text "^30 for i in 1:12), "\n\n")),
        TK.tool(kind = "read", title = path, id = "nav-file",
                content = [TK.text_block("```julia\nconst NAVIGATION = 42\n```")]),
        TK.end_turn()]
    first = TK.new_chat(s)
    TK.send_message(s, "first chat")
    @test TK.wait_for(s, "first reply done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true
    second = TK.new_chat(s; cwd)
    TK.send_message(s, "second chat")
    @test TK.wait_for(s, "file link", "!!document.querySelector('.bt-tool-msg[data-msg-id*=\"nav-file\"] .bt-path-link')"; timeout = 60) == true
    TK.click(s, ".bt-tool-msg[data-msg-id*=\"nav-file\"] .bt-path-link")
    @test TK.wait_for(s, "editor rendered", "!!document.querySelector('.bt-file-editor .view-lines')"; timeout = 60) == true

    try
        for width in (1280, 600)
            TK.set_window_size(s, width, 820)
            sleep(0.5) # breakpoint changes may rebuild the workspace
            TK.open_chat(s, second)
            @test TK.wait_for(s, "chat tab active", "document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent === 'Chat'"; timeout = 20) == true
            TK.eval_js(s, """(() => {
                window.__btNavChrome = document.querySelector('.bw-ws-chrome').firstElementChild;
                // Older suite chats may legitimately be evicted by the LRU.
                // Track the two chats this scenario keeps alive throughout.
                const panes = [...document.querySelectorAll('.bt-chatpane')]
                    .filter(p => $(TK.json([first, second])).includes(p.dataset.panePid));
                const panels = [...document.querySelectorAll('.bw-ws-panel')];
                window.__btNavMoves = 0;
                window.__btNavMovedNodes = [];
                window.__btNavObserver = new MutationObserver(records => {
                    for (const r of records) for (const n of r.removedNodes) {
                        if (panes.concat(panels).some(p => n === p || n.contains(p))) {
                            window.__btNavMoves++;
                            window.__btNavMovedNodes.push({node:n.nodeName, classes:n.className,
                                panes:panes.filter(p=>n===p||n.contains(p)).map(p=>p.dataset.panePid)});
                        }
                    }
                });
                window.__btNavObserver.observe(document.querySelector('.bw-ws'), {childList:true, subtree:true});
                return true;
            })()""")
            for pid in (first, second, first, second)
                TK.open_chat(s, pid)
                @test TK.wait_for(s, "cached chat visible",
                    "[...document.querySelectorAll('.bt-chatpane')].some(p => p.dataset.panePid === $(TK.json(pid)) && p.getAttribute('aria-hidden') !== 'true')"; timeout = 20) == true
            end
            # A server-driven activation must reuse the same workspace DOM even
            # when the file tab was active. Labels change in place too.
            TK.click_text(s, "navigation.jl")
            @test TK.wait_for(s, "file tab active", "document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent === 'navigation.jl'"; timeout = 20) == true
            # The icon remains visible with the narrow sidebar collapsed.
            TK.click(s, ".bt-side-item[data-project-id=\"\"]")
            @test TK.wait_for(s, "home tab active", "document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent === 'Home'"; timeout = 20) == true
            TK.to_settings(s)
            @test TK.wait_for(s, "settings tab renamed", "document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent === 'Settings'"; timeout = 20) == true
            TK.open_chat(s, second)
            @test TK.wait_for(s, "chat label restored", "document.querySelector('.bw-tab.bw-active .bw-tab-label')?.textContent === 'Chat'"; timeout = 20) == true
            sleep(0.3)
            @test TK.eval_js(s, "document.querySelector('.bw-ws-chrome').firstElementChild === window.__btNavChrome") == true
            TK.eval_js(s, "window.__btNavMoves") == 0 ||
                @info "workspace nodes moved during navigation" nodes = TK.eval_js(s, "window.__btNavMovedNodes")
            @test TK.eval_js(s, "window.__btNavMoves") == 0
            @test TK.eval_js(s, """[...document.querySelectorAll('.bt-file-editor')].some(e =>
                e.querySelector('.bt-file-editor-path')?.textContent === $(TK.json(path)) &&
                e.querySelector('.view-lines')?.textContent.includes('NAVIGATION'))""") == true
            TK.eval_js(s, "window.__btNavObserver.disconnect(); true")
        end
        TK.screenshot(s, joinpath(cwd, "workspace-navigation.png"))
        @test isempty(TK.js_errors(s))
    finally
        TK.eval_js(s, "window.__btNavObserver?.disconnect(); true")
        TK.set_window_size(s, 1280, 820)
        s.agent_fn[] = S.default_agent
    end
end
