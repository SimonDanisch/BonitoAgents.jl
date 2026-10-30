# The heavy part of a row, its tool body, is freed once it is a few screens from
# the view and rendered again when it comes back: a long turn of big edits keeps
# only the diffs near the reader in the page, not every one the transcript holds
# (a turn of 60 held 60, 69 MB of heap and 27k elements). The rows stay, and a
# freed row keeps its height, so nothing the reader sees moves. A body counts
# as heavy from 300 elements (`freeBody`): these diffs are 400 lines each.
@testitem "e2e:far_bodies" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    N = 40
    code(i) = join(("    x$(j) = compute($(j), $(i))" for j in 1:400), "\n")
    s.agent_fn[] = function (p)
        occursin("edits", p) || return [TK.text("echo: $(p)"), TK.end_turn()]
        evs = Any[]
        for i in 1:N
            push!(evs, TK.text("edit number $(i): " * "lorem ipsum dolor "^6))
            push!(evs, TK.edit("/p/f$(i).jl", code(i), replace(code(i), "x5 = " => "y5 = "); id = "fb-$(i)-e"))
        end
        push!(evs, TK.text("FAR-BODIES-END"))
        push!(evs, TK.end_turn())
        return evs
    end
    pid = TK.new_chat(s; title = "FarBodies")
    TK.send_message(s, "edits please")

    C = "document.querySelector('.bt-chatpane[data-pane-pid=\"$(pid)\"] .bt-messages')"
    CH = "$C.__bt_chat"
    card(i) = "$C.querySelector('.bt-tool-msg[data-msg-id*=\"fb-$(i)-e\"]')"
    DIFFS = "$C.querySelectorAll('.bt-code-diff').length"
    @test TK.wait_for(s, "the turn done",
        "$C.textContent.includes('FAR-BODIES-END') && !document.querySelector('.bt-busy.bt-busy-active')"; timeout = 120) == true
    @test TK.wait_for(s, "the last diff mounted", "!!$(card(N))?.querySelector('.bt-code-diff')"; timeout = 60) == true
    sleep(2)

    @testset "far from the view, the rows stay and hold no diffs" begin
        @test TK.eval_js(s, "$CH.block.order.length === $CH.block.count") == true     # nothing dropped
        n = Int(TK.eval_js(s, DIFFS))
        @test 0 < n < N ÷ 2
        # Freed, or never built: a body far away waits until the reader is near.
        @test TK.eval_js(s, "[1, 2, 3, 4, 5, 6].every(i => !$C.querySelector(`.bt-tool-msg[data-msg-id*=\"fb-\${i}-e\"] .bt-code-diff`))") == true
    end

    # Home and End, as the reader presses them: a press in the transcript first.
    x, y = TK.eval_js(s, "(() => { const r = $C.getBoundingClientRect(); return [Math.round(r.left + 3), Math.round(r.top + r.height / 2)]; })()")
    ctx = s.browser[]
    ECT.send_input(ctx, "{type: 'mouseDown', x: $x, y: $y, button: 'left', clickCount: 1}")
    ECT.send_input(ctx, "{type: 'mouseUp', x: $x, y: $y, button: 'left', clickCount: 1}")
    TK.eval_js(s, "document.activeElement && document.activeElement.blur(); true")
    height(i) = TK.eval_js(s, "$(card(i)).getBoundingClientRect().height")

    @testset "near it, the body is built; far again, freed at the height it had" begin
        TK.press_key!(s, "Home")
        @test TK.wait_for(s, "the first diff built", "!!$(card(1)).querySelector('.bt-code-diff .bt-l')"; timeout = 30) == true
        sleep(0.5)
        live = height(1)
        @test TK.wait_for(s, "the far end freed", "!$(card(N)).querySelector('.bt-code-diff')"; timeout = 30) == true
        TK.press_key!(s, "End")
        @test TK.wait_for(s, "the first row freed", "!!$(card(1)).querySelector('.bt-body-freed')"; timeout = 30) == true
        @test abs(height(1) - live) <= 1                 # nothing moved
        TK.press_key!(s, "Home")
        @test TK.wait_for(s, "the first diff back", "!!$(card(1)).querySelector('.bt-code-diff .bt-l')"; timeout = 30) == true
        sleep(0.5)
        @test abs(height(1) - live) <= 1
    end

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
