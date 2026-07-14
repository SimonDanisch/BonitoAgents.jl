# BonitoAgents walkthrough, recorded with ElectronCall.Testing.
#
# A scripted tour of the dashboard: send a task, watch the agent stream a todo
# list (pinned to the taskbar), REAL `julia_eval` tool calls (executed through
# BonitoMCP's persistent Malt session — real stdout, real values, and a color
# matrix that comes back as an inline image), a Monaco diff, and a LIVE Bonito
# app; steer the app's slider; open a project file from the sidebar tree in
# the built-in editor; split the workspace by dragging its tab beside the chat.
#
# Only the prose and the edit-diff are scripted; every `bt_eval` and the app
# embed run real Julia in the eval session. No API key, no network, and the
# recording comes out the same every time. Every gesture is a real pointer
# event from ElectronCall's animated cursor. The eval session is pre-warmed
# before recording starts, so the video never sits on a cold Julia boot.
#
# Run:  julia --project=BonitoAgents/test examples/walkthrough.jl
# Out:  examples/walkthrough.mp4

include(joinpath(@__DIR__, "..", "BonitoAgents", "test", "testkit", "TestKit.jl"))
using .TestKit
const TK  = TestKit
const ECT = TestKit.ECT
using BonitoWidgets: tab, groupbody
import BonitoMCP

const APP_ENV = abspath(joinpath(@__DIR__, "..", "BonitoAgents", "test", "appenv"))
const PROMPT  = "Add a torus (wrap-around) mode to the Game of Life grid, verify it, and give me a live preview."

# ── real code the agent runs via julia_eval ──────────────────────────────────
# Beat 1: reproduce the problem — on a BOUNDED grid a glider starves at the edge.
const REPRO_CODE = """
step_bounded(g) = begin
    R, C = size(g); n = falses(R, C)
    for i in 1:R, j in 1:C
        s = -g[i,j]
        for di in -1:1, dj in -1:1
            ii, jj = i + di, j + dj
            (1 <= ii <= R && 1 <= jj <= C) || continue
            s += g[ii, jj]
        end
        n[i,j] = s == 3 || (g[i,j] && s == 2)
    end
    n
end
g = falses(12, 12); for (i,j) in [(2,3),(3,4),(4,2),(4,3),(4,4)]; g[i,j] = true; end
for gen in 1:40; global g = step_bounded(g); end
println("glider on a BOUNDED 12x12 grid, after 40 generations: ", count(g), " cells left")
"""

# Beat 2: verify the torus + hand back a heat-trail image. The value is a
# Matrix{RGB}, which julia_eval ships as an inline image (output discipline).
const VERIFY_CODE = """
step_torus(g) = begin
    R, C = size(g); n = falses(R, C)
    for i in 1:R, j in 1:C
        s = -g[i,j]
        for di in -1:1, dj in -1:1
            s += g[mod1(i+di,R), mod1(j+dj,C)]
        end
        n[i,j] = s == 3 || (g[i,j] && s == 2)
    end
    n
end
# R-pentomino at the center: chaotic growth that paints the whole torus.
g = falses(48, 72)
for (i,j) in [(24,36),(24,37),(25,35),(25,36),(26,36)]; g[i,j] = true; end
heat = zeros(48, 72)
for gen in 1:300
    global g = step_torus(g)
    heat .+= g
end
println("R-pentomino on a 48x72 TORUS: ", count(g), " live cells after 300 generations")
println("cells the pattern visited: ", count(>(0), heat), " of ", length(heat))
using Bonito.Colors
h = heat ./ maximum(heat)
[RGB(0.05 + 0.92v, 0.10 + 0.75v, 0.16 + 0.25v) for v in h]
"""

