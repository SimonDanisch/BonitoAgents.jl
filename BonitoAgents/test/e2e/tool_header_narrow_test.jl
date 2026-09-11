# The tool row has to stay readable when the message column is phone-narrow.
#
# The bug this pins, reported from a phone as "you can't see how long a tool
# ran, since it's outside the window": `.bt-tool-summary` was `flex-shrink: 0`
# with `nowrap`, so it could not give up a pixel. The title shrank away to a
# single character and then the summary pushed the elapsed timer and the status
# pill clean OUT of the card. Measured on a 392px viewport, header 70→382: a
# 20-character summary overflowed the header by 52px and put the status at
# 335→407; at 80 characters, 700→772. The duration was being rendered the whole
# time — just off-screen.
#
# What the row owes the user, in order: which tool, how long, how it ended. The
# summary is the part that yields.
#
# ISOLATED (its own dev_server + browser): it resizes the window, which every
# other item on the shared runner would inherit.
@testitem "e2e:tool_header_narrow" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    const ECT = TK.ECT   # ElectronCall.Testing — real window resizing

    LONG_TITLE = "Bash(cd /sim/Programmieren/AgentsDev && julia --project=. -e 'using Pkg; Pkg.test()')"

    # Everything about the one tool row, measured off the rendered DOM.
    MEASURE = """(() => {
        const h = document.querySelector('.bt-tool-header');
        if (!h) return null;
        const hr = h.getBoundingClientRect();
        const box = s => { const e = h.querySelector(s);
            if (!e) return null;
            const st = getComputedStyle(e);
            if (st.display === 'none') return 'hidden';
            const r = e.getBoundingClientRect();
            return {l: r.left, r: r.right, txt: (e.textContent || '').trim()}; };
        const sum = h.querySelector('.bt-tool-summary');
        return {overflow: h.scrollWidth - h.clientWidth,
                header: {l: hr.left, r: hr.right},
                timer: box('.bt-tool-timer'), status: box('.bt-tool-status'),
                summary: box('.bt-tool-summary'),
                summaryShrink: sum ? getComputedStyle(sum).flexShrink : null,
                title: box('.bt-tool-title')}; })()"""

    # `inside` is the whole contract: rendered, and within the card.
    inside(m, part) = m[part] isa AbstractDict &&
        m[part]["l"] >= m["header"]["l"] - 0.5 &&
        m[part]["r"] <= m["header"]["r"] + 0.5

    server = TK.dev_server(agent = _ -> [
        TK.tool(; kind = "execute", title = LONG_TITLE, id = "t1", complete = false),
        # Past the 1s floor under which the timer deliberately renders nothing,
        # so there is a duration to look for at all.
        TK.delay(2200),
        TK.tool_update("t1"; status = "completed",
                       content = Any[TK.text_block("line one\nline two\nline three")]),
        TK.end_turn()])
    try
        # Build the chat at a normal width, then RESIZE — `open_browser` would
        # reload the window back to the dashboard and there would be no tool row
        # to measure. `set_window_size` drives Chromium's device emulation, so
        # the chat pane stays mounted across the change, which is also what a
        # phone rotating actually does.
        TK.open_browser(server)
        ctx = server.browser[]
        TK.new_chat(server; cwd = mktempdir(), title = "narrowtool")
        TK.send_message(server, "run it")
        @test TK.wait_for(server, "the tool finished",
            "(document.querySelector('.bt-tool-status')||{}).textContent === 'completed'";
            timeout = 60) == true
        @test TK.wait_for(server, "the elapsed time rendered",
            "((document.querySelector('.bt-tool-timer')||{}).textContent||'').trim() !== ''";
            timeout = 20) == true

        @testset "desktop width: the summary is shown, nothing overflows" begin
            m = TK.eval_js(server, MEASURE)
            @test m !== nothing
            @test m["summary"] isa AbstractDict      # room for it here
            @test m["overflow"] <= 0
            @test inside(m, "timer")
            @test inside(m, "status")
        end

        ECT.set_window_size(ctx, 390, 844)           # iPhone-class viewport
        @test TK.wait_for(server, "the narrow layout settled",
            "window.innerWidth < 500"; timeout = 20) == true
        sleep(0.5)

        @testset "phone width: the duration and the status stay on screen" begin
            m = TK.eval_js(server, MEASURE)
            @test m !== nothing
            # The whole complaint, as one assertion each.
            @test inside(m, "timer")
            @test inside(m, "status")
            @test m["status"]["txt"] == "completed"
            @test !isempty(m["timer"]["txt"])
            # Nothing escapes the card at all.
            @test m["overflow"] <= 0
            # The title identifies the call; ellipsized to "B" it identifies
            # nothing. (It IS still truncated — that is fine and expected.)
            @test length(m["title"]["txt"]) > 3
            # At this width the summary is the thing that gives way.
            @test m["summary"] == "hidden"
        end

        @testset "phone width: a long summary cannot push them off" begin
            # Perturbing the RENDERED node to test the layout contract — the
            # card itself came through the real chat above. A summary long
            # enough to overflow is what the old CSS could not survive, and no
            # mock tool produces one.
            TK.eval_js(server, """(() => {
                const s = document.querySelector('.bt-tool-summary');
                s.style.display = 'inline';          // defeat the container query
                s.textContent = 'exit 0 · ' + 'x'.repeat(120);
                return true; })()""")
            sleep(0.4)
            m = TK.eval_js(server, MEASURE)
            @test m["overflow"] <= 0
            @test inside(m, "timer")
            @test inside(m, "status")
            # …because the summary is allowed to yield. `flex-shrink: 0` here
            # is the regression, and it is silent until a summary gets long.
            @test m["summaryShrink"] != "0"
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
