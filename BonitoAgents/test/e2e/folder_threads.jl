# End-to-end: the folder→threads discovery browser + the active-chats sidebar,
# driven black-box through a REAL dev_server (real worker, real ACP wire, mock
# agent binary). Ports the legacy Tier 3b electron test (test_folder_threads.jl)
# off the old internal harness (TH.make_state / open_window / eval_js) onto
# TestKit, preserving its assertions:
#
#   ACTIVE-CHATS SIDEBAR (the "Open chats" list)
#     * a RUNNING chat shows as a `.bt-side-item` with a close ✕ (`.bt-side-close`),
#     * clicking the row opens its chat (input mounts),
#     * clicking the ✕ closes it (its sidebar row disappears, view → dashboard).
#
#   FOLDER→THREADS TREE (the always-visible discover tree, KeyedList-driven)
#     * the persisted worker scan (state.discovered) renders one `.bt-group`
#       per folder (two folders here: MyApp with two sibling threads, Other),
#     * inside the collapsed `details.bt-discover-panel`: the folder name shows,
#       each row LEADS with the first prompt (`.bt-session-name-text`, not the
#       folder name), every folder has a "+ New thread" (`.bt-new-thread`), and
#       discovered sessions render a "Resume" button (`.bt-session-row`),
#     * there is NO "Discover" toggle button (the panel is always present),
#     * expanding a folder's `details.bt-group` reveals both sibling previews,
#     * the tree SURVIVES navigating away (closing the chat → dashboard re-mounts
#       and the persisted scan re-renders).
#
# Unlike the legacy test (which faked a ChatModel via MockTransport and poked an
# in-process state struct), this drives the production stack: the running chat
# is a real `new_chat` (real worker session, mock agent), and the discover tree
# is seeded the only black-box way available — pushing into the worker-scan sink
# `state.discovered` (exactly what a real worker's ~/.claude scan publishes; see
# resume_discover_test.jl, which seeds the same sink). The worker never produces
# discoverable jsonl in the harness, so seeding that published sink IS the
# black-box analog of "the worker discovered sessions on disk".
#
# ISOLATED dev_server: seeding state.discovered for this worker would pollute a
# shared soak server's dashboard for every neighbouring suite, and closing the
# chat asserts on an empty-ish sidebar — both demand a private server.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# Seed the worker's published discover scan: one folder (MyApp) with two sibling
# threads, plus a second folder (Other). This is the sink a real worker's
# ~/.claude scan writes to; the always-visible tree renders straight from it.
# The folders are REAL temp dirs: discover drops entries whose folder no longer
# exists (its only filter), so seeded paths must exist to render. Returns the
# `(; myapp, other)` paths for the testsets that build projects on them.
function seed_discovered!(server, wid)
    state = server.h.state
    base   = mktempdir()
    myapp  = mkpath(joinpath(base, "MyApp"))
    other  = mkpath(joinpath(base, "Other"))
    lock(state.lock) do
        state.discovered[][wid] = [
            Dict{String,Any}("session_id" => "aaaa1111", "path" => myapp, "name" => "MyApp",
                             "first_prompt" => "refactor the parser", "last_used" => 1.70e9,
                             "kind" => "session", "running" => true),
            Dict{String,Any}("session_id" => "bbbb2222", "path" => myapp, "name" => "MyApp",
                             "first_prompt" => "add tests for IO", "last_used" => 1.69e9, "kind" => "session"),
            Dict{String,Any}("session_id" => "cccc3333", "path" => other, "name" => "Other",
                             "first_prompt" => "write the README", "last_used" => 1.68e9, "kind" => "session"),
        ]
    end
    notify(state.discovered)
    return (; myapp, other)
end

# Open the (default-collapsed) discover panel so its contents land in innerText.
open_discover_panel(server) = TK.eval_js(server,
    "(() => { document.querySelectorAll('details.bt-discover-panel').forEach(d => d.open = true); return true; })()")

