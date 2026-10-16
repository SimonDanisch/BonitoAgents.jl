# Chats with a turn in flight sit together at the top of the sidebar, under
# "Active", so switching between working chats does not mean searching a list
# sorted by name. Under the mouse the rows hold still: a chat whose turn starts
# or ends moves once the pointer leaves the sidebar, never from under a click.
# Rows move, they are not rebuilt: the same nodes, open file trees and all.
@testitem "e2e:sidebar_groups" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    s.agent_fn[] = p -> occursin("work", p) ?
        [TK.delay(4000), TK.text("done working"), TK.end_turn()] : [TK.text("ok"), TK.end_turn()]
    # Rows sort by folder name: these two bracket every other chat's.
    root = mktempdir()
    a = TK.new_chat(s; cwd = mkpath(joinpath(root, "aaa-groups")))
    TK.send_message(s, "hello")
    z = TK.new_chat(s; cwd = mkpath(joinpath(root, "zzz-groups")))
    TK.send_message(s, "hello")

    row(pid) = "document.querySelector('.bt-side-chat .bt-side-item[data-project-id=\"$(pid)\"]').closest('.bt-side-chat')"
    # The row's place in the list, and the group label it shows ("" = none).
    PLACE(pid) = """(() => { const r = $(row(pid));
        const all = [...document.querySelectorAll('.bt-sidebar .bt-side-chat')];
        const g = r.querySelector('.bt-side-group');
        return [all.indexOf(r), g.classList.contains('bt-hidden') ? '' : g.textContent]; })()"""
    place(pid) = TK.eval_js(s, PLACE(pid))
    active(pid) = "$(row(pid)).querySelector('.bt-side-icon-wrap').classList.contains('bt-glow-active')"
    @test TK.wait_for(s, "both chats listed", "!!$(row(a)) && !!$(row(z))"; timeout = 20) == true
    @test TK.wait_for(s, "both idle", "!$(active(a)) && !$(active(z))"; timeout = 30) == true
    TK.eval_js(s, "window.__zRow = $(row(z)); true")

    # The real mouse (trusted input): the hold listens for the pointer
    # entering and leaving the sidebar, which a scripted cursor never does.
    ctx = s.browser[]
    function mouse_to(js)
        x, y = round.(Int, TK.eval_js(s, js))
        ECT.send_input(ctx, "{type: 'mouseMove', x: $(x), y: $(y)}")
    end
    away = "(() => { const r = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
    over = "(() => { const r = $(row(a)).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
    mouse_to(away)

    @testset "idle, by name, no labels" begin
        pa, pz = place(a), place(z)
        @test pa[1] < pz[1]
        @test pa[2] == "" && pz[2] == ""
    end

    @testset "a working chat goes to the top, under Active" begin
        TK.send_message(s, "work")                      # z is the open chat
        @test TK.wait_for(s, "z works", active(z); timeout = 20) == true
        @test TK.wait_for(s, "z on top", "$(PLACE(z))[0] === 0"; timeout = 10) == true
        @test place(z)[2] == "Active"
        @test place(a)[2] == "" || place(a)[2] == "Other chats"
        @test TK.eval_js(s, "[...document.querySelectorAll('.bt-sidebar .bt-side-group:not(.bt-hidden)')].map(e => e.textContent)") ==
              ["Active", "Other chats"]
        # When it is done, back to its place by name, and the labels go.
        @test TK.wait_for(s, "z done", "!$(active(z))"; timeout = 30) == true
        @test TK.wait_for(s, "z back below a", "$(PLACE(z))[0] > $(PLACE(a))[0]"; timeout = 10) == true
        @test TK.eval_js(s, "document.querySelectorAll('.bt-sidebar .bt-side-group:not(.bt-hidden)').length") == 0
    end

    @testset "under the mouse the rows hold still" begin
        mouse_to(over)
        before = place(z)[1]
        TK.send_message(s, "work")
        @test TK.wait_for(s, "z works", active(z); timeout = 20) == true
        sleep(1)
        @test place(z)[1] == before                      # it glows where it is
        mouse_to(away)
        @test TK.wait_for(s, "z moves up once the mouse leaves", "$(PLACE(z))[0] === 0"; timeout = 10) == true
        @test TK.wait_for(s, "z done", "!$(active(z))"; timeout = 30) == true
        @test TK.wait_for(s, "z back below a", "$(PLACE(z))[0] > $(PLACE(a))[0]"; timeout = 10) == true
    end

    # Moved, never rebuilt.
    @test TK.eval_js(s, "$(row(z)) === window.__zRow") == true
    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
