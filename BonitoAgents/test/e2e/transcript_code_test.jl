# Read-only code in the transcript is text, never an editor: an edit's diff and
# an eval's code are rows of the source, highlighted by Monaco's tokenizer. A
# Monaco editor per card forced layouts on every render and was built anew each
# time its card scrolled back in (30 per scroll through 30 edits, ~70% of the
# main thread, 2026-10-20). Asserted: no editor on the page; the highlighted
# rows hold the source exactly (tabs, runs of spaces, no U+00A0 from Monaco's
# HTML), with the changed words marked; an expanded edit the transcript drops
# comes back expanded, at the height it had.
@testitem "e2e:transcript_code" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    long = join(("    x$(j) = compute($(j))" for j in 1:40), "\n")
    tab_old = "function f()\n\treturn \"a  b\"\nend"
    tab_new = "function f()\n\treturn \"a  b c\"\nend"
    env = abspath(joinpath(@__DIR__, "..", "evalenv"))
    s.agent_fn[] = function (_)
        evs = Any[TK.bt_eval("a = 1\n\tb = \"x  y\""; env_path = env, id = "tc-eval"),
                  TK.edit("/p/tab.jl", tab_old, tab_new; id = "tc-tab"),
                  TK.edit("/p/long.jl", long, replace(long, "x20 = compute(20)" => "x20 = fast(20)"); id = "tc-long")]
        for i in 1:30
            push!(evs, TK.text("after edit $(i): " * "lorem ipsum dolor sit amet "^8))
            push!(evs, TK.edit("/p/f$(i).jl", "a = $(i)\nb = 2", "a = $(i)\nb = 3"; id = "tc-$(i)"))
        end
        # Cheap rows after them, past what the block holds (160 rows): at the
        # bottom it has dropped the edits at the top.
        for i in 1:75
            push!(evs, TK.text("filler $(i)"))
            push!(evs, TK.tool(kind = "read", title = "filler tool $(i)", id = "tc-fill-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    TK.new_chat(s; title = "TranscriptCode")
    TK.send_message(s, "edits")

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    chat = "$VP.querySelector('.bt-messages')"
    card(id) = "$VP.querySelector('.bt-tool-msg[data-msg-id*=\"$(id)\"]')"
    section(id) = "$(card(id))?.querySelector('.bt-subsection-body')"
    rows(sel) = TK.eval_js(s, "[...$(sel).querySelectorAll('.bt-l')].map(r => r.textContent)")
    # Expanded, as a reader opens it: an edit that streamed in shows its diff
    # already, one replayed from the history (the transcript reloads after some
    # earlier items) is a closed card until clicked.
    function expand(id)
        TK.eval_js(s, "$(card(id)).querySelector('.bt-tool-header').dataset.expanded") == "true" && return
        TK.click(s, ".bt-tool-msg[data-msg-id*=\"$(id)\"] .bt-tool-header")
    end
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 240) == true
    @test TK.wait_for(s, "the last row in", "!!$(card("tc-fill-75"))"; timeout = 60) == true

    ctx = s.browser[]
    ECT.install_cursor(ctx)
    gutter = ECT.JS("(() => { const r = $(chat).getBoundingClientRect(); return [r.left + 3, r.top + r.height / 2]; })()")
    wheel_to(sel) = TK.wheel_into_view(s, chat, sel; step = 400)
    at_bottom() = TK.eval_js(s, "(() => { const c = $(chat); return !!$(card("tc-fill-75")) && c.scrollHeight - c.clientHeight - c.scrollTop < 2; })()")

    @testset "code is highlighted text, the source exactly" begin
        @test wheel_to(card("tc-tab"))
        expand("tc-tab")
        @test TK.wait_for(s, "the diff highlighted",
            "!!$(card("tc-tab"))?.querySelector('.bt-code-diff .bt-l span[class^=mtk]')"; timeout = 30) == true
        @test rows("$(card("tc-tab")).querySelector('.bt-code-diff')") ==
            ["function f()", "\treturn \"a  b\"", "\treturn \"a  b c\"", "end"]
        @test TK.eval_js(s, "[...$(card("tc-tab")).querySelectorAll('.bt-l-add .bt-ch')].map(e => e.textContent).join('')") == " c"
        @test TK.eval_js(s, "$(card("tc-tab")).querySelector('.bt-l-del .bt-ch') === null") == true
        @test TK.eval_js(s, "$(card("tc-tab")).querySelector('.bt-subsection-preview').textContent") == "+1 −1"

        @test wheel_to(card("tc-eval"))
        @test TK.wait_for(s, "the eval code highlighted",
            "!!$(card("tc-eval"))?.querySelector('.bt-code .bt-l span[class^=mtk]')"; timeout = 30) == true
        @test rows("$(card("tc-eval")).querySelector('.bt-code')") == ["a = 1", "\tb = \"x  y\""]
        @test TK.eval_js(s, "!/\\u00a0/.test($(VP).querySelector('.bt-messages').textContent)") == true
        @test TK.eval_js(s, "document.querySelectorAll('.monaco-editor').length") == 0
    end

    @testset "an expanded edit the transcript drops comes back expanded" begin
        @test wheel_to(card("tc-long"))
        expand("tc-long")
        # 41 lines: past the 13-line summary (~250px), whole once expanded.
        @test TK.wait_for(s, "the long edit expanded",
            "($(section("tc-long"))?.getBoundingClientRect().height || 0) > 500"; timeout = 20) == true
        h = TK.eval_js(s, "Math.round($(section("tc-long")).getBoundingClientRect().height)")

        ECT.move_to(ctx, gutter; duration = 0.05)
        for _ in 1:120
            at_bottom() && break
            ECT.wheel(ctx, 800; steps = 2)
            sleep(0.1)
        end
        @test at_bottom()
        @test TK.eval_js(s, "!$(card("tc-long"))") == true

        @test wheel_to(card("tc-long"))
        @test TK.wait_for(s, "the long edit rendered again",
            "[...($(card("tc-long"))?.querySelectorAll('.bt-l-add') || [])].some(l => l.textContent.includes('fast(20)'))"; timeout = 30) == true
        @test TK.wait_for(s, "still expanded", "Math.abs(($(section("tc-long"))?.getBoundingClientRect().height || 0) - $(h)) < 2"; timeout = 20) == true
        @test TK.eval_js(s, "$(card("tc-long")).querySelector('.bt-tool-header').dataset.expanded") == "true"
        @test TK.eval_js(s, "document.querySelectorAll('.monaco-editor').length") == 0
    end

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
