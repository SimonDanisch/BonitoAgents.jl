# Tier 3b — the folder→threads browser + active-chats sidebar (TODO 85).
# Headless (show=false) live render: proves the KeyedList-driven discover tree
# actually mounts in a browser (folders, per-thread previews, "+ New thread",
# Resume), and that the left sidebar lists RUNNING chats (with a close ✕) and
# switches/closes them. No real worker — a MockTransport ChatModel stands in
# for a running chat; opening a discovered thread isn't exercised here (it
# needs a live worker), only that the click path raises no JS error.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)
state.workers[]["w-1"].status = :online

# A running chat so the active-chats sidebar has something to list.
let proj = state.projects[]["p-1"]
    model = BonitoAgents.ChatModel(state, proj.server_path;
                                  project_id = proj.id,
                                  transport  = TH.mock_transport())
    BonitoAgents.start_chat_client!(model)
end

# Persisted discover output for the worker: one folder with two sibling
# threads, plus a second folder — the always-visible tree renders from here.
state.discovered[]["w-1"] = [
    Dict{String,Any}("session_id" => "aaaa1111", "path" => "/work/MyApp", "name" => "MyApp",
                     "first_prompt" => "refactor the parser", "last_used" => 1.70e9,
                     "kind" => "session", "running" => true),
    Dict{String,Any}("session_id" => "bbbb2222", "path" => "/work/MyApp", "name" => "MyApp",
                     "first_prompt" => "add tests for IO", "last_used" => 1.69e9, "kind" => "session"),
    Dict{String,Any}("session_id" => "cccc3333", "path" => "/work/Other", "name" => "Other",
                     "first_prompt" => "write the README", "last_used" => 1.68e9, "kind" => "session"),
]
notify(state.discovered)

ctx = TH.open_window(state)
results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("active-chats sidebar lists the running chat") do
        # The running chat (p-1 = Project1) shows as a sidebar item with a ✕.
        record("Project1 active-chat row present",
               @TH.test_true TH.wait_for(ctx, """
                   Array.from(document.querySelectorAll('.bt-sidebar .bt-side-item'))
                        .some(el => el.dataset.projectId === 'p-1')
               """; timeout = 6.0))
        record("active-chat row has a close ✕",
               @TH.test_true TH.dom_exists(ctx, ".bt-sidebar .bt-side-item[data-project-id='p-1'] .bt-side-close"))
    end

    TH.section("folder→threads tree mounts (KeyedList renders)") do
        # Folder groups render from state.discovered (this is the live proof
        # the KeyedList content actually mounts in the browser).
        record("two folder groups render",
               @TH.test_true TH.wait_for(ctx, "document.querySelectorAll('.bt-group').length >= 2"; timeout = 6.0))
        # The outer discover panel is now a collapsable <details> (closed by
        # default — the worker pill stays compact). Open it so its contents
        # show up in innerText for the assertions below.
        TH.eval_js(ctx, "(() => { const d = document.querySelector('details.bt-discover-panel'); if (d) d.open = true; })()")
        sleep(0.2)
        record("folder name MyApp shown (after opening the panel)",
               @TH.test_true TH.eval_js(ctx, "document.body.innerText.indexOf('MyApp') !== -1"))
        # Rows + Resume live inside the (default-collapsed) <details> body —
        # present in the DOM, just not in innerText until expanded — so assert
        # via the DOM, not rendered text. The row now LEADS with the prompt
        # (not the repeated folder name), so its title text is the first prompt.
        record("row leads with the prompt, not the folder name",
               @TH.test_true TH.eval_js(ctx, """
                   Array.from(document.querySelectorAll('.bt-session-name-text'))
                        .some(e => e.textContent.indexOf('refactor the parser') !== -1)
               """))
        record("'+ New thread' present per folder",
               @TH.test_true TH.dom_exists(ctx, ".bt-new-thread"))
        record("Resume buttons present for discovered sessions",
               @TH.test_true TH.eval_js(ctx, """
                   Array.from(document.querySelectorAll('.bt-session-row'))
                        .some(r => r.textContent.indexOf('Resume') !== -1)
               """))
        record("no Discover toggle button",
               @TH.test_true TH.eval_js(ctx, """
                   !Array.from(document.querySelectorAll('button')).some(b => b.innerText.trim() === 'Discover')
               """))
    end

    TH.section("expand a folder → its sibling threads are visible") do
        # Open the MyApp <details> and confirm both sibling previews show.
        TH.eval_js(ctx, """
            (() => {
                const groups = document.querySelectorAll('details.bt-group');
                for (const g of groups) { if (g.innerText.indexOf('MyApp') !== -1) g.open = true; }
            })()
        """)
        record("both sibling threads visible when expanded",
               @TH.test_true TH.wait_for(ctx, """
                   document.body.innerText.indexOf('refactor the parser') !== -1 &&
                   document.body.innerText.indexOf('add tests for IO') !== -1
               """; timeout = 3.0))
    end

    TH.section("switch to the active chat, then close it") do
        # Click the active-chat row → main panel swaps to the chat.
        TH.eval_js(ctx, "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=\\'p-1\\']').click()")
        record("clicking the row opens the chat (input mounts)",
               @TH.test_true TH.wait_for(ctx, "document.querySelector('.bt-input, .bt-app, textarea') !== null"; timeout = 5.0))
        # Click its ✕ → chat stops, row disappears, view falls back to dashboard.
        TH.eval_js(ctx, "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=\\'p-1\\'] .bt-side-close').click()")
        record("closing the chat removes its sidebar row",
               @TH.test_true TH.wait_for(ctx, """
                   !Array.from(document.querySelectorAll('.bt-sidebar .bt-side-item'))
                         .some(el => el.dataset.projectId === 'p-1')
               """; timeout = 5.0))
        # Back on the dashboard, the folder→threads tree must still be there
        # (the dashboard re-mounts on navigation; the persisted scan re-renders).
        record("folder tree still present after navigating back",
               @TH.test_true TH.wait_for(ctx, "document.querySelectorAll('.bt-group').length >= 2"; timeout = 5.0))
    end

    TH.section("no JS errors fired") do
        record("error sink empty", @TH.test_eq length(TH.js_errors(ctx)) 0)
    end

    TH.emit_screenshot(ctx; label = "tier 3b — folder→threads + active chats")
finally
    TH.report!("Tier 3b — folder→threads + active chats", results)
    TH.shutdown(ctx)
end
