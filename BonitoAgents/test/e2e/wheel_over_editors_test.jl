# A wheel over code or a diff scrolls the chat, unless the code's section can
# still scroll that way itself. (As Monaco editors they cancelled every wheel,
# so over an eval card's code or an edit's diff the chat stood still: "I can't
# scroll up".) ElectronCall's wheel scrolls the nearest box that can move unless
# a handler cancels it, as a browser's own wheel does.
@testitem "e2e:wheel_over_editors" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    env = abspath(joinpath(@__DIR__, "..", "evalenv"))
    long = join(("    x$(j) = compute($(j))" for j in 1:60), "\n")
    s.agent_fn[] = _ -> vcat(
        [TK.text("filler $(i): " * "lorem ipsum dolor sit amet "^14) for i in 1:6],
        [TK.edit("/p/short.jl", "a = 1\nb = 2", "a = 1\nb = 3"; id = "wh-short"),
         TK.edit("/p/long.jl", long, replace(long, "x30 = compute(30)" => "x30 = fast(30)"); id = "wh-long"),
         TK.bt_eval("x = 1\ny = x + 1"; env_path = env, id = "wh-eval")],
        [TK.text("tail $(i): " * "lorem ipsum dolor sit amet "^14) for i in 1:6],
        [TK.end_turn()])
    TK.new_chat(s; title = "WheelEditors")
    TK.send_message(s, "edit and eval")

    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    chat = "$VP.querySelector('.bt-messages')"
    card(id) = "$VP.querySelector('.bt-tool-msg[data-msg-id*=\"$(id)\"]')"
    @test TK.wait_for(s, "the eval card done",
        "($(card("wh-eval"))?.querySelector('.bt-tool-status')?.textContent || '') === 'completed'"; timeout = 180) == true
    @test TK.wait_for(s, "both diffs and the eval code mounted",
        "!!$(card("wh-short"))?.querySelector('.bt-code-diff .bt-l') && " *
        "!!$(card("wh-long"))?.querySelector('.bt-code-diff .bt-l') && " *
        "!!$(card("wh-eval"))?.querySelector('.bt-code .bt-l')"; timeout = 60) == true
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 60) == true

    ctx = s.browser[]
    ECT.install_cursor(ctx)
    scroll_top() = TK.eval_js(s, "Math.round($(chat).scrollTop)")
    wheel_to(sel) = TK.wheel_into_view(s, chat, sel)
    # Wheel up over `sel`; how far the chat moved.
    function moved_over(sel; dy = -120, steps = 3)
        point = ECT.JS("(() => { const r = $(sel).getBoundingClientRect(); return [r.left + 40, r.top + Math.min(r.height / 2, 20)]; })()")
        ECT.move_to(ctx, point; duration = 0.05)
        before = scroll_top()
        ECT.wheel(ctx, dy; steps)
        sleep(0.3)
        return scroll_top() - before
    end

    # The sections' boxes, as they show on screen (not their content, which a
    # capped diff holds far past its box).
    # The eval card's code: two lines, so its section can't scroll. The chat does.
    code = "$(card("wh-eval")).querySelector('.bt-code').closest('.bt-subsection-body')"
    @test wheel_to(code)
    @test moved_over(code) < -100

    # A short diff: the same.
    short = "$(card("wh-short")).querySelector('.bt-subsection-body')"
    @test wheel_to(short)
    @test moved_over(short) < -100

    # A long diff capped below its content scrolls itself first: down over it,
    # its lines move, and the chat, which could move down too, stays.
    longsel = "$(card("wh-long")).querySelector('.bt-subsection-body')"
    @test wheel_to(longsel)
    @test TK.eval_js(s, "(() => { const c = $(chat); return c.scrollHeight - c.clientHeight - c.scrollTop; })()") > 200
    # How far the diff's section is scrolled.
    scrolled() = TK.eval_js(s, "$(longsel).scrollTop")
    @test scrolled() == 0
    @test moved_over(longsel; dy = 120) == 0
    @test scrolled() > 20
    # Up again: back at its top it lets go, and the chat scrolls on.
    @test moved_over(longsel; dy = -600, steps = 12) < -100

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
