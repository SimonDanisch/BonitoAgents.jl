# The worker's session list is built when it's opened, through the real page: the
# dashboard is part of every page, even one that opens straight into a chat, so
# what a closed list costs is what every page load pays.
#
# The contract:
#   1. a page load with hundreds of discovered sessions builds no folder or row and
#      makes only a handful of fetches, with the counts still in the header,
#   2. opening the list builds its folders and no rows, opening a folder builds its rows,
#   3. closing and reopening keeps what was built,
#   4. "+ New thread" and Rescan in a header don't close or open by accident,
#   5. updates reach what's open: a new folder leaves an open folder open, a rename
#      reaches its row.
#
# ISOLATED: seeding state.discovered would pollute a shared server's dashboard.
@testitem "e2e:discover_lazy" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    import BonitoAgents as BT

    function seed!(state, wid; sessions, folders)
        lock(state.lock) do
            state.discovered[][wid] = [Dict{String,Any}(
                "session_id" => "sess-$(i)", "path" => "/work/folder$(i % folders)", "name" => "folder$(i % folders)",
                "first_prompt" => "prompt number $(i)", "last_used" => 1.7e9 + i,
                "kind" => "session", "running" => false) for i in 1:sessions]
        end
        notify(state.discovered)
    end
    count(selector) = "document.querySelectorAll($(repr(selector))).length"
    folder(name) = "[...document.querySelectorAll('details.bt-group')].find(g => g.querySelector('.bt-group-name').textContent === $(repr(name)))"
    fetches = "performance.getEntriesByType('resource').filter(e => e.initiatorType === 'fetch').length"

    # "+ New thread" really opens a chat here.
    real_folder = mkpath(joinpath(mktempdir(), "brandnew"))
    server = TK.dev_server(agent = prompt -> [TK.text("echo: $(prompt)"), TK.end_turn()])
    try
        TK.open_browser(server)
        state = server.h.state
        @test timedwait(() -> !isempty(state.workers[]), 30.0) === :ok
        wid = first(keys(state.workers[]))
        seed!(state, wid; sessions = 300, folders = 30)
        TK.navigate(server, "/")
        @test TK.wait_for(server, "the worker's header", "!!document.querySelector('details.bt-discover-panel')"; timeout = 60) == true
        @test TK.wait_for(server, "the count in the header",
            "document.querySelector('.bt-discover-title').textContent === 'projects (30)'"; timeout = 15) == true
        sleep(2)   # What the page still has to load would show up here.

        @testset "a page load builds nothing below the header" begin
            @test TK.eval_js(server, count(".bt-group")) == 0
            @test TK.eval_js(server, count(".bt-session-row")) == 0
            # 300 rows and 30 folders made one fetch each when they were built with the page.
            @test TK.eval_js(server, fetches) < 30
        end

        @testset "opening the list builds folders, opening a folder builds rows" begin
            TK.click(server, "details.bt-discover-panel > summary")
            @test TK.wait_for(server, "the folders", "$(count("details.bt-group")) === 30"; timeout = 15) == true
            @test TK.eval_js(server, "$(fetches) < 30") == true
            @test TK.eval_js(server, count(".bt-session-row")) == 0
            @test TK.eval_js(server, "document.querySelector('details.bt-discover-panel').open") == true

            TK.eval_js(server, "$(folder("folder7")).querySelector('summary').click(); true")
            @test TK.wait_for(server, "its rows", "$(count(".bt-session-row")) === 10"; timeout = 15) == true
            @test TK.eval_js(server, "$(folder("folder7")).innerText.includes('prompt number 7')") == true
        end

        @testset "closing and reopening keeps what was built" begin
            TK.eval_js(server, "window.__row = document.querySelector('.bt-session-row'); true")
            TK.eval_js(server, "$(folder("folder7")).querySelector('summary').click(); true")
            @test TK.wait_for(server, "closed", "!$(folder("folder7")).open"; timeout = 5) == true
            TK.eval_js(server, "$(folder("folder7")).querySelector('summary').click(); true")
            @test TK.wait_for(server, "open again", "$(folder("folder7")).open"; timeout = 5) == true
            sleep(0.5)
            @test TK.eval_js(server, "window.__row.isConnected") == true
            @test TK.eval_js(server, count(".bt-session-row")) == 10
        end

        @testset "a new folder leaves an open folder open" begin
            lock(state.lock) do
                push!(state.discovered[][wid], Dict{String,Any}(
                    "session_id" => "sess-new", "path" => real_folder, "name" => "brandnew",
                    "first_prompt" => "the new one", "last_used" => 1.8e9,
                    "kind" => "session", "running" => false))
            end
            notify(state.discovered)
            @test TK.wait_for(server, "the new folder", "$(count("details.bt-group")) === 31"; timeout = 15) == true
            @test TK.wait_for(server, "the open folder's rows", "$(count(".bt-session-row")) === 10"; timeout = 15) == true
            @test TK.eval_js(server, "$(folder("folder7")).open") == true
            # It still works after the list around it re-rendered.
            TK.eval_js(server, "$(folder("brandnew")).querySelector('summary').click(); true")
            @test TK.wait_for(server, "the new folder's row", "$(folder("brandnew")).innerText.includes('the new one')"; timeout = 15) == true
            @test TK.eval_js(server, "document.querySelector('.bt-discover-title').textContent") == "projects (31)"
        end

        @testset "a rename reaches the row, an unrelated change re-renders nothing" begin
            TK.eval_js(server, "window.__row = $(folder("brandnew")).querySelector('.bt-session-row'); true")
            notify(state.projects)   # Nothing the rows show changed.
            sleep(0.5)
            @test TK.eval_js(server, "window.__row.isConnected") == true
            lock(state.lock) do
                p = BT.ProjectInfo("renamed", "brandnew", wid, real_folder, real_folder, BT.Dates.now())
                p.resume_session_id = "sess-new"
                p.title[] = "Renamed Chat"
                p.dismissed = true
                state.projects[]["renamed"] = p
            end
            notify(state.projects)
            @test TK.wait_for(server, "the title", "$(folder("brandnew")).innerText.includes('Renamed Chat')"; timeout = 15) == true
            lock(state.lock) do
                delete!(state.projects[], "renamed")
            end
            notify(state.projects)
        end

        @testset "a new count reaches the header and leaves the folder open" begin
            @test TK.eval_js(server, "$(folder("folder7")).open") == true
            lock(state.lock) do
                push!(state.discovered[][wid], Dict{String,Any}(
                    "session_id" => "sess-extra", "path" => "/work/folder7", "name" => "folder7",
                    "first_prompt" => "one more", "last_used" => 1.7e9,
                    "kind" => "session", "running" => false))
            end
            notify(state.discovered)
            @test TK.wait_for(server, "the new count",
                "$(folder("folder7")).querySelector('.bt-group-meta').textContent.startsWith('11 sessions')"; timeout = 15) == true
            @test TK.wait_for(server, "its rows", "$(folder("folder7")).querySelectorAll('.bt-session-row').length === 11"; timeout = 15) == true
            @test TK.eval_js(server, "$(folder("folder7")).open") == true
        end

        @testset "+ New thread opens a chat, it doesn't toggle the folder" begin
            TK.eval_js(server, "$(folder("brandnew")).querySelector('summary').click(); true")
            @test TK.wait_for(server, "closed", "!$(folder("brandnew")).open"; timeout = 5) == true
            TK.eval_js(server, "$(folder("brandnew")).querySelector('.bt-new-thread').click(); true")
            @test TK.wait_for(server, "the chat", "!!document.querySelector('.bt-chatpane[aria-hidden=false] .bt-text-input')"; timeout = 30) == true
            TK.to_dashboard(server)
            @test TK.wait_for(server, "back home", "!document.querySelector('.bt-chatpane[aria-hidden=false]')"; timeout = 15) == true
            @test TK.eval_js(server, "$(folder("brandnew")).open") == false
        end

        @testset "Rescan opens a closed list, and doesn't close an open one" begin
            rescan = "[...document.querySelectorAll('details.bt-discover-panel .bw-btn')].find(b => b.textContent.includes('Rescan'))"
            TK.eval_js(server, "document.querySelector('details.bt-discover-panel > summary').click(); true")
            @test TK.wait_for(server, "closed", "!document.querySelector('details.bt-discover-panel').open"; timeout = 5) == true
            TK.eval_js(server, "$(rescan).click(); true")
            @test TK.wait_for(server, "open", "document.querySelector('details.bt-discover-panel').open"; timeout = 5) == true
            sleep(0.3)
            @test TK.eval_js(server, "document.querySelector('details.bt-discover-panel').open") == true
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
