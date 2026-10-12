# Editors live as long as their rows are on the page. A row that leaves the
# virtual window ends its body's session, and BonitoBook disposes the editors
# then; Monaco kept every one before (350 diffs, 214 MB after one scroll).
# Asserted: Monaco's registry holds only what is on the page (the one inspection
# besides the DOM: a leak has none), and a row that comes back is rendered again,
# still expanded, with no dead diff left even after a fast scroll.
@testitem "e2e:editor_dispose" setup = [SharedServer] tags = [:e2e] begin
    S = SharedServer
    s = S.server()
    TK = S.TK
    ECT = TK.ECT

    long = join(("    x$(j) = compute($(j))" for j in 1:40), "\n")
    env = abspath(joinpath(@__DIR__, "..", "evalenv"))
    s.agent_fn[] = function (_)
        # Two eval cards (a plain editor each) and a long edit at the top.
        evs = Any[TK.bt_eval("a = $(i)"; env_path = env, id = "ed-eval-$(i)") for i in 1:2]
        push!(evs, TK.edit("/p/long.jl", long, replace(long, "x20 = compute(20)" => "x20 = fast(20)"); id = "ed-long"))
        for i in 1:30
            push!(evs, TK.text("after edit $(i): " * "lorem ipsum dolor sit amet "^8))
            push!(evs, TK.edit("/p/f$(i).jl", "a = $(i)\nb = 2", "a = $(i)\nb = 3"; id = "ed-$(i)"))
        end
        push!(evs, TK.end_turn())
        return evs
    end
    TK.new_chat(s; title = "EditorDispose")
    TK.send_message(s, "edits")

    VP = "[...document.querySelectorAll('.bt-chatpane')].find(p => p.offsetParent !== null)"
    chat = "$VP.querySelector('.bt-messages')"
    card(id) = "$VP.querySelector('.bt-tool-msg[data-msg-id*=\"$(id)\"]')"
    diff(id) = "$(card(id))?.querySelector('.monaco-diff-editor-div')"
    @test TK.wait_for(s, "the agent done", "!document.querySelector('.bt-busy.bt-busy-active')"; timeout = 240) == true
    @test TK.wait_for(s, "the last diff mounted", "!!$(card("ed-30"))?.querySelector('.monaco-diff-editor .view-line')"; timeout = 60) == true

    ctx = s.browser[]
    ECT.install_cursor(ctx)
    gutter = ECT.JS("(() => { const r = $(chat).getBoundingClientRect(); return [r.left + 3, r.top + r.height / 2]; })()")
    wheel_to(sel) = TK.wheel_into_view(s, chat, sel; step = 400)
    at_bottom() = TK.eval_js(s, "(() => { const c = $(chat); return c.scrollHeight - c.clientHeight - c.scrollTop < 2; })()")

    # Monaco's own registry, through the module BonitoBook imported (the same
    # URL is the same module instance).
    TK.eval_js(s, """(async () => {
        const u = performance.getEntriesByType('resource').map(e => e.name)
            .find(n => /monaco-editor@[^/]+\\/\\+esm\$/.test(n));
        window.__ed_monaco = await import(u);
        return true; })()""")
    # A diff's gutter is the one `.monaco-editor` that is no code editor.
    only_on_page = """(() => { const m = window.__ed_monaco.editor;
        return m.getDiffEditors().length === document.querySelectorAll('.monaco-diff-editor').length &&
               m.getEditors().length === document.querySelectorAll('.monaco-editor:not(.gutter)').length; })()"""

    # Up to the long edit and expand it.
    @test wheel_to(card("ed-long"))
    TK.click(s, ".bt-tool-msg[data-msg-id*=\"ed-long\"] .bt-tool-header")
    expanded() = TK.eval_js(s, "Math.round($(diff("ed-long"))?.getBoundingClientRect().height || 0)")
    @test TK.wait_for(s, "the long edit expanded", "($(diff("ed-long"))?.getBoundingClientRect().height || 0) > 500"; timeout = 20) == true
    h = expanded()

    # Far away, to the bottom: the long edit leaves the page, and its editor
    # with it.
    ECT.move_to(ctx, gutter; duration = 0.05)
    for _ in 1:120
        at_bottom() && break
        ECT.wheel(ctx, 800; steps = 2)
        sleep(0.1)
    end
    @test at_bottom()
    @test TK.eval_js(s, "!$(card("ed-long"))") == true
    @test TK.wait_for(s, "only the diffs on the page alive", only_on_page; timeout = 30) == true

    # Back: rendered again, expanded as it was.
    @test wheel_to(card("ed-long"))
    @test TK.wait_for(s, "the long edit rendered again",
        "[...($(card("ed-long"))?.querySelectorAll('.modified-in-monaco-diff-editor .view-line') || [])].some(l => l.textContent.includes('fast(20)'))"; timeout = 30) == true
    @test TK.wait_for(s, "still expanded", "Math.abs(($(diff("ed-long"))?.getBoundingClientRect().height || 0) - $(h)) < 2"; timeout = 20) == true
    @test TK.eval_js(s, "$(card("ed-long")).querySelector('.bt-tool-header').dataset.expanded") == "true"
    @test TK.wait_for(s, "still only the diffs on the page alive", only_on_page; timeout = 30) == true
    # No dead diff left on the page: the fast scroll took rows away before
    # their body arrived, and Bonito freed those bodies right away.
    @test TK.wait_for(s, "every diff on the page live", """[...$(VP).querySelectorAll('.bt-tool-body .monaco-diff-editor-div')]
        .every(d => d.__btMonacoDiff && !d.__btMonacoDiff.disposed && d.querySelector('.monaco-diff-editor'))"""; timeout = 30) == true

    @test isempty(TK.js_errors(s))
    s.agent_fn[] = S.default_agent
end
