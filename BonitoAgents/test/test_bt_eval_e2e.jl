# End-to-end test for `bt_julia_eval` via the TestKit dispatcher.
#
# This is "as realistic as it gets" without writing an MCP client into the
# mock agent binary: the test process spawns a real `dev_server` (real
# worker, real WorkerTransport, real ACP wire), wires in the mock-agent
# binary as `agent_bin`, then for any `bt_eval(code; env_path)` event the
# dispatcher invokes the actual `BonitoMCP.julia_eval_handler` — same Malt
# worker pool, same `--project=<env_path>` activation, same result
# formatter. The result content blocks ride back as ACP `tool_call`
# frames; the chat renders them through its standard `bt_julia_eval`
# path (the one that produces collapsible Code/Output sub-sections).
#
# The "tmp env with the correct package versions" goal lands here too:
# each test creates its own `mktempdir()` Project and asserts that
# `bt_eval` ran INSIDE that project, not in the test process's session.

using Test, JSON
using Bonito           # test dep — used to locate the RESOLVED v5 Bonito source
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit
const TK = TestKit
using .TestKit: text, bt_eval, bt_continue, end_turn

const SHOT_DIR = joinpath(tempdir(), "bt-eval-e2e")
mkpath(SHOT_DIR)
shot(name) = joinpath(SHOT_DIR, name)

# The committed eval test env (dev Bonito via [sources]) — REQUIRED for any
# testset asserting the LIVE result embed: a fresh empty project resolves a
# pre-v5 Bonito, the bridge gate skips setup, and contract v3 then has no
# descriptor — the result is the REPL-style echo in Output instead.
const EVALENV = abspath(joinpath(@__DIR__, "evalenv"))

# Create a tmp project directory with a fresh, empty Project.toml. No
# package deps → no Pkg.instantiate needed → fast. The `Base.active_project()`
# probe below proves bt_eval is honoring the env_path.
function fresh_project(name::AbstractString)
    d = mktempdir(; prefix = "bt-eval-env-$(name)-")
    open(joinpath(d, "Project.toml"), "w") do io
        write(io, """
        name = "$(name)"
        uuid = "$(string(Base.UUID(rand(UInt128))))"
        version = "0.0.1"

        [deps]
        """)
    end
    return d
end

# ── Tool-message DOM probe ─────────────────────────────────────────────────
# After bt_eval lands, the chat renders a `bt_julia_eval` tool message
# with two collapsible sub-sections (Code + Output). Probe asserts the
# right text shows up and the tool is in the "completed" state.
function probe(s)
    return TK.eval_js(s, """(() => {
        const tool = document.querySelector('.bt-tool-msg');
        if (!tool) return {error: 'no tool message'};
        const header = tool.querySelector('.bt-tool-header');
        const status = tool.querySelector('.bt-tool-status');
        // Body might be lazy-mounted; trigger expansion if not loaded yet.
        const body = tool.querySelector('.bt-tool-body');
        return {
            tool_count: document.querySelectorAll('.bt-tool-msg').length,
            tool_title: tool.querySelector('.bt-tool-title') ?
                         tool.querySelector('.bt-tool-title').textContent : null,
            status: status ? status.textContent : null,
            header_expanded: header.dataset.expanded || 'false',
            body_innerText_len: body ? body.innerText.length : 0,
            body_text_snippet: body ? body.innerText.slice(0, 300) : null,
        };
    })()""")
end