# The live preview: pure Bonito, the generation slider steps a glider on the
# torus — computed in Julia per slider move, so the embed is genuinely live.
const GOL_APP = """using Bonito
App() do
    step(g) = begin
        R, C = size(g); n = falses(R, C)
        for i in 1:R, j in 1:C
            s = -g[i,j]
            for di in -1:1, dj in -1:1
                s += g[mod1(i+di,R), mod1(j+dj,C)]
            end
            n[i,j] = s == 3 || (g[i,j] && s == 2)
        end
        n
    end
    gen = Bonito.Slider(0:80; value = 0)
    grid0 = falses(18, 28)
    for (i,j) in [(2,3),(3,4),(4,2),(4,3),(4,4), (9,14),(9,15),(10,14),(10,15), (12,20),(13,21),(14,19),(14,20),(14,21)]
        grid0[i,j] = true
    end
    cells = map(gen.value) do n
        g = grid0
        for _ in 1:n; g = step(g); end
        DOM.div((DOM.div(; style = "width:14px;height:14px;border-radius:3px;" *
                (v ? "background:#4fd1c5;" : "background:#1d232e;")) for v in permutedims(g))...;
            style = "display:grid;grid-template-columns:repeat(28,14px);gap:2px;padding:12px;background:#12161d;border-radius:8px;")
    end
    DOM.div(DOM.div("generation ", gen, map(string, gen.value);
                    style = "display:flex;gap:10px;align-items:center;color:#aab;padding:8px 12px;font:13px sans-serif;"),
            cells; style = "font-family:sans-serif;")
end"""

const OLD_GRID = """function neighbors(g::Grid, i::Int, j::Int)
    s = 0
    for di in -1:1, dj in -1:1
        (di == 0 && dj == 0) && continue
        ii, jj = i + di, j + dj
        (1 <= ii <= g.rows && 1 <= jj <= g.cols) || continue
        s += g.cells[ii, jj]
    end
    return s
end"""

const NEW_GRID = """function neighbors(g::Grid, i::Int, j::Int)
    s = 0
    for di in -1:1, dj in -1:1
        (di == 0 && dj == 0) && continue
        ii, jj = wrapped(g, i + di, j + dj)
        ii === nothing && continue
        s += g.cells[ii, jj]
    end
    return s
end

# Torus mode: indices wrap with mod1; bounded mode keeps the old clamp.
wrapped(g::Grid, i, j) = g.wrap ? (mod1(i, g.rows), mod1(j, g.cols)) :
    (1 <= i <= g.rows && 1 <= j <= g.cols ? (i, j) : nothing)"""

# ── the scripted agent ───────────────────────────────────────────────────────
# Prose and the edit-diff are scripted; the evals + app run REAL Julia.
# `TK.delay` keeps the stream readable without ending the turn.
function walkthrough_agent(prompt::AbstractString)
    occursin("torus", lowercase(prompt)) || return [TK.text("echo: $(prompt)"), TK.end_turn()]
    Any[
        TK.text("Plan: reproduce the edge die-off, add a `wrap::Bool` torus mode, verify it with a quick simulation."),
        TK.delay(800),
        TK.todo([(content = "Reproduce the boundary die-off",  status = "in_progress"),
                 (content = "Add wrap::Bool torus mode",        status = "pending"),
                 (content = "Verify + visualize on the torus",  status = "pending")]),
        TK.delay(800),
        TK.bt_eval(REPRO_CODE; env_path = APP_ENV, id = "wt-repro"),
        TK.delay(700),
        TK.text("Confirmed: the glider starves at the boundary. Adding the wrap mode:"),
        TK.todo([(content = "Reproduce the boundary die-off",  status = "completed"),
                 (content = "Add wrap::Bool torus mode",        status = "in_progress"),
                 (content = "Verify + visualize on the torus",  status = "pending")]),
        TK.delay(400),
        TK.tool(kind = "edit", title = "Edit src/grid.jl", id = "wt-edit",
                content = [TK.diff_block("src/grid.jl", OLD_GRID, NEW_GRID)]),
        TK.delay(600),
        TK.todo([(content = "Reproduce the boundary die-off",  status = "completed"),
                 (content = "Add wrap::Bool torus mode",        status = "completed"),
                 (content = "Verify + visualize on the torus",  status = "in_progress")]),
        TK.bt_eval(VERIFY_CODE; env_path = APP_ENV, id = "wt-verify"),
        TK.todo([(content = "Reproduce the boundary die-off",  status = "completed"),
                 (content = "Add wrap::Bool torus mode",        status = "completed"),
                 (content = "Verify + visualize on the torus",  status = "completed")]),
        # The LIVE preview last: its eval-worker dial-back takes a few seconds
        # to boot, which overlaps with the tour's image / file-tree beats —
        # the slider steer is the finale.
        TK.bt_show_app(GOL_APP; env_path = APP_ENV, id = "wt-app"),
        TK.text("The heat-trail shows the R-pentomino wrapping across every edge. The preview above is live — drag the generation slider to watch a glider cross the torus seam."),
        TK.end_turn(),
    ]
end

