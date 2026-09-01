# The searchable model picker — the header dropdown used when a ConfigOption has
# more choices than `MODEL_SEARCH_THRESHOLD` (8), e.g. OpenCode's ~100 models.
#
# It had NO coverage at all, which is why its three handlers could sit on
# `window.*` unnoticed. This pins the behaviour so moving them into the module
# (`$(ChatLib).then(lib => lib.msearch…)`, the pattern `toolSlot` already uses)
# is provably behaviour-preserving rather than a hopeful refactor of untested UI.
#
# Asserted purely on the rendered DOM: open, filter, select.
@testitem "e2e:model_search" tags = [:e2e] begin
    include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
    using .TestKit
    const TK = TestKit
    using Test

    agent_script(_p) = [TK.text("ok"), TK.end_turn()]

    # `many_choices` makes MockACP advertise a 12-choice `model` option, which is
    # what pushes the header past the searchable-dropdown threshold.
    server = TK.dev_server(agent = agent_script, name = "msearch-w", many_choices = true)
    try
        TK.open_browser(server)
        TK.new_chat(server; cwd = mktempdir(), title = "ModelSearch")

        # Visible (non-`hidden`) rows in the dropdown — what filtering changes.
        shown_js = """(() => [...document.querySelectorAll('.bt-msearch-item')]
            .filter(e => !e.hidden).map(e => e.textContent.trim()))()"""
        open_js = "!!document.querySelector('.bt-msearch.bt-msearch-open')"

        @testset "many choices render the searchable picker" begin
            @test TK.wait_for(server, "msearch picker present",
                "!!document.querySelector('.bt-msearch-trigger')"; timeout = 60) == true
            # 12 choices, all present before any filtering.
            @test TK.wait_for(server, "all 12 choices rendered",
                "document.querySelectorAll('.bt-msearch-item').length === 12"; timeout = 30) == true
            @test TK.eval_js(server, open_js) == false   # closed until clicked
        end

        @testset "clicking the trigger opens it" begin
            TK.click(server, ".bt-msearch-trigger")
            @test TK.wait_for(server, "dropdown open", open_js; timeout = 10) == true
            @test length(TK.eval_js(server, shown_js)) == 12
        end

        @testset "typing filters the list" begin
            TK.set_input(server, ".bt-msearch-input", "gamma")
            @test TK.wait_for(server, "filtered to the gamma rows",
                "$(shown_js).length === 3"; timeout = 10) == true
            @test all(occursin("Gamma", String(s)) for s in TK.eval_js(server, shown_js))

            # Narrower still, then cleared — filtering is live, not one-shot.
            TK.set_input(server, ".bt-msearch-input", "gamma two")
            @test TK.wait_for(server, "filtered to one row",
                "$(shown_js).length === 1"; timeout = 10) == true
            TK.set_input(server, ".bt-msearch-input", "")
            @test TK.wait_for(server, "cleared back to all 12",
                "$(shown_js).length === 12"; timeout = 10) == true
        end

        @testset "picking a choice closes it and updates the pill" begin
            TK.set_input(server, ".bt-msearch-input", "delta two")
            @test TK.wait_for(server, "delta two isolated",
                "$(shown_js).length === 1"; timeout = 10) == true
            TK.eval_js(server, """(() => {
                const el = [...document.querySelectorAll('.bt-msearch-item')].find(e => !e.hidden);
                if (el) el.click(); return !!el; })()""")
            @test TK.wait_for(server, "dropdown closed after pick",
                "!$(open_js)"; timeout = 10) == true
            # The selection round-trips through Julia and comes back as the
            # trigger's label — the part that needs the Observable, and the
            # reason `select` can't be pure DOM.
            @test TK.wait_for(server, "pill shows the picked model",
                """(document.querySelector('.bt-msearch-trigger')?.textContent || '')
                     .includes('Delta Two')"""; timeout = 30) == true
        end

        @test isempty(TK.js_errors(server))
    finally
        close(server)
    end
end