function run_suite(server)
    server.agent_fn[] = (msg -> [TK.text("Echo: $msg")])
    state = server.h.state
    wid   = first(keys(state.workers[]))

    # A real running chat so the active-chats sidebar has something to list.
    pid = TK.new_chat(server; title = "RunningChat")
    TK.send_message(server, "first message")

    # Persist the discover scan, then return to the dashboard where the tree +
    # the active-chats sidebar both live.
    seeded = seed_discovered!(server, wid)
    TK.to_dashboard(server)

    @testset "folder→threads browser + active chats (UI)" begin
        @testset "active-chats sidebar lists the running chat" begin
            @test TK.wait_for(server, "running chat row present",
                "[...document.querySelectorAll('.bt-sidebar .bt-side-item')].some(el => el.dataset.projectId === $(repr(pid)))";
                timeout = 10) == true
            @test TK.eval_js(server,
                "!!document.querySelector('.bt-sidebar .bt-side-item[data-project-id=$(repr(pid))] .bt-side-close')") == true
        end

        @testset "folder→threads tree mounts (KeyedList renders)" begin
            # Two folder groups render straight from the persisted scan — the live
            # proof the KeyedList content actually mounts in the browser.
            @test TK.wait_for(server, "two folder groups",
                "document.querySelectorAll('.bt-group').length >= 2"; timeout = 10) == true

            # Open the default-collapsed discover panel so its body shows up.
            open_discover_panel(server)
            @test TK.wait_for(server, "folder name MyApp shown",
                "document.body.innerText.indexOf('MyApp') !== -1"; timeout = 5) == true

            # Rows lead with the prompt (not the repeated folder name); present in
            # the DOM even while the per-folder <details> stays collapsed.
            @test TK.eval_js(server, """
                [...document.querySelectorAll('.bt-session-name-text')]
                    .some(e => e.textContent.indexOf('refactor the parser') !== -1)""") == true
            # "+ New thread" present per folder.
            @test TK.eval_js(server, "!!document.querySelector('.bt-new-thread')") == true
            # Resume buttons for discovered (session-bearing) rows.
            @test TK.eval_js(server, """
                [...document.querySelectorAll('.bt-session-row')]
                    .some(r => r.textContent.indexOf('Resume') !== -1)""") == true
            # No "Discover" toggle button — the panel is always present.
            @test TK.eval_js(server, """
                ![...document.querySelectorAll('button')].some(b => (b.innerText||'').trim() === 'Discover')""") == true
        end

        @testset "expand a folder → its sibling threads are visible" begin
            # Open the MyApp <details> and confirm both sibling previews show.
            TK.eval_js(server, """(() => {
                for (const g of document.querySelectorAll('details.bt-group')) {
                    if (g.innerText.indexOf('MyApp') !== -1) g.open = true;
                }
                return true; })()""")
            @test TK.wait_for(server, "both sibling threads visible",
                """document.body.innerText.indexOf('refactor the parser') !== -1 &&
                   document.body.innerText.indexOf('add tests for IO') !== -1"""; timeout = 5) == true
        end

        @testset "a renamed chat's title shows in the discovered row" begin
            # Regression: renaming a chat must reach the dashboard projects
            # overview too. A (dismissed) project that resumes the 'Other'
            # session pins a title; the discovered row must show THAT title —
            # the same persisted `ProjectInfo.title` the sidebar/header read —
            # not the first-prompt preview ("write the README").
            BT = TK.BT
            lock(state.lock) do
                p = BT.ProjectInfo("renamed-other", "Other", wid,
                                   seeded.other, seeded.other, BT.Dates.now())
                p.resume_session_id = "cccc3333"
                p.title = "Renamed Other Chat"
                p.dismissed = true
                state.projects[]["renamed-other"] = p
            end
            notify(state.projects)
            TK.eval_js(server, "(() => { document.querySelectorAll('details.bt-group').forEach(g=>g.open=true); return true; })()")
            @test TK.wait_for(server, "renamed title shown in discovered row",
                "[...document.querySelectorAll('.bt-session-name-text')].some(e => (e.textContent||'').includes('Renamed Other Chat'))";
                timeout = 10) == true
            @test TK.eval_js(server,
                "![...document.querySelectorAll('.bt-session-name-text')].some(e => (e.textContent||'').includes('write the README'))") == true
        end

        @testset "discover is unconditional: in-sidebar rows stay visible with a pill; missing folders are skipped" begin
            BT = TK.BT
            # Row helper: the cccc3333 row is the one titled "Renamed Other Chat"
            # (pinned by the previous testset's project).
            row_visible = "[...document.querySelectorAll('.bt-session-name-text')].some(e => (e.textContent||'').includes('Renamed Other Chat'))"
            pill_shown  = "[...document.querySelectorAll('.bt-session-row .bt-pill')].some(e => (e.textContent||'') === 'in sidebar' && !e.classList.contains('bt-hidden'))"

            # Un-dismiss the project → chat_in_sidebar(p) is true. The OLD code
            # dropped the row here (the "chat is nowhere" bug); now it must stay
            # visible and gain the "in sidebar" pill.
            lock(state.lock) do
                state.projects[]["renamed-other"].dismissed = false
            end
            notify(state.projects)
            @test TK.wait_for(server, "in-sidebar row still visible", row_visible; timeout = 10) == true
            @test TK.wait_for(server, "'in sidebar' pill shown", pill_shown; timeout = 10) == true

            # Re-dismiss → the pill hides, the row remains.
            lock(state.lock) do
                state.projects[]["renamed-other"].dismissed = true
            end
            notify(state.projects)
            @test TK.wait_for(server, "pill hidden after dismiss", "!($pill_shown)"; timeout = 10) == true
            @test TK.eval_js(server, row_visible) == true

            # NOTE: the "folder no longer exists" drop happens WORKER-side at
            # scan time (`entry_from_jsonl`'s isdir — the paths live on the
            # worker's disk, not the server's), so the server renders whatever
            # the worker published. That filter is covered by the worker-scan
            # unit test (unit:worker_scan), not here.
        end

        @testset "switch to the active chat, then close it" begin
            # Click the running-chat row → main panel swaps to the chat.
            TK.eval_js(server,
                "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=$(repr(pid))]').click()")
            @test TK.wait_for(server, "clicking the row opens the chat (input mounts)",
                "!!document.querySelector('.bt-text-input')"; timeout = 10) == true

            # Click its ✕ → chat stops, its sidebar row disappears.
            TK.eval_js(server,
                "document.querySelector('.bt-sidebar .bt-side-item[data-project-id=$(repr(pid))] .bt-side-close').click()")
            @test TK.wait_for(server, "closing the chat removes its sidebar row",
                "![...document.querySelectorAll('.bt-sidebar .bt-side-item')].some(el => el.dataset.projectId === $(repr(pid)))";
                timeout = 10) == true

            # Back on the dashboard, the folder→threads tree must still be there
            # (the dashboard re-mounts on navigation; the persisted scan re-renders).
            @test TK.wait_for(server, "folder tree still present after navigating back",
                "document.querySelectorAll('.bt-group').length >= 2"; timeout = 10) == true
        end
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server()
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
    TK.exit_success()
end
