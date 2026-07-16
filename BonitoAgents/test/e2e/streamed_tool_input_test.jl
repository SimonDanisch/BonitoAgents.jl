# Black-box port of the legacy electron test_streamed_tool_input.jl onto the
# shared-soak dev_server. Real claude-agent-acp STREAMS tool input: a tool's
# arguments (`rawInput`) usually arrive on a `tool_call_update` AFTER the
# initial `tool_call`. The DOM must grow the late affordances:
#
#   • bt_julia_eval: the compact Monaco body eager-mount, the ⏱ timeout
#     badge (.bt-tool-timeout) and the ⊗ stop button (.bt-tool-stop) appear on
#     the in-flight UPDATE (the opening header carried an EMPTY rawInput), the
#     pill stays live (.bt-tool-live) while it runs, and the preview is removed
#     again on completion.
#   • Read: the ✎ edit affordance — the title turns into a .bt-path-link
#     carrying the REAL worker-side file_path from rawInput — appears once that
#     file_path streams in (the display title "Read hello.jl" is NOT a path).
#
# The streaming itself rides the TestKit DSL: `tool(...; complete=false)` opens
# the bubble with no/partial rawInput, then `tool_update(id; raw_input=...)`
# merges the arguments into the live MCPCall/GenericTool — the exact wire shape
# the chat's `update_from_snap!` + ACP `merge_late_input!` consume.
@testitem "e2e:streamed_tool_input" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TK
    s = SharedServer.server()

    # Real file under the chat's project tree so the Read path resolves to an
    # actual worker-side path (mirrors the legacy fixture's hello.jl).
    cwd = mktempdir()
    write(joinpath(cwd, "hello.jl"), "greet() = println(\"hi\")\n")
    fpath = joinpath(cwd, "hello.jl")

    const EVALNAME = "mcp__btworker__bt_julia_eval"

    # The scripted turn. Everything is held open with `delay`s so the in-flight
    # affordances are observable mid-stream; the eval is finally completed so
    # the "preview removed on completion" assertion has a terminal transition.
    s.agent_fn[] = function (_prompt)
        return [
            # ── eval: announce with EMPTY rawInput, then stream the args while
            #    running (compact body + ⏱ + ⊗ must appear on THIS update),
            #    hold it live, then complete (preview must be removed). ──
            TK.tool(kind = "other", title = EVALNAME, tool_name = EVALNAME,
                    id = "ev1", open_status = "pending", complete = false,
                    raw_input = Dict{String,Any}()),
            TK.tool_update("ev1"; status = "in_progress",
                           raw_input = Dict{String,Any}(
                               "code" => "sleep(2); 40 + 2", "timeout" => 60,
                               "env_path" => "/tmp/p")),

            # ── read: announce as a DISPLAY-title tool (no path), then stream
            #    the real file_path so the title becomes a ✎ path link. ──
            TK.tool(kind = "read", title = "Read File", tool_name = "Read",
                    id = "rd1", open_status = "pending", complete = false,
                    raw_input = Dict{String,Any}()),
            TK.tool_update("rd1";
                           raw_input = Dict{String,Any}("file_path" => fpath)),

            # Hold the turn open generously so all the in-flight affordances
            # (live preview, ⏱, ⊗, the live pill, the streamed path link) are
            # observable while we assert — `send_message` + the first DOM polls
            # take seconds to round-trip, so a short hold would race completion.
            # The third @testset then completes both tools and observes the
            # live preview being torn down on the terminal transition.
            TK.delay(12000),
            TK.tool_update("rd1"; status = "completed",
                           content = [TK.text_block("greet() = println(\"hi\")\n")]),
            # Wire contract v3: the eval's content is plain output text (the
            # result repr echoed REPL-style) — no code echo, no labels.
            TK.tool_update("ev1"; status = "completed",
                           content = [TK.text_block("42")]),
        ]
    end

    TK.new_chat(s; cwd = cwd, title = "Streamed")
    TK.send_message(s, "go")

    body(id)      = "document.querySelector('.bt-tool-body[data-tool-id=\"$(id)\"]')"
    # The .bt-tool-msg card that owns the body for `id` (the pill node).
    card(id)      = "[...document.querySelectorAll('.bt-tool-msg')].find(m => m.querySelector('.bt-tool-body[data-tool-id=\"$(id)\"]'))"

    @testset "bt_julia_eval: compact body + ⏱ + ⊗ stream in on the args update" begin
        # The eval pill arrives (the tool title carries the bare tool name).
        @test TK.wait_for(s, "eval pill arrives",
            "[...document.querySelectorAll('.bt-tool-title')].some(t => (t.innerText||'').indexOf('bt_julia_eval') !== -1)";
            timeout = 30) == true

        # The args update eager-mounts the body WHILE running — the "preview"
        # is the real Monaco Code editor (a LONG Code section clamps itself;
        # see the section-clamp contract in test_bt_eval_e2e.jl) — and flips
        # the header to expanded so the arrow matches the visible body.
        @test TK.wait_for(s, "Monaco body mounts + shows on the args update",
            "(() => { const n = $(card("ev1")); " *
            "const b = n && n.querySelector('.bt-eval-body'); " *
            "return !!b && (b.innerText || '').indexOf('sleep(2)') !== -1 && " *
            "n.querySelector('.bt-tool-header')?.dataset.expanded === 'true'; })()";
            timeout = 15) == true

        # The ⏱ timeout badge inserted late (60s from rawInput.timeout).
        @test TK.wait_for(s, "⏱ badge inserted late",
            "(() => { const b = document.querySelector('.bt-tool-timeout'); " *
            "return b && b.innerText.indexOf('60') !== -1; })()";
            timeout = 10) == true

        # The ⊗ stop button inserted late (bt_julia_eval is EVAL_STOPPABLE).
        @test TK.wait_for(s, "⊗ stop button inserted late",
            "!!document.querySelector('.bt-tool-stop')"; timeout = 10) == true

        # The pill is still live (pulsing/taskbar gate) while the preview shows.
        @test TK.wait_for(s, "pill still live while preview shows",
            "(() => { const n = $(card("ev1")); " *
            "return !!n && n.classList.contains('bt-tool-live'); })()";
            timeout = 10) == true
    end

    @testset "Read: ✎ edit button — title becomes a path link via late rawInput" begin
        # The title turns into a .bt-path-link carrying the REAL file_path
        # (from the streamed rawInput), NOT the display title.
        @test TK.wait_for(s, "title turns into a path link carrying the real path",
            "(() => { const n = $(card("rd1")); " *
            "const t = n && n.querySelector('.bt-tool-title.bt-path-link'); " *
            "return !!t && t.dataset.path === $(TK.json(fpath)); })()";
            timeout = 15) == true

        # Clicking the path link must NOT expand the pill (it opens the editor
        # instead — covered by file_open_test; here we only assert it's inert
        # against the collapsible).
        TK.eval_js(s, "(() => { const n = $(card("rd1")); " *
            "const t = n && n.querySelector('.bt-tool-title.bt-path-link'); " *
            "if (t) t.click(); return true; })()")
        @test TK.wait_for(s, "path-link click does not expand the pill",
            "(() => { const n = $(card("rd1")); " *
            "const h = n && n.querySelector('.bt-tool-header'); " *
            "return !!h && h.dataset.expanded === 'false'; })()";
            timeout = 10) == true
    end

    @testset "streamed rawInput resolves: eval completes with the result visible" begin
        # On completion: the stream pane is gone and the output is visible
        # WITHOUT any click — the body stays shown from the eager mount
        # (scripted content carries no result descriptor, so there's no
        # `expand_full`; real evals get that from the descriptor block).
        @test TK.wait_for(s, "completed + auto-expanded, no stream pane",
            "(() => { const n = $(card("ev1")); " *
            "const st = n && n.querySelector('.bt-tool-status'); " *
            "return !!st && st.textContent === 'completed' && " *
            "n.querySelector('.bt-eval-stream') === null && " *
            "n.querySelector('.bt-tool-header')?.dataset.expanded === 'true'; })()";
            timeout = 20) == true
        @test TK.wait_for(s, "eval result rendered in body",
            "(($(body("ev1")) || {}).textContent || '').indexOf('42') !== -1";
            timeout = 15) == true
    end

    @test isempty(TK.js_errors(s))
end
