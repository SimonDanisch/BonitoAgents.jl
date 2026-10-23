# Chats with a turn in flight sit together at the top of the sidebar, under
# "Active", so switching between working chats does not mean searching a list
# sorted by name. The other chats follow, the one whose turn ended last first:
# a chat that just went quiet stays right below the active ones instead of
# dropping to its name's place. Under the mouse the rows hold still: a chat
# whose turn starts or ends moves once the pointer leaves the sidebar, never
# from under a click. Rows move, they are not rebuilt: the same nodes, open
# file trees and all.
@testitem "e2e:sidebar_groups" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    s.agent_fn[] = p -> occursin("work", p) ?
        [TK.delay(4000), TK.text("done working"), TK.end_turn()] : [TK.text("ok"), TK.end_turn()]
    # Names that would sort these two apart (a first): the order below is the
    # turns', not the names'.
    root = mktempdir()
    a = TK.new_chat(s; cwd = mkpath(joinpath(root, "aaa-groups")))
    TK.send_message(s, "hello")
    # a's turn ends before z's starts: `send_message` does not wait for the
    # answer, and each first reply includes its own agent's cold start, so two
    # chats sent to back to back finished in either order.
    @test TK.wait_for(s, "a answered",
        "[...document.querySelectorAll('.bt-chatpane[aria-hidden=false] .bt-agent-msg')].some(m => m.innerText.trim() === 'ok')";
        timeout = 60) == true
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

    # The chat that is open in the window, with its composer: `send_message`
    # writes to that one.
    function open!(pid)
        TK.open_chat(s, pid)
        TK.wait_for(s, "$(pid) open", "!!document.querySelector('.bt-side-item.bt-side-active[data-project-id=\"$(pid)\"]')";
                    timeout = 10)
    end

    @testset "idle: the chat that answered last first, no labels" begin
        pa, pz = place(a), place(z)
        @test pz[1] < pa[1]                              # z answered after a
        @test pa[2] == "" && pz[2] == ""
    end

    @testset "a working chat goes to the top, under Active, and stays there when done" begin
        open!(a)
        TK.send_message(s, "work")
        @test TK.wait_for(s, "a works", active(a); timeout = 20) == true
        @test TK.wait_for(s, "a on top", "$(PLACE(a))[0] === 0"; timeout = 10) == true
        @test place(a)[2] == "Active"
        @test place(z)[2] == "" || place(z)[2] == "Other chats"
        @test TK.eval_js(s, "[...document.querySelectorAll('.bt-sidebar .bt-side-group:not(.bt-hidden)')].map(e => e.textContent)") ==
              ["Active", "Other chats"]
        # Done, it heads the other chats, above z that answered before it, and
        # the labels go.
        @test TK.wait_for(s, "a done", "!$(active(a))"; timeout = 30) == true
        @test TK.wait_for(s, "the labels gone", "document.querySelectorAll('.bt-sidebar .bt-side-group:not(.bt-hidden)').length === 0";
                          timeout = 10) == true
        @test place(a)[1] == 0 && place(a)[1] < place(z)[1]
    end

    @testset "under the mouse the rows hold still" begin
        open!(z)
        mouse_to(over)
        before = place(z)[1]
        TK.send_message(s, "work")
        @test TK.wait_for(s, "z works", active(z); timeout = 20) == true
        sleep(1)
        @test place(z)[1] == before                      # it glows where it is
        mouse_to(away)
        @test TK.wait_for(s, "z moves up once the mouse leaves", "$(PLACE(z))[0] === 0"; timeout = 10) == true
        @test TK.wait_for(s, "z done", "!$(active(z))"; timeout = 30) == true
        # Done, z stays on top: its turn ended last.
        sleep(1)
        @test place(z)[1] == 0 && place(z)[1] < place(a)[1]
    end

    # Moved, never rebuilt.
    @test TK.eval_js(s, "$(row(z)) === window.__zRow") == true
    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