# The project files the sidebar tree + editor show.
function seed_project!(s)
    wdir = joinpath(s.h.worker_root, "GameOfLife")
    mkpath(joinpath(wdir, "src"))
    write(joinpath(wdir, "src", "grid.jl"), """
        module GameOfLifeGrid

        struct Grid
            rows::Int
            cols::Int
            wrap::Bool
            cells::BitMatrix
        end
        Grid(rows, cols; wrap = false) = Grid(rows, cols, wrap, falses(rows, cols))

        $(NEW_GRID)

        end # module
        """)
    write(joinpath(wdir, "src", "GameOfLife.jl"),
          "module GameOfLife\ninclude(\"grid.jl\")\nend\n")
    # `shown:` files (the heat-trail image) are written by the eval session
    # relative to ITS env — in production BonitoMCP runs ON the worker inside
    # the real project dir, but TestKit executes evals in this process with
    # cwd = APP_ENV. The chat fetches shown files from the worker project dir,
    # so link the eval env's `.bonitoAgents` into the seeded project (same
    # machine in the dev rig). The file tree ignores `.bonitoAgents`.
    mkpath(joinpath(APP_ENV, ".bonitoAgents"))
    symlink(joinpath(APP_ENV, ".bonitoAgents"), joinpath(wdir, ".bonitoAgents"))
    return wdir
end

# ── helpers ──────────────────────────────────────────────────────────────────
# Expand the `nth` visible tool pill whose text contains `needle` (the two
# julia_eval pills share their title, so the verify one is nth = 2).
expand_pill!(s, needle; nth = 1) = TK.eval_js(s, """(() => {
    const ps = [...document.querySelectorAll('.bt-tool-msg')]
        .filter(e => e.offsetParent && (e.innerText||'').includes($(repr(needle))));
    const p = ps[$(nth - 1)];
    if (!p) return false;
    const d = p.querySelector('details'); d && (d.open = true);
    p.querySelector('summary')?.click?.();
    return true;
})()""")

scroll_to_bottom!(s) = TK.eval_js(s, """(() => {
    const c = [...document.querySelectorAll('.bt-messages')].find(e=>e.offsetParent);
    if (!c) return false;
    c.dispatchEvent(new WheelEvent('wheel', {bubbles: true}));
    c.scrollTop = c.scrollHeight;
    c.dispatchEvent(new Event('scroll', {bubbles: true}));
    return true;
})()""")

