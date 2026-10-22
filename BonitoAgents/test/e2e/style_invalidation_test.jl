# A change inside the chat restyles what it touches, not the whole page. A `*`
# after a `:has()` (`.bt-header-row:has(...) .bt-header-session > *`) made Chrome
# restyle the whole subtree of `.bt-stage` on any DOM change inside it: every
# timer tick, streamed token, Monaco render and scroll step restyled all 15k
# elements of a long chat, 65 ms each, which is what made scrolling stutter and
# typing on a phone lag. The `:has()` rules that remained cost the same way in
# smaller steps: Chrome checks one on every DOM change under its anchor, and
# `.bt-tool-msg:has(.bt-embed)` searched a whole card on each. So we have
# none (Monaco's own sheet keeps one, `.rendered-markdown li:has(...)`, scoped
# to its hover lists). Measured from a Chromium trace of a scroll, as the
# Performance panel records it.
@testitem "e2e:style_invalidation" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    body(i, extra) = join(("    v$(j) = classify(mesh, $(i + j))$(extra)" for j in 1:25), "\n")
    s.agent_fn[] = _ -> vcat(
        reduce(vcat, [[TK.text("Step $(i): tighten block $(i)."),
                       TK.edit("/p/block$(i).jl", body(i, ""), body(i, "  # checked"); id = "si-$(i)")]
                      for i in 1:30]),
        [TK.end_turn()])
    first_chat = TK.new_chat(s; title = "StyleInvalidation")
    TK.send_message(s, "edit everything")

    VP = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    chat = "$VP.querySelector('.bt-messages')"
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 120) == true
    @test TK.wait_for(s, "the last diffs highlighted",
        "$VP.querySelectorAll('.bt-code-diff .bt-l span[class^=mtk]').length > 50"; timeout = 60) == true

    # No `:has()` in our rules (the ones naming a `.bt-` class); a failure
    # names each one with where its sheet came from.
    has_rules = TK.eval_js(s, """(() => {
        const found = [];
        const owner = (sheet) => sheet.href || (sheet.ownerNode
            ? sheet.ownerNode.nodeName + ' ' + (sheet.ownerNode.textContent || '').slice(0, 120) : '?');
        const walk = (rules, sheet) => { for (const r of rules) {
            if (r.selectorText) { if (r.selectorText.includes(':has(') && r.selectorText.includes('.bt-')) found.push(r.selectorText + '  <-  ' + owner(sheet)); }
            else if (r.cssRules) walk(r.cssRules, sheet); } };
        for (const sheet of document.styleSheets) walk(sheet.cssRules, sheet);
        return found; })()""")
    @test isempty(has_rules)

    # Scroll up through the chat while Chromium records: the transcript window
    # mounts cards, code gets highlighted, the new-message pill updates. No
    # style recalculation may touch most of the page.
    elements = TK.eval_js(s, "document.getElementsByTagName('*').length")
    ctx = s.browser[]
    ECT.install_cursor(ctx)
    point = ECT.JS("(() => { const r = $(chat).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()")
    ECT.move_to(ctx, point; duration = 0.05)
    trace = TK.record_trace(s) do
        ECT.wheel(ctx, -3000; steps = 60)
        sleep(0.5)
    end
    recalcs = [e for e in trace if get(e, "name", "") == "UpdateLayoutTree" && get(e, "ph", "") == "X"]
    @test length(recalcs) > 10
    touched = maximum(e -> something(get(get(e, "args", Dict()), "elementCount", nothing), 0), recalcs)
    @info "style recalculation while scrolling" elements largest_recalc = touched recalcs = length(recalcs)
    @test elements > 2000
    @test touched < elements / 2

    # The desktop trace from 2026-10-20 froze for 7.09 seconds while revealing
    # an ALREADY loaded chat. Its hidden Monaco editors woke together and each
    # render forced another chat-wide style recalculation. Scrolling alone
    # misses that trigger: keep two populated chats and switch between them.
    second_chat = TK.new_chat(s; title = "StyleInvalidationSwitch")
    TK.send_message(s, "edit everything again")
    @test TK.wait_for(s, "the second agent done",
        "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 120) == true
    @test TK.wait_for(s, "the second chat highlighted",
        "$VP.querySelectorAll('.bt-code-diff .bt-l span[class^=mtk]').length > 50"; timeout = 60) == true
    # Both panes remain mounted; returning to either must keep its static code.
    @test TK.eval_js(s, "document.querySelectorAll('.bt-chatpane .monaco-editor').length") == 0
    switch_trace = TK.record_trace(s) do
        for pid in (first_chat, second_chat, first_chat, second_chat)
            TK.open_chat(s, pid)
            @test TK.wait_for(s, "the selected pane shown",
                "$VP.dataset.panePid === $(TK.json(pid))"; timeout = 20) == true
            sleep(0.25)
        end
    end
    switch_recalcs = [e for e in switch_trace if get(e, "name", "") == "UpdateLayoutTree" && get(e, "ph", "") == "X"]
    @test !isempty(switch_recalcs)
    # Showing a pane necessarily styles that pane once. It must not repeatedly
    # restyle the thousands of highlighted rows as each editor used to do.
    broad = count(e -> get(get(e, "args", Dict()), "elementCount", 0) > 2000, switch_recalcs)
    style_ms = sum(e -> get(e, "dur", 0), switch_recalcs; init = 0) / 1000
    @info "style recalculation switching existing chats" recalcs = length(switch_recalcs) broad style_ms
    @test broad <= 8
    @test TK.eval_js(s, "document.querySelectorAll('.bt-chatpane .monaco-editor').length") == 0

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
