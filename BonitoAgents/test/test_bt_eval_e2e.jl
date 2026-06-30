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
using .TestKit: text, bt_eval, end_turn

const SHOT_DIR = joinpath(tempdir(), "bt-eval-e2e")
mkpath(SHOT_DIR)
shot(name) = joinpath(SHOT_DIR, name)

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
        TK.refresh_eval_session!(project)
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
        TK.screenshot(s, shot("bt_eval-counter.png"))
    finally
        close(s)
    end
end