@testset "bt_eval e2e — runs a simple expression and renders the result" begin
    project = fresh_project("simple")
    @info "project env" project

    s = TK.dev_server(; agent = msg -> [
        text("I'll evaluate that for you."),
        bt_eval("1 + 41"; env_path = project, id = "te-1"),
        text("That's the answer."),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        TK.send_message(s, "what is the answer to life?")

        # Wait until the bt_julia_eval tool lands.
        TK.wait_for(s, "bt_julia_eval tool mounted",
                    """document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent === 'completed'""";
                    timeout = 60)
        sleep(1.0)

        # Expand the tool body so the Code/Output collapsibles render.
        TK.click(s, ".bt-tool-msg .bt-tool-header")
        sleep(1.5)

        snap = probe(s)
        @info "DOM after bt_eval" snap
        @test snap["tool_count"] >= 1
        @test snap["status"] == "completed"
        # `42` MUST appear in the rendered body — that's the literal output
        # of `1 + 41` formatted by BonitoMCP's content blocks.
        @test occursin("42", snap["body_text_snippet"])

        TK.screenshot(s, shot("bt_eval-simple.png"))
    finally
        close(s)
    end
end

# REPL semantics: the worker evals the code STRING per-top-level-statement
# (`repl_eval` → `include_string` with soft scope), NOT as one spliced
# expression. Two things that broke under the old splice-as-argument path:
#   (1) soft scope — a top-level `for` may assign to a global (`acc += i`);
#       under hard scope it errored "acc not defined in local scope".
#   (2) world age — a `function` def then a call to it in the SAME eval no
#       longer warns "access to binding … in a world prior to its definition"
#       (Julia ≥ 1.12); the def advances the world before the call runs.
@testset "bt_eval e2e — REPL semantics: soft-scope loops + world-age-clean defs" begin
    project = EVALENV   # result embed asserted → needs the bridge (see EVALENV)
    softscope_code = "acc = 0\nfor i in 1:5\n    acc += i\nend\nacc"
    worldage_code  = "double(x) = 2x\ndouble(21)"
    s = TK.dev_server(; agent = msg ->
        occursin("loop", msg) ?
            [text("summing"), bt_eval(softscope_code; env_path = project, id = "ss-1"), end_turn()] :
            [text("defining"), bt_eval(worldage_code; env_path = project, id = "wa-1"), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)

        # (1) Soft-scope accumulator: completes without error and the result
        # embed shows 15 (a hard-scope failure would set errored + show the
        # "not defined in local scope" text instead).
        TK.send_message(s, "run the loop")
        card1 = ".bt-tool-msg[data-msg-id*=\"ss-1\"]"
        @test TK.wait_for(s, "soft-scope loop completed with result 15",
            """(() => { const c = document.querySelector('$card1');
                if (!c || c.querySelector('.bt-tool-status')?.textContent !== 'completed') return false;
                return (c.querySelector('.bt-embed')?.innerText || '').includes('15'); })()""";
            timeout = 90) == true
        # No error, no soft-scope diagnostic anywhere in the card.
        @test TK.eval_js(s, """(() => { const c = document.querySelector('$card1');
            const t = c.innerText || '';
            return !/local scope|UndefVarError/.test(t); })()""") == true

        # (2) Define-then-call in one eval: result 42, and NO world-age warning
        # leaked into the Output (there should be no Output section at all —
        # nothing was printed).
        TK.send_message(s, "define and call")
        card2 = ".bt-tool-msg[data-msg-id*=\"wa-1\"]"
        @test TK.wait_for(s, "world-age-clean def completed with result 42",
            """(() => { const c = document.querySelector('$card2');
                if (!c || c.querySelector('.bt-tool-status')?.textContent !== 'completed') return false;
                return (c.querySelector('.bt-embed')?.innerText || '').includes('42'); })()""";
            timeout = 60) == true
        @test TK.eval_js(s, """(() => { const c = document.querySelector('$card2');
            const t = c.innerText || '';
            return !/world|prior to its definition/i.test(t); })()""") == true
        # Nothing printed → no Output section.
        @test TK.eval_js(s, """[...document.querySelector('$card2').querySelectorAll('.bt-subsection-label')]
            .every(l => (l.textContent||'').trim() !== 'Output')""") == true
    finally
        close(s)
    end
end

# The live-display contract for a RUNNING eval: (1) the body eager-mounts
# without any click while the code runs (real wire: the status stays PENDING
# for the whole MCP call — no in_progress ever arrives) and a LONG Code
# section starts in SUMMARY state — a ~4-line window onto the editor, capped
# by the Collapsable body (which owns the scrollbar). The cap lives on the
# SECTION, never on the tool card, so Output and the result embed below it are
# always reachable; (2) stdout streams into the Output section's `pin_end`
# console, pinned to the newest line — the SAME widget the completed output
# uses (no styling jump); (3) a completed eval that RETURNED a value shows the
# result without a click, and the Output header cycles the three states
# summary → collapsed → full → summary.
@testset "bt_eval e2e — live display: three-state sections, stdout stream tail, result visible" begin
    project = EVALENV   # live embed asserted → needs the bridge (see EVALENV)
    # 9 code lines (> CLAMP_LINES) so the Code section clamps while running;
    # 12 output lines so the Output section clamps after completion.
    code = """
    # streaming demo: prints twelve lines, slowly,
    # with enough code lines that the Code section
    # itself exceeds the section clamp threshold.
    acc = 0
    for i in 1:12
        println("STREAMLINE ", i)
        global acc += i
        sleep(1.0)
    end
    1234321
    """
    s = TK.dev_server(; agent = msg -> [
        text("streaming eval"),
        bt_eval(code; env_path = project, id = "ts-1"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 900)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        # Fresh evalenv session: the pool is process-global, so a session left by
        # an earlier testset still dials ITS (closed) dev_server — the mount
        # would degrade to the static fallback. Each dev_server = a fresh boot.
        TK.send_message(s, "stream please")
        card = ".bt-tool-msg[data-msg-id*=\"ts-1\"]"

        # (1) While running (status stays "pending" on the real wire): the
        # body is MOUNTED and VISIBLE without any click, and the header reads
        # expanded so the arrow matches the shown body.
        @test TK.wait_for(s, "body mounted + visible while running",
            """(() => { const c = document.querySelector('$card');
                return !!(c && c.querySelector('.bt-eval-body') &&
                    c.querySelector('.bt-tool-status')?.textContent === 'pending' &&
                    c.querySelector('.bt-tool-header')?.dataset.expanded === 'true'); })()""";
            timeout = 120) == true
        # The header clock TICKS while it runs — with the status parked at
        # "pending" for the whole MCP call, elapsed time is the user's only
        # hang-vs-slow signal. Two distinct values observed while still live
        # prove it advances (recomputed from started_at, 1Hz shared ticker).
        @test TK.wait_for(s, "elapsed clock ticks while running",
            """(() => { const c = document.querySelector('$card');
                const t = c && c.querySelector('.bt-tool-timer');
                if (!t || !t.textContent) return false;
                if (c.querySelector('.bt-tool-status')?.textContent !== 'pending') return false;
                window.__clk1 ??= t.textContent;
                return t.textContent !== window.__clk1; })()""";
            timeout = 30, interval = 0.5) == true
        # The Code SECTION starts in SUMMARY state — a ~4-line window onto the
        # editor, capped by the Collapsable body (which owns the scrollbar),
        # with real Monaco lines rendered. The card body itself is NOT capped.
        code_sec = """[...document.querySelectorAll('$card .bt-subsection')].find(d =>
            d.querySelector('.bt-subsection-label')?.textContent === 'Code')"""
        @test TK.wait_for(s, "Code section in summary state, ~4 lines",
            """(() => { const d = $code_sec;
                const b = d && d.querySelector('.bt-subsection-body');
                return !!(d && b && d.dataset.state === 'summary' &&
                       b.querySelectorAll('.view-line').length >= 3 &&
                       b.offsetHeight > 0 && b.offsetHeight <= 110); })()""";
            timeout = 30) == true

        # (2) The stdout streams into the Output section's console, pinned to
        # the newest line — the SAME `pin_end` Collapsable body the completed
        # output uses (no styling jump). ONE combined wait with a boot-tolerant
        # timeout: the fresh evalenv session pays worker spawn + `using` before
        # the first print.
        out_sec = """[...document.querySelectorAll('$card .bt-subsection')].find(d =>
            d.querySelector('.bt-subsection-label')?.textContent === 'Output')"""
        stream_ok = try
            TK.wait_for(s, "stream tail streams late lines, pinned to end",
                """(() => { const d = $out_sec;
                    const con = d && d.querySelector('.bt-console');
                    const sc  = d && d.querySelector('.bt-subsection-body');
                    return !!(con && sc && /STREAMLINE (8|9|10|11|12)/.test(con.textContent) &&
                              d.dataset.pinEnd === '1' &&
                              sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 4); })()""";
                timeout = 180) == true
        catch
            false
        end
        stream_ok || @info "stream dump" pane = TK.eval_js(s,
                """(() => { const d = $out_sec; const con = d && d.querySelector('.bt-console');
                    const sc = d && d.querySelector('.bt-subsection-body');
                    return con ? JSON.stringify({txt: con.textContent.slice(-200),
                        st: sc?.scrollTop, ch: sc?.clientHeight, sh: sc?.scrollHeight}) : "(no console)"; })()""") body = TK.eval_js(s,
                "document.querySelector('$card .bt-tool-body')?.innerText?.slice(0, 300)")
        @test stream_ok

        # (3) Completion with a non-nothing result: the result embed is
        # visible (below the summary-state sections — no click needed), and no
        # fallback stream pane lingers.
        @test TK.wait_for(s, "completed + result visible",
            """(() => { const c = document.querySelector('$card');
                if (!c) return false;
                const done = c.querySelector('.bt-tool-status')?.textContent === 'completed';
                const open = c.querySelector('.bt-tool-header')?.dataset.expanded === 'true';
                const res  = c.querySelector('.bt-embed')?.innerText.includes('1234321');
                return !!(done && open && res); })()"""; timeout = 60) == true
        @test TK.eval_js(s, "!document.querySelector('$card .bt-eval-stream')") == true
        # The clock FREEZES at the final duration on completion.
        clk1 = TK.eval_js(s, "document.querySelector('$card .bt-tool-timer').textContent")
        sleep(1.6)
        clk2 = TK.eval_js(s, "document.querySelector('$card .bt-tool-timer').textContent")
        @test occursin(r"^\d+(s|m(\d+s)?)$", clk1)
        @test clk1 == clk2

        # (4) The completed Output section is the SAME pin_end console in
        # SUMMARY state — scrollbar, capped to ~4 lines. Clicking its HEADER
        # cycles the three states: summary → collapsed → full → summary. Each
        # state has its OWN distinct disclosure marker (▸ collapsed, ▿ summary,
        # ▾ full) so all three are visually distinguishable.
        marker = () -> TK.eval_js(s,
            "getComputedStyle(($out_sec).querySelector('.bt-subsection-summary'), '::before').content")
        @test TK.wait_for(s, "Output section done: summary state, pinned console",
            """(() => { const d = $out_sec;
                const b = d && d.querySelector('.bt-subsection-body');
                return !!(d && b && d.dataset.state === 'summary' && d.dataset.pinEnd === '1' &&
                          d.hasAttribute('open') && b.offsetHeight <= 110); })()""";
            timeout = 30) == true
        @test occursin("▿", marker())          # summary marker
        # Cycle 1: summary → collapsed (header click; body hidden).
        TK.eval_js(s, "($out_sec).querySelector('.bt-subsection-summary').click(); true")
        @test TK.wait_for(s, "cycled to collapsed",
            "!(($out_sec).hasAttribute('open'))"; timeout = 5) == true
        @test occursin("▸", marker())          # collapsed marker (distinct)
        # Cycle 2: collapsed → full (body back, taller than the summary cap).
        TK.eval_js(s, "($out_sec).querySelector('.bt-subsection-summary').click(); true")
        @test TK.wait_for(s, "cycled to full (uncapped)",
            """(() => { const d = $out_sec;
                return !!(d.hasAttribute('open') && d.dataset.state === 'full' &&
                    d.querySelector('.bt-subsection-body').offsetHeight > 110); })()""";
            timeout = 5) == true
        @test occursin("▾", marker())          # full marker (distinct from the other two)
        # Cycle 3: full → summary (back to the ~4-line window).
        TK.eval_js(s, "($out_sec).querySelector('.bt-subsection-summary').click(); true")
        @test TK.wait_for(s, "cycled back to summary",
            """(() => { const d = $out_sec;
                return !!(d.hasAttribute('open') && d.dataset.state === 'summary' &&
                    d.querySelector('.bt-subsection-body').offsetHeight <= 110); })()""";
            timeout = 5) == true

        TK.screenshot(s, shot("bt_eval-stream.png"))
    finally
        close(s)
    end
end

# An ERRORING eval must SHOW its error. Contract v3: a user error is a
# VALUE — the worker parks the `CapturedException` like any result (the
# descriptor carries `errored: true`) and prints the red `ERROR: …` text
# into the output, REPL-style. MCP `isError` stays FALSE (it's reserved for
# infra failures — claude fuses isError content into one rawOutput blob), so
# the tool status is `completed` and nothing ever fuses. The chat shows the
# error twice over: terminal text in Output, live-rendered exception
# (Bonito's `jsrender(::CapturedException)`) as the result embed.
@testset "bt_eval e2e — erroring eval renders ERROR output + live exception result" begin
    project = EVALENV   # live exception embed asserted → needs the bridge
    s = TK.dev_server(; agent = msg -> [
        text("this will fail"),
        bt_eval("values = [4.0, 9.0, -16.0, 25.0]\nmap(sqrt, values)";
                env_path = project, id = "terr-1"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        TK.send_message(s, "fail please")
        card = ".bt-tool-msg[data-msg-id*=\"terr-1\"]"

        # User error ≠ failed tool: the MCP call completed (isError is infra-only).
        @test TK.wait_for(s, "eval completed",
            "document.querySelector('$card .bt-tool-status')?.textContent === 'completed'";
            timeout = 120) == true
        # The red ERROR text + stacktrace in the Output console, no click.
        @test TK.wait_for(s, "ERROR output visible",
            """(() => { const b = document.querySelector('$card .bt-tool-body');
                const t = (b && b.innerText) || '';
                return t.includes('ERROR:') && t.includes('DomainError'); })()""";
            timeout = 30) == true
        # The result embed is the LIVE-rendered CapturedException (descriptor
        # with errored: true → RemoteRef mount → Bonito's exception render).
        @test TK.wait_for(s, "live exception result mounted",
            """(() => { const e = document.querySelector('$card .bt-embed');
                return !!e && (e.innerText || '').includes('DomainError'); })()""";
            timeout = 30) == true

        TK.screenshot(s, shot("bt_eval-failed.png"))
    finally
        close(s)
    end
end

# bt_julia_continue: the checkpoint/reattach pair. The eval checkpoints on
# its soft timeout (partial output + "still running"); the continue call
# reattaches through the REAL julia_continue_handler and delivers the rest.
# The continue card carries NO code argument — its body must NOT render an
# empty "Code" Monaco box (the source lives in the eval card above): Output
# and the result only.
@testset "bt_eval e2e — continue: checkpoint reattach, no empty Code box" begin
    project = EVALENV   # result embed asserted → needs the bridge
    code = """
    println("before checkpoint")
    sleep(3)
    println("after checkpoint")
    424242
    """
    s = TK.dev_server(; agent = msg -> [
        text("slow job"),
        bt_eval(code; env_path = project, id = "tc-1", timeout = 1),
        bt_continue(; env_path = project, id = "tc-2", timeout = 60),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 900)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        TK.send_message(s, "continue please")
        card1 = ".bt-tool-msg[data-msg-id*=\"tc-1\"]"
        card2 = ".bt-tool-msg[data-msg-id*=\"tc-2\"]"

        # The eval checkpoints: completed with the "still running" footer.
        @test TK.wait_for(s, "eval checkpointed",
            """(() => { const c = document.querySelector('$card1');
                return !!(c && c.querySelector('.bt-tool-status')?.textContent === 'completed' &&
                    (c.querySelector('.bt-tool-body')?.innerText || '').includes('still running')); })()""";
            timeout = 120) == true
        # The continue card completes with the tail of the output + result.
        @test TK.wait_for(s, "continue delivered output + result",
            """(() => { const c = document.querySelector('$card2');
                if (!c) return false;
                const t = (c.querySelector('.bt-tool-body')?.innerText || '');
                return c.querySelector('.bt-tool-status')?.textContent === 'completed' &&
                       t.includes('after checkpoint') &&
                       (c.querySelector('.bt-embed')?.innerText || '').includes('424242'); })()""";
            timeout = 120) == true
        # ... and it has NO Code section (continue carries no code).
        @test TK.eval_js(s,
            """[...document.querySelectorAll('$card2 .bt-subsection-label')]
               .every(l => l.textContent !== 'Code')""") == true

        TK.screenshot(s, shot("bt_eval-continue.png"))
    finally
        close(s)
    end
end

@testset "bt_eval e2e — env_path isolation: two projects, separate sessions" begin
    # Two independent tmp projects. Run `Base.active_project()` in each
    # via bt_eval. The output for each must point at its OWN tmp project,
    # proving the env_path is honored end-to-end (not "all eval runs in
    # the test process's project"). This is the regression the user asked
    # for under "tmp env with correct package versions" — env_path
    # leaking would make e.g. `pkgversion(Bonito)` return the
    # development version when the user expected the registered one.
    pA = fresh_project("envA")
    pB = fresh_project("envB")

    s = TK.dev_server(; agent = msg -> begin
        # Choose env based on the user's message. The test sends two
        # prompts; pick the matching env each turn.
        if occursin("A", msg)
            [text("Running in env A."),
             bt_eval("Base.active_project()"; env_path = pA, id = "teA"),
             end_turn()]
        else
            [text("Running in env B."),
             bt_eval("Base.active_project()"; env_path = pB, id = "teB"),
             end_turn()]
        end
    end)
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)

        # Turn 1: env A
        TK.send_message(s, "active project in A?")
        TK.wait_for(s, "first bt_eval landed",
                    """document.querySelectorAll('.bt-tool-msg .bt-status-completed').length >= 1""";
                    timeout = 60)
        sleep(0.5)
        TK.click(s, ".bt-tool-msg[data-msg-id*=\"teA\"] .bt-tool-header")
        sleep(1.5)

        bodyA = TK.eval_js(s, """document.querySelector('.bt-tool-msg[data-msg-id*="teA"] .bt-tool-body')?.innerText || ''""")
        @info "envA body" bodyA
        @test occursin(pA, bodyA)
        @test !occursin(pB, bodyA)
        TK.screenshot(s, shot("bt_eval-envA.png"))

        # Turn 2: env B
        TK.send_message(s, "active project in B?")
        TK.wait_for(s, "second bt_eval landed",
                    """document.querySelectorAll('.bt-tool-msg .bt-status-completed').length >= 2""";
                    timeout = 60)
        sleep(0.5)
        TK.click(s, ".bt-tool-msg[data-msg-id*=\"teB\"] .bt-tool-header")
        sleep(1.5)

        bodyB = TK.eval_js(s, """document.querySelector('.bt-tool-msg[data-msg-id*="teB"] .bt-tool-body')?.innerText || ''""")
        @info "envB body" bodyB
        @test occursin(pB, bodyB)
        @test !occursin(pA, bodyB)
        TK.screenshot(s, shot("bt_eval-envB.png"))

        @info "screenshots saved" dir=SHOT_DIR files=readdir(SHOT_DIR)
    finally
        close(s)
    end
end

# A tmp project that pins the dev Bonito so the eval worker can render the
# result to a LIVE fragment (`render_eval_html`). Pre-instantiated (the worker
# does NOT auto-instantiate) — Bonito is already precompiled in the depot, so
# this resolves fast.
function bonito_project()
    d = mktempdir(; prefix = "bt-eval-bonito-")
    bonito = pkgdir(Bonito)   # the v5 source the test env actually resolved (sandbox-safe)
    open(joinpath(d, "Project.toml"), "w") do io
        write(io, """
        name = "btbon"
        uuid = "$(string(Base.UUID(rand(UInt128))))"
        version = "0.0.1"

        [deps]
        Bonito = "824d6782-a2ef-11e9-3a09-e5662e0c26f8"

        [sources]
        Bonito = {path = "$bonito"}
        """)
    end
    run(pipeline(`$(Base.julia_cmd()) --project=$d -e "import Pkg; Pkg.instantiate()"`;
                 stdout = devnull, stderr = devnull))
    return d
end

@testset "bt_eval e2e — rich result renders as a LIVE Bonito fragment (not text fallback)" begin
    project = bonito_project()
    @info "bonito project env" project
    s = TK.dev_server(; agent = msg -> [
        text("rendering it live"),
        bt_eval("using Bonito; DOM.div(\"FRAGMENT-MARKER-9173\"; class = \"my-eval-result\")";
                env_path = project, id = "tf-1"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        TK.send_message(s, "render a div please")
        TK.wait_for(s, "eval tool completed",
            "document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent === 'completed'";
            timeout = 120)
        sleep(1.0)
        # The result body is lazy-mounted on expand (ToolRenderCommand fires when
        # the header is clicked) — expand it so the eval body + result render.
        TK.click(s, ".bt-tool-msg .bt-tool-header")
        sleep(2)
        # The result mounted as a LIVE worker fragment (render_eval_html → HTML
        # over the bridge): the worker-side div, WITH its `my-eval-result` class,
        # is in the page. A text-fallback repr would NOT carry that class — so
        # this distinguishes the new HTML chain from the old text path.
        @test TK.wait_for(s, "live fragment mounted",
            "document.querySelector('.my-eval-result')?.textContent?.includes('FRAGMENT-MARKER-9173') === true";
            timeout = 30) == true
        # The env_path is ALWAYS shown in the eval header.
        @test TK.eval_js(s, "document.body.innerText.includes($(TK.json(project)))") == true
        TK.screenshot(s, shot("bt_eval-fragment.png"))
    finally
        close(s)
    end
end

# This is the crux of "bt_show_app is redundant": an INTERACTIVE result (an
# Observable wired to a button) must round-trip through the LIVE eval bridge, not
# just render static markup. If clicking the button updates the count, the
# worker-side session is live over the bridge — exactly what bt_show_app provided,
# now via the plain bt_julia_eval render path. `$(obs)` must reach the test source
# as a literal `$` (escaped) so it's Bonito JS interpolation, not Julia's.
@testset "bt_eval e2e — INTERACTIVE result is live over the eval bridge" begin
    project = bonito_project()
    # Mirror app_interactive.jl's proven pattern: the displayed value is a Julia
    # `map` over a click counter, computed IN THE WORKER (7×clicks). The onclick
    # only bumps the raw counter; "C=7" can ONLY appear if the click round-tripped
    # to the worker, the map ran there, and the value streamed back. A static/dead
    # mount leaves it at "C=0".
    code = "using Bonito; App() do; " *
        "clicks = Observable(0); " *
        "out = map(c -> \"C=\" * string(7c), clicks); " *
        "DOM.div(DOM.span(out; class=\"counter-out\"), " *
        "DOM.div(\"bump\"; class=\"counter-btn\", onclick=js\"(e)=> \$(clicks).notify(\$(clicks).value + 1)\"); " *
        "class=\"my-counter\"); end"
    s = TK.dev_server(; agent = msg -> [
        text("live counter"),
        bt_eval(code; env_path = project, id = "tc-1"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        # Bind a fresh per-project dial-back for THIS chat's eval worker (the worker
        # dials back once, bound to the first project that used it — app_interactive
        # does the same so the embed renders for the right chat).
        TK.send_message(s, "give me a counter")
        TK.wait_for(s, "eval tool completed",
            "document.querySelector('.bt-tool-msg .bt-tool-status')?.textContent === 'completed'";
            timeout = 120)
        sleep(1.0)
        TK.click(s, ".bt-tool-msg .bt-tool-header")   # expand → lazy-mount the body
        # The counter renders with its Julia-computed initial value (static markup).
        @test TK.wait_for(s, "counter mounted",
            "document.querySelector('.counter-out')?.textContent === 'C=0'"; timeout = 30) == true
        # Click the button; the Julia map (7×clicks) runs in the worker and streams
        # back — only possible over a LIVE bridge.
        # Click the button; the Julia map (7×clicks) runs in the worker and streams
        # back over the live proxy bridge — same single render path as any result.
        # (Regression guard for the dropped-frame bug: the init bundle's
        # `proxy_asset_add` fires at eval-time before the dial-back connects; the
        # BridgeDriver must buffer it and flush on connect, else the host never
        # learns `/assets/<key>` is proxied and the browser's fetch isn't forwarded.)
        TK.click(s, ".my-counter .counter-btn")
        @test TK.wait_for(s, "counter incremented over the bridge",
            "document.querySelector('.counter-out')?.textContent === 'C=7'"; timeout = 30) == true

        # ZERO output for a value that's DISPLAYED in the result pane. The
        # counter prints nothing and returns an App — the App is shown as the
        # live embed, so there must be NO Output section at all (not the App's
        # struct dump, not even a concise "App"). The result repr rides in the
        # descriptor for the agent; the user sees only the embed. This pins the
        # regression where the result echo leaked into Output.
        has_output = TK.eval_js(s, """(() => {
            const c = document.querySelector('.bt-tool-msg[data-msg-id*="tc-1"]')
                   || document.querySelector('.bt-tool-msg');
            return [...c.querySelectorAll('.bt-subsection-label')]
                .some(l => (l.textContent||'').trim() === 'Output');
        })()""")
        @test has_output == false
        TK.screenshot(s, shot("bt_eval-counter.png"))
    finally
        close(s)
    end
end