# ── the recorded tour ────────────────────────────────────────────────────────
function tour(s, ctx)
    # 1 ─ start on the dashboard, then open the project on camera
    sleep(1.5)
    TK.new_chat(s; title = "GameOfLife")
    seed_project!(s)
    TK.wait_for(s, "chat view open",
        "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent)"; timeout = 30)
    sleep(1.2)

    # 2 ─ type the task and send it (.bt-text-input is the composer; a bare
    #     `textarea` selector would hit the search lens above the transcript)
    ECT.move_to(ctx, ECT.Sel(".bt-text-input"))
    ECT.click(ctx, ECT.Sel(".bt-text-input"))
    sleep(0.4)
    ECT.type_into(ctx, ".bt-text-input", PROMPT)
    sleep(1.0)
    ECT.click(ctx, ECT.Sel(".bt-send-btn"))

    # 3 ─ the turn streams: todo list, REAL evals, the diff, the app. Stay in
    #     follow-mode the whole time — every event scrolls into view on its
    #     own; expanding pills mid-stream would park the viewport mid-transcript.
    TK.wait_for(s, "turn finished",
        "[...document.querySelectorAll('.bt-agent-msg')].filter(e=>e.offsetParent).some(n => n.innerText.includes('torus seam'))";
        timeout = 120)
    sleep(1.2)

    # 4 ─ open the two evals deliberately: first the repro (code + stdout),
    #     then the verify with the inline heat-trail image
    expand_pill!(s, "bt_julia_eval"; nth = 1)
    sleep(1.8)
    expand_pill!(s, "bt_julia_eval"; nth = 2)
    TK.wait_for(s, "heat-trail image rendered",
        "[...document.querySelectorAll('.bt-tool-msg img[src], .bt-embed img[src]')].some(e => e.offsetParent)";
        timeout = 30)
    TK.eval_js(s, """(() => {
        const img = [...document.querySelectorAll('.bt-tool-msg img[src]')].find(e => e.offsetParent);
        img && img.scrollIntoView({block: 'center'});
        return true;
    })()""")
    sleep(2.2)

    # 5 ─ open a project file from the sidebar tree. The "▾ files" hint is a
    #     hover-revealed overlay on the chat row, so a coordinate click can hit
    #     the row beneath it — move the cursor there for the recording, but
    #     fire the click on the element itself.
    ECT.move_to(ctx, ECT.Sel(".bt-side-chat"))          # hover reveals the hint
    sleep(0.4)
    ECT.move_to(ctx, ECT.Sel(".bt-side-tree-hint"))
    TK.eval_js(s, "(() => { document.querySelector('.bt-side-tree-hint')?.click(); return true; })()")
    TK.wait_for(s, "file tree visible",
        "[...document.querySelectorAll('.bt-tree-row')].some(e=>e.offsetParent)"; timeout = 20)
    sleep(0.5)
    ECT.click(ctx, ECT.Sel(".bt-tree-row.bt-tree-dir")) # expand src/
    TK.wait_for(s, "src/ expanded",
        "[...document.querySelectorAll('.bt-tree-row.bt-tree-file')].some(e=>e.offsetParent && e.innerText.includes('grid.jl'))";
        timeout = 20)
    sleep(0.4)
    # JS targets are evaluated as EXPRESSIONS and must yield [x, y] page
    # coordinates — hence the IIFE (a bare arrow would return the function
    # itself, and a DOM element can't cross the IPC boundary).
    ECT.click(ctx, ECT.JS("""(() => {
        const e = [...document.querySelectorAll('.bt-tree-row.bt-tree-file')]
            .find(x => x.innerText.includes('grid.jl'));
        if (!e) return null;
        const r = e.getBoundingClientRect();
        return [r.x + r.width / 2, r.y + r.height / 2];
    })()"""))
    TK.wait_for(s, "editor open",
        "!!document.querySelector('.bt-file-editor .monaco-editor-div')"; timeout = 30)
    sleep(1.0)

    # 6 ─ split the workspace: drag the editor tab beside the chat
    ECT.drag(ctx, ECT.JS(tab("grid.jl")),
             [ECT.JS(groupbody("Chat"; rel = (0.5, 0.5))),
              ECT.JS(groupbody("Chat"; rel = (0.93, 0.5)))];
             grab = 0.4, move = 0.9)
    sleep(1.0)

    # 7 ─ the finale: the LIVE preview in the split layout. Bonito is already
    #     loaded in the eval worker (pre-warm), so the embed came up during
    #     the stream; steer its slider.
    scroll_to_bottom!(s)
    TK.wait_for(s, "live app slider up",
        "!!document.querySelector('.bt-embed input[type=range]')"; timeout = 45)
    ECT.steer_slider(ctx, ".bt-embed input[type=range]", 0.35; duration = 1.4)
    sleep(0.4)
    ECT.steer_slider(ctx, ".bt-embed input[type=range]", 0.8; duration = 1.4)
    sleep(0.8)

    # 8 ─ rest on the result
    ECT.move_to(ctx, (720, 620); duration = 0.8)
    sleep(1.2)
end

# ── run ──────────────────────────────────────────────────────────────────────
function record(; outpath = joinpath(@__DIR__, "walkthrough.mp4"))
    s = TK.dev_server(agent = walkthrough_agent,
                      browser_width = 1440, browser_height = 900)
    try
        TK.open_browser(s)
        ctx = s.browser[]
        # Pre-warm the eval session for APP_ENV: the dispatcher runs evals in
        # THIS process, so one throwaway call boots the Malt worker AND loads
        # Bonito in it now — `bt_show_app`'s registration then takes seconds
        # on camera instead of stalling the stream on a cold `using Bonito`.
        BonitoMCP.julia_eval_handler(Dict{String,Any}("code" => "using Bonito",
                                                      "env_path" => APP_ENV))
        ECT.install_error_sink(ctx)
        ECT.install_cursor(ctx; start = (720, 700))
        sleep(0.8)

        ECT.record_video(() -> tour(s, ctx), ctx, outpath; fps = 30)

        errs = TK.js_errors(s)
        isempty(errs) || @warn "JS errors during walkthrough" errs
        @info "wrote $outpath"
    finally
        close(s)
    end
    return outpath
end

# Auto-run only as a script — `include`-ing the file (screenshot sessions,
# REPL experiments) gets the pieces without kicking off a recording.
abspath(PROGRAM_FILE) == (@__FILE__) && record()
