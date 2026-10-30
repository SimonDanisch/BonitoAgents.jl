# The To-do app, the way a user meets it: a tile on the dashboard (its logo, the
# details on hover), set up once in a dialog that picks the worker its chat runs
# on, opened at once after that. Its chat shows the server-wide list pinned
# above the conversation. An item
# added there is checked off by ANOTHER chat's agent through its MCP (a real
# BonitoMCP process, forwarding the app's tool to the server), and the list
# shows who did it. "Start chat" asks the app chat's agent, which picks the
# folder and starts a chat there that knows which item it works on.
#
# Its own server: the app chat would otherwise sit in every later item's sidebar.
@testitem "e2e:todo_app" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TestKit
    real_call(tool; kw...) = TK.mcp_call(tool; real_process = true, kw...)
    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    APP = "document.querySelector('.bt-chatpane .bt-todo')?.closest('.bt-chatpane')"
    item(id) = "$APP?.querySelector('.bt-todo-item[data-todo-id=\"$id\"]')"
    # A tool card in the visible pane that ran to completion.
    completed(id) = """(() => { const c = $VP?.querySelector('.bt-tool-msg[data-msg-id*="$id"]');
        return c?.querySelector('.bt-tool-status')?.textContent === 'completed'; })()"""

    folder = mktempdir()
    worker = Ref("")
    agent(p) =
        occursin("Start a chat for to-do #2", p) ?
            [real_call("todo_projects"; id = "tp"),
             real_call("todo_start_chat"; id = "ts", todo_id = 2, worker = worker[], path = folder,
                       prompt = "DO-THE-THING for the flaky test"),
             TK.text("Started it."), TK.end_turn()] :
        occursin("check off", p) ?
            [real_call("todo_done"; id = "td", todo_id = 1, note = "notes written"),
             TK.text("Checked it off."), TK.end_turn()] :
        occursin("DO-THE-THING", p) ? [TK.text("WORKING ON IT"), TK.end_turn()] :
        [TK.text("ok"), TK.end_turn()]
    s = TK.dev_server(agent = agent)
    try
        TK.open_browser(s)
        TK.to_dashboard(s)

        # ── the Apps tile: logo, details on hover, a setup dialog first ────
        TILE = "document.querySelector('.bt-app-tile[data-app=\"todo\"]')"
        @test TK.wait_for(s, "the To-do tile with its logo",
            "(i => !!i && i.complete && i.naturalWidth > 0)($TILE?.querySelector('img.bt-app-logo'))";
            timeout = 60) == true
        @test occursin("todo.svg", TK.eval_js(s, "$TILE.querySelector('.bt-app-logo').getAttribute('src')"))
        @test TK.eval_js(s, "$TILE.querySelector('.bt-app-title').textContent") == "To-do"
        @test TK.eval_js(s, "$TILE.querySelector('.bt-app-status').textContent") == "Not set up"
        # Hovered (a real pointer): what it is, the tools it gives agents.
        x, y = TK.eval_js(s, "(() => { const r = $TILE.querySelector('.bt-app-launch').getBoundingClientRect(); return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)]; })()")
        TK.ECT.send_input(s.browser[], "{type: 'mouseMove', x: $x, y: $y}")
        @test TK.wait_for(s, "the details on hover",
            "getComputedStyle($TILE.querySelector('.bt-app-details')).opacity === '1'"; timeout = 5) == true
        details = TK.eval_js(s, "$TILE.querySelector('.bt-app-details').textContent")
        @test contains(details, "One to-do list for every chat") && contains(details, "todo_done")
        TK.ECT.send_input(s.browser[], "{type: 'mouseMove', x: 2, y: 2}")
        # A phone: tiles side by side, nothing cut off, no hover details.
        phone = TK.emulate_phone(s) do
            sleep(0.5)
            TK.eval_js(s, """(() => { const t = $TILE, l = t.querySelector('.bt-app-launch').getBoundingClientRect(),
                    name = t.querySelector('.bt-app-title');
                return [l.width >= 100 && l.right <= innerWidth, name.scrollWidth <= name.clientWidth,
                        getComputedStyle(t.querySelector('.bt-app-details')).display]; })()""")
        end
        @test phone == [true, true, "none"]

        # A click asks first where its chat runs.
        TK.click(s, ".bt-app-tile[data-app=\"todo\"] .bt-app-launch")
        SETUP = "document.querySelector('.bw-modal-overlay .bt-app-setup')"
        @test TK.wait_for(s, "the setup dialog with this worker",
            "!!$SETUP?.querySelector('.bt-app-choice.bt-on .bt-app-choice-name')"; timeout = 15) == true
        worker[] = TK.eval_js(s, "$SETUP.querySelector('.bt-app-choice.bt-on .bt-app-choice-name').textContent")
        @test !isempty(worker[])
        @test TK.eval_js(s, "$SETUP.querySelector('.bt-app-start').disabled") == false
        TK.screenshot(s, joinpath(tempdir(), "todo_app_setup.png"))
        TK.click(s, ".bt-app-setup .bt-app-start")
        @test TK.wait_for(s, "the app chat with its list",
            "!!$VP?.querySelector('.bt-todo') && !!$VP?.querySelector('.bt-text-input')";
            timeout = 60) == true
        @test TK.eval_js(s, "!document.querySelector('.bw-modal-overlay.bw-modal-open')") == true
        # The ordinary chat widgets are all there, the list above the messages.
        @test TK.eval_js(s, """(() => { const p = $VP, t = p.querySelector('.bt-todo'),
            m = p.querySelector('.bt-messages');
            return !!p.querySelector('.bt-app[data-app="todo"] .bt-header') &&
                   t.getBoundingClientRect().bottom <= m.getBoundingClientRect().top + 1; })()""") == true
        @test TK.eval_js(s, "$VP.querySelector('.bt-todo-empty').textContent") == "Nothing to do yet."
        app_pid = TK.eval_js(s, "$APP.dataset.panePid")
        # Pinned in the sidebar, under its own heading, wearing the app's logo.
        @test TK.wait_for(s, "the app chat under Apps", """(() => {
            const r = document.querySelector('.bt-side-chat .bt-side-item[data-project-id="$(app_pid)"]')?.closest('.bt-side-chat');
            const g = r?.querySelector('.bt-side-group');
            return !!g && !g.classList.contains('bt-hidden') && g.textContent === 'Apps' &&
                   (r.querySelector('img.bt-proj-thumb')?.getAttribute('src') || '').includes('todo.svg'); })()"""; timeout = 20) == true

        # Set up, the tile says where it runs and opens the chat at once.
        TK.to_dashboard(s)
        @test TK.wait_for(s, "the tile set up",
            "$TILE?.querySelector('.bt-app-status')?.textContent === $(TK.json("on " * worker[]))"; timeout = 20) == true
        TK.click(s, ".bt-app-tile[data-app=\"todo\"] .bt-app-launch")
        @test TK.wait_for(s, "the app chat again", "$VP?.dataset.panePid === $(TK.json(app_pid))"; timeout = 30) == true
        @test TK.eval_js(s, "!document.querySelector('.bw-modal-overlay.bw-modal-open')") == true

        # ── the user adds items in the pane ─────────────────────────────────
        function add!(text)
            TK.set_input(s, ".bt-todo-input", text)
            TK.eval_js(s, "$VP.querySelector('.bt-todo-add').requestSubmit(); true")
        end
        add!("Write the release notes")
        @test TK.wait_for(s, "item #1", "$(item(1))?.querySelector('.bt-todo-text')?.textContent === 'Write the release notes'"; timeout = 15) == true
        @test TK.eval_js(s, "$VP.querySelector('.bt-todo-input').value") == ""
        add!("Fix the flaky test")
        @test TK.wait_for(s, "item #2", "!!$(item(2))"; timeout = 15) == true
        @test TK.eval_js(s, "$APP.querySelector('.bt-todo-counts').textContent") == "2 open · 0 done"

        # A double click edits an item's text in place.
        TK.eval_js(s, """(() => { const t = $(item(2)).querySelector('.bt-todo-text');
            t.dispatchEvent(new MouseEvent('dblclick', {bubbles: true}));
            t.textContent = 'Fix the flaky sidebar test';
            t.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return true; })()""")
        @test TK.wait_for(s, "the edit saved",
            "$(item(2))?.querySelector('.bt-todo-text')?.textContent === 'Fix the flaky sidebar test'"; timeout = 15) == true

        # ── another chat's agent checks #1 off, through its own MCP ─────────
        other = TK.new_chat(s; cwd = folder)
        TK.send_message(s, "check off the notes")
        @test TK.wait_for(s, "todo_done ran", completed("td"); timeout = 120) == true
        # The app's pane is kept mounted: it shows the change without a reload.
        @test TK.wait_for(s, "#1 gone from the open list", "!$(item(1)) && !!$(item(2))"; timeout = 15) == true
        @test TK.eval_js(s, "$APP.querySelector('.bt-todo-counts').textContent") == "1 open · 1 done"
        TK.open_chat(s, app_pid)
        TK.click(s, ".bt-todo-showdone")
        @test TK.wait_for(s, "#1 shown as done", "$(item(1))?.classList.contains('bt-todo-item-done')"; timeout = 15) == true
        # By the chat that did it, under its title (the folder's name), with its note.
        done_by = TK.eval_js(s, "$(item(1)).querySelector('.bt-todo-done-by').textContent")
        @test startswith(done_by, "✓ by $(basename(folder)) · ")
        @test endswith(done_by, " · notes written")
        @test TK.eval_js(s, "$(item(1)).querySelector('.bt-todo-check').checked") == true
        TK.screenshot(s, joinpath(tempdir(), "todo_app_list.png"))

        # ── "Start chat": the app chat's agent picks the folder ─────────────
        TK.click(s, ".bt-todo-item[data-todo-id=\"2\"] .bt-todo-start")
        @test TK.wait_for(s, "the request in the app chat",
            "($VP.querySelector('.bt-messages').textContent || '').includes('Start a chat for to-do #2')"; timeout = 20) == true
        @test TK.wait_for(s, "todo_start_chat ran", completed("ts"); timeout = 120) == true
        @test TK.wait_for(s, "the new chat linked to #2", "!!$(item(2))?.querySelector('.bt-todo-chat')"; timeout = 20) == true
        @test TK.eval_js(s, "$(item(2)).querySelector('.bt-todo-chat').textContent") == "Fix the flaky sidebar test"
        TK.screenshot(s, joinpath(tempdir(), "todo_app_started.png"))
        new_pid = TK.eval_js(s, "$(item(2)).querySelector('.bt-todo-chat').dataset.value")
        @test new_pid != other

        # The link opens it: the prompt the agent wrote, told which item it is.
        TK.click(s, ".bt-todo-item[data-todo-id=\"2\"] .bt-todo-chat")
        @test TK.wait_for(s, "the new chat on screen",
            "$VP?.dataset.panePid === $(TK.json(new_pid))"; timeout = 30) == true
        @test TK.wait_for(s, "its prompt and answer", """(() => {
            const t = $VP.querySelector('.bt-messages').textContent || '';
            return t.includes('DO-THE-THING for the flaky test') && t.includes('to-do #2') &&
                   t.includes('WORKING ON IT'); })()"""; timeout = 60) == true
        @test TK.eval_js(s, "!$VP.querySelector('.bt-todo')") == true   # an ordinary chat

        # ── removing an item ────────────────────────────────────────────────
        TK.open_chat(s, app_pid)
        TK.click(s, ".bt-todo-item[data-todo-id=\"2\"] .bt-todo-remove")
        @test TK.wait_for(s, "#2 removed", "!$(item(2))"; timeout = 15) == true

        @test isempty(TK.js_errors(s))
    finally
        close(s)
    end
end
