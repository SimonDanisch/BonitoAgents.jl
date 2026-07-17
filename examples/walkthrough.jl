# BonitoAgents walkthrough, recorded with ElectronCall.Testing over a
# PERSISTENT demo rig.
#
# Unlike the old fully-scripted version, the four chats on camera are REAL
# claude-agent-acp sessions (Opus + the built-in Julia MCP tools), seeded once
# into a reusable rig directory and replayed from disk on every re-record —
# re-recording burns no tokens. The rig lives OUTSIDE the repo (it holds
# machine-local absolute paths); see its README for how it was seeded and how
# to revive the live app embed after a cold start:
#
#   <rig root>/            (BT_WALKTHROUGH_RIG, default: ../../../walkthrough)
#     README.md            how to relaunch / re-seed / revive
#     rig/                 dev_server(dir = ...) state: server state, mirrors,
#                          worker config (worker id pinned → projects stay valid)
#     projects/            the four demo projects the agent actually worked on
#
# The tour: dashboard overview cards (thumbnails from the chats' own plots) →
# open the Lorenz chat from its card → steer the LIVE WGLMakie app's rho
# slider → detach the app and dock it beside the chat (the plotpane) → open
# lorenz.jl from the sidebar file tree (tabs beside the app) → flip through
# the fractal gallery chat → the Game of Life refactor diff → the parallel
# subagent audit feed → back to the dashboard.
#
# Run:  julia --project=BonitoAgents/test examples/walkthrough.jl
# Out:  examples/walkthrough.mp4  (1600x900, 16:9, 30 fps)

# Guarded: a warm seeding session that already holds a TestKit (and a live
# TestServer from it) must not shadow it with a second module instance —
# the types would no longer match.
isdefined(@__MODULE__, :TestKit) ||
    include(joinpath(@__DIR__, "..", "BonitoAgents", "test", "testkit", "TestKit.jl"))
const TK  = TestKit
const ECT = TestKit.ECT
using BonitoWidgets: groupbody, floattitle
import BonitoAgents as BT

const RIG_ROOT = get(ENV, "BT_WALKTHROUGH_RIG",
                     abspath(joinpath(@__DIR__, "..", "..", "..", "walkthrough")))

# ── rig attach ───────────────────────────────────────────────────────────────
# Reopen the persistent rig: same state dir, same pinned worker id, so every
# project/chat seeded earlier is exactly where it was. `mock = false` keeps the
# real provider wiring (needed only if you re-seed; the tour itself never
# prompts the agent).
attach_rig(; rig = RIG_ROOT) =
    TK.dev_server(; mock = false, name = "studio", dir = joinpath(rig, "rig"))

# name → project id, resolved from the persisted projects table.
function rig_pids(state)
    Dict(p.name => p.id for (_, p) in state.projects[])
end

# Copy every `shown:` file referenced by any chat from the worker tree into the
# server mirror. Idempotent; makes the dashboard cards' thumbnails and every
# bt_show body render without a fetch pause on camera. (A file the agent
# later deleted just logs and is skipped — its pill shows the graceful
# error body, which the tour avoids.)
function warm_mirrors!(server)
    state = server.h.state
    for (_, p) in state.projects[]
        msgs, chat_dir = BT.overview_msgs(state, p)
        for m in msgs
            m isa BT.ToolMsg || continue
            content = BT.tool_content_for_render(m, chat_dir)
            isempty(content) && continue
            ref = BT.find_show_reference(content)
            ref === nothing && continue
            path = BT.parse_show_path(ref)
            path === nothing && continue
            try
                BT.fetch_show_file(BT.ShowTool(state, p.id, p.server_path, path))
            catch e
                @warn "walkthrough: shown file not warmable (skipped)" path exception = e
            end
        end
    end
end

# Bring every chat's session + pane up BEFORE the camera rolls: ensures the
# ChatModels exist (claude session/load, no tokens), mounts the keep-alive
# panes, and lets images settle — chat switches on camera are then instant.
function warm_chats!(server, pids)
    state = server.h.state
    # Lorenz LAST: it's the first chat the tour opens and the only one whose
    # pane re-mount is expensive (the live WGLMakie embed re-boots on a
    # keep-alive eviction) — keep it most-recently-used going into the tour.
    order = ["GameOfLife", "FractalGallery", "TinyServer", "LorenzExplorer"]
    for name in order
        BT.ensure_project_session!(state, state.projects[][pids[name]])
    end
    for name in order
        TK.open_chat(server, pids[name])
        sleep(4)
    end
end

# After a COLD rig attach the eval worker is fresh, so the live app the agent
# registered during seeding is gone — its embed shows the placeholder. One
# cheap single-purpose prompt re-registers it. Opt-in (BT_WALKTHROUGH_REVIVE=1)
# because it's the only step that talks to the real agent.
function revive_live_app!(server, pids)
    state = server.h.state
    # The rig worker dials back asynchronously after attach — a prompt sent
    # before its control WS is up fails the lazy ACP bind ("Worker … is not
    # connected") and the revive turn dies without registering anything.
    t0 = time()
    while isempty(state.worker_control_ws) && time() - t0 < 60
        sleep(0.5)
    end
    isempty(state.worker_control_ws) && error("revive: rig worker never connected")
    model = BT.ensure_project_session!(state, state.projects[][pids["LorenzExplorer"]])
    s = BT.shared(model)
    BT.send_message!(model, BT.UserMsg(
        "Bring the interactive explorer app back up with bt_show_app " *
        "(env_path = \"/sim/Programmieren/ClaudeExperiments\", rho slider 10:60, " *
        "same as before). Nothing else, no prose."))
    t0 = time()
    while !s.busy_active[] && time() - t0 < 60; sleep(2); end
    while s.busy_active[] && time() - t0 < 420; sleep(5); end
    @info "revive turn finished" busy = s.busy_active[]
end

# ── camera helpers ───────────────────────────────────────────────────────────
# REAL input only: everything on camera must be a genuine input event on a
# VISIBLE element — no programmatic scrollTo/scrollIntoView, no
# `element.click()`, no value-poking. Scrolling is `ECT.wheel` (trusted
# `sendInputEvent` wheel at the cursor), sliders are `ECT.steer_slider`
# (trusted mouse drag of the thumb) and it THROWS if the slider isn't on
# screen; clicks are `ECT.click` at resolved coordinates.

# Park the cursor over the transcript's LEFT GUTTER (message padding), where a
# user would wheel: the center of the column can be occupied by a WGLMakie
# canvas, which captures wheel events for camera zoom instead of scrolling.
function cursor_to_transcript!(s, ctx)
    r = TK.eval_js(s, """(() => {
        const c = [...document.querySelectorAll('.bt-messages')].find(e => e.offsetParent);
        if (!c) return null;
        const b = c.getBoundingClientRect();
        return [b.x + 30, b.y + b.height / 2];
    })()""")
    ECT.move_to(ctx, (Float64(r[1]), Float64(r[2])); duration = 0.4)
end

# How far `js_el`'s center sits from the viewport position `at` (0 = top,
# 1 = bottom): negative = above, positive = below, 0 = within ±tol px.
# nothing = not in the DOM.
function el_offscreen(s, js_el::AbstractString; at = 0.5, tol = 60)
    v = TK.eval_js(s, """(() => {
        const el = $(js_el);
        if (!el) return null;
        const r = el.getBoundingClientRect();
        const off = (r.y + r.height / 2) - window.innerHeight * $(Float64(at));
        return Math.abs(off) <= $(Float64(tol)) ? 0 : off;
    })()""")
    return v === nothing ? nothing : Float64(v)
end

# Real-wheel until `js_el` sits at viewport position `at` (e.g. 0.25 parks a
# slider near the top so the canvas below it stays in frame).
function wheel_to!(s, ctx, js_el::AbstractString; at = 0.5, max_ticks = 40)
    cursor_to_transcript!(s, ctx)
    for _ in 1:max_ticks
        off = el_offscreen(s, js_el; at)
        off === nothing && return false
        off == 0 && return true
        ECT.wheel(ctx, clamp(off, -320, 320))
        sleep(0.25)
    end
    return el_offscreen(s, js_el; at) == 0
end

# Page-coordinate center of `js_el` (for a real ECT.click on it).
el_center_js(js_el::AbstractString) = """(() => {
    const el = $(js_el);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
})()"""

# Click a sidebar chat entry by its (persistent) title.
side_chat_js(title) = """(() => {
    const e = [...document.querySelectorAll('.bt-side-item')]
        .find(x => x.offsetParent && (x.innerText||'').includes($(repr(title))));
    if (!e) return null;
    const r = e.getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
})()"""

# Center of the dashboard overview card for project `pid`.
card_js(pid) = """(() => {
    const c = document.querySelector('.bt-ov-card[data-project-id=$(repr(pid))]');
    if (!c) return null;
    const r = c.getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
})()"""

# The LAST matching element's center (page coordinates) — pill buttons etc.
last_el_js(sel) = """(() => {
    const es = [...document.querySelectorAll($(repr(sel)))].filter(e => e.offsetParent);
    const e = es[es.length - 1];
    if (!e) return null;
    const r = e.getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
})()"""

# The detach button of the app pill that holds the LIVE canvas — a chat can
# carry older app pills whose embeds are placeholders (their eval-worker
# registration died with a previous rig session); detaching one of those pops
# an empty float and the canvas beat stalls.
live_detach_js() = """(() => {
    const pill = [...document.querySelectorAll('.bt-tool-msg')]
        .filter(e => e.offsetParent && e.querySelector('canvas'))
        .pop();
    const b = pill && pill.querySelector('.bt-tool-detach');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
})()"""

# JS locator for the `nth` visible tool pill containing `needle` (element
# expression — combine with el_center_js / el_offscreen / wheel_to!).
pill_js(needle; nth = 1) = """[...document.querySelectorAll('.bt-tool-msg')]
    .filter(e => e.offsetParent && (e.innerText||'').includes($(repr(needle))))[$(nth - 1)]"""

# Whether the pill's body is still collapsed (so a header click EXPANDS it —
# clicking an already-open pill would collapse it on camera).
pill_collapsed(s, needle; nth = 1) = TK.eval_js(s, """(() => {
    const p = $(pill_js(needle; nth));
    if (!p) return false;
    const d = p.querySelector('details');
    if (d) return !d.open;
    const body = p.querySelector('.bt-tool-body');
    return !(body && body.childElementCount > 0);
})()""") === true

# The sidebar Home entry (the tour returns to the dashboard by CLICKING it,
# like a user — never by poking navigation state).
home_js() = """[...document.querySelectorAll('.bt-side-item')]
    .find(x => x.offsetParent && (x.innerText||'').trim() === 'Home')"""

# The live embed occasionally lands in a broken intermediate state after the
# warm sweep's keep-alive evictions (re-embed raced by the next navigation);
# a dedicated open + settle remounts it cleanly. Gate the camera on it.
function ensure_live_embed!(s, pids; tries = 3)
    for attempt in 1:tries
        TK.open_chat(s, pids["LorenzExplorer"])
        sleep(8)
        ok = TK.eval_js(s, """(() => {
            const p = [...document.querySelectorAll('.bt-chatpane')].find(x => x.offsetParent !== null);
            return !!(p && p.querySelector('canvas') &&
                      p.querySelector('.bt-embed input[type=range]'));
        })()""")
        ok === true && return true
        @warn "walkthrough: live embed not up, remounting" attempt
        TK.to_dashboard(s)
        sleep(2)
    end
    error("walkthrough: the live Lorenz embed did not come up — see the rig README's revive notes")
end

# ── the recorded tour ────────────────────────────────────────────────────────
function tour(s, ctx, pids)
    # 1 ─ the dashboard: four real sessions, thumbnails from their own plots.
    # (record() parked the app on the dashboard before the camera started —
    # everything from here on is real cursor/wheel input.)
    sleep(1.6)
    ECT.move_to(ctx, ECT.JS(card_js(pids["FractalGallery"])); duration = 0.9)
    sleep(0.9)
    ECT.move_to(ctx, ECT.JS(card_js(pids["LorenzExplorer"])); duration = 0.8)
    sleep(0.7)

    # 2 ─ open the Lorenz chat straight from its overview card.
    ECT.click(ctx, ECT.JS(card_js(pids["LorenzExplorer"])))
    TK.wait_for(s, "lorenz chat open",
        "[...document.querySelectorAll('.bt-text-input')].some(e => e.offsetParent)"; timeout = 30)
    sleep(1.4)

    # 3 ─ the LIVE WGLMakie app. Wheel (real input) until the SLIDER is on
    #     screen — steer_slider drags the actual thumb with trusted mouse
    #     events and refuses to run off screen. Centering the slider keeps the
    #     canvas right below it, so the recomputed attractor morphs in view.
    TK.wait_for(s, "live slider present",
        "[...document.querySelectorAll('.bt-embed input[type=range]')].some(e => e.offsetParent)";
        timeout = 60)          # a keep-alive re-mount re-boots the WGLMakie embed
    # The embed keeps growing for a moment as the canvas mounts, which shifts
    # the virtual scroll under us — re-aim until the slider HOLDS its spot.
    for attempt in 1:4
        wheel_to!(s, ctx, "document.querySelector('.bt-embed input[type=range]')"; at = 0.18)
        sleep(1.2)
        el_offscreen(s, "document.querySelector('.bt-embed input[type=range]')"; at = 0.18) == 0 && break
    end
    # Down into the pre-chaotic regime first (ρ≈17: the density collapses to
    # a galaxy-like spiral around the stable fixed point), then sweep up
    # through the chaos transition at ρ≈24.7 into the molten twin-lobed
    # butterfly (ρ≈47) — the most dramatic morph the surface offers.
    ECT.steer_slider(ctx, ".bt-embed input[type=range]", 0.14; duration = 1.4)
    sleep(1.0)
    ECT.steer_slider(ctx, ".bt-embed input[type=range]", 0.75; duration = 2.0)
    sleep(1.2)

    # 4 ─ detach the app and dock it beside the chat: the plotpane. The detach
    #     button lives in the pill HEADER — wheel it on screen, then click it.
    wheel_to!(s, ctx, """[...document.querySelectorAll('.bt-tool-msg')]
        .filter(e => e.offsetParent && e.querySelector('canvas'))
        .pop()?.querySelector('.bt-tool-detach')""")
    sleep(0.8)
    ECT.click(ctx, ECT.JS(live_detach_js()))
    TK.wait_for(s, "floating app window",
        "[...document.querySelectorAll('.bw-ws-float')].some(f => f.offsetParent && f.querySelector('canvas'))";
        timeout = 30)
    sleep(1.2)
    ECT.drag(ctx, ECT.JS(floattitle("App")),
             [ECT.JS(groupbody("Chat"; rel = (0.7, 0.5))),
              ECT.JS(groupbody("Chat"; rel = (0.94, 0.5)))];
             grab = 0.4, move = 1.1)
    sleep(1.6)

    # 5 ─ the docked app is still live: one more steer in the plotpane
    #     (the docked panel is fully visible, no scrolling needed).
    TK.wait_for(s, "docked slider",
        "[...document.querySelectorAll('input[type=range]')].some(e => e.offsetParent)"; timeout = 15)
    ECT.steer_slider(ctx, "input[type=range]", 0.45; duration = 1.2)
    sleep(0.8)

    # 6 ─ open lorenz.jl from the sidebar file tree → a tab beside the app.
    #     The ▾ files hint is HOVER-gated (pointer-events flips on `:hover`),
    #     which only real pointer state sets — real_click sends trusted input.
    ECT.move_to(ctx, ECT.JS(side_chat_js("Lorenz attractor explorer")))
    sleep(0.6)                                    # hover reveals the ▾ files hint
    ECT.real_click(ctx, ECT.JS(el_center_js("""[...document.querySelectorAll('.bt-side-chat')]
        .find(c => (c.innerText||'').includes('Lorenz'))
        ?.querySelector('.bt-side-tree-hint')""")))
    TK.wait_for(s, "file tree open",
        "[...document.querySelectorAll('.bt-tree-row')].some(e => e.offsetParent)"; timeout = 20)
    sleep(0.6)
    ECT.click(ctx, ECT.JS(el_center_js("""[...document.querySelectorAll('.bt-tree-row')]
        .find(x => x.offsetParent && x.innerText.includes('lorenz.jl'))""")))
    TK.wait_for(s, "editor open",
        "!!document.querySelector('.bt-file-editor .monaco-editor-div')"; timeout = 30)
    sleep(1.8)

    # 7 ─ switch chats: the fractal gallery, wheeling up through the renders.
    ECT.click(ctx, ECT.JS(side_chat_js("Julia-set fractal gallery")))
    TK.wait_for(s, "fractal chat visible",
        "[...document.querySelectorAll('.bt-text-input')].some(e => e.offsetParent)"; timeout = 20)
    sleep(1.0)
    cursor_to_transcript!(s, ctx)
    for _ in 1:3
        ECT.wheel(ctx, -700; steps = 8, step_sleep = 0.1)
        sleep(1.8)
    end

    # 8 ─ the refactor chat: a real Monaco diff from the torus edit. Click the
    #     pill's ▶ toggle to expand it (only if it isn't already open). The
    #     toggle is the deterministic target: the header CENTER can land on
    #     the title, which is a path-link that opens the editor instead.
    ECT.click(ctx, ECT.JS(side_chat_js("Game of Life: torus mode")))
    sleep(1.0)
    wheel_to!(s, ctx, pill_js("Edit"; nth = 1))
    if pill_collapsed(s, "Edit"; nth = 1)
        ECT.click(ctx, ECT.JS(el_center_js(pill_js("Edit"; nth = 1) *
            "?.querySelector('.bt-tool-toggle')")))
        # Replayed diffs arrive via a tool.render round trip — hold the shot
        # until Monaco is actually on screen.
        TK.wait_for(s, "diff mounts",
            pill_js("Edit"; nth = 1) *
            "?.querySelector('.monaco-diff-editor-div, .monaco-diff-editor') != null";
            timeout = 20)
    end
    sleep(2.4)

    # 9 ─ the audit chat: three parallel subagents with live activity feeds.
    ECT.click(ctx, ECT.JS(side_chat_js("Parallel code audit")))
    sleep(1.2)
    wheel_to!(s, ctx, pill_js("Task"; nth = 1))
    sleep(3.0)

    # 10 ─ home stretch: back to the dashboard by clicking Home, like a user.
    ECT.click(ctx, ECT.JS(el_center_js(home_js())))
    TK.wait_for(s, "dashboard visible",
        "!!document.querySelector('.bt-ov-grid')"; timeout = 15)
    sleep(1.0)
    ECT.move_to(ctx, ECT.JS(card_js(pids["GameOfLife"])); duration = 0.9)
    sleep(1.6)
end

# ── run ──────────────────────────────────────────────────────────────────────
# Pass an already-attached `server` (e.g. the warm seeding session, where the
# live app embed is still registered in the eval worker) to record without a
# fresh attach. A cold attach still records everything except the LIVE embed
# interior — see the rig README for the one-prompt revive.
function record(; server = nothing, outpath = joinpath(@__DIR__, "walkthrough.mp4"))
    s = server === nothing ? attach_rig() : server
    try
        server === nothing && TK.open_browser(s)
        TK.set_window_size(s, 1600, 900)          # 16:9
        # Fresh page: an interactive session accumulates WebGL contexts across
        # embed remounts, and Chromium reaps the OLDEST context past its ~16
        # cap — which can kill the live embed moments after it mounts. A
        # reload resets the budget so the take starts clean.
        TK.eval_js(s, "location.reload(); true")
        sleep(6)
        TK.install_pane_scope!(s)
        TK.wait_for(s, "app back after reload",
            "!!document.querySelector('.bt-sidebar')"; timeout = 60)
        warm_mirrors!(s)
        pids = rig_pids(s.h.state)
        get(ENV, "BT_WALKTHROUGH_REVIVE", "0") == "1" && revive_live_app!(s, pids)
        warm_chats!(s, pids)
        ensure_live_embed!(s, pids)
        TK.to_dashboard(s)
        ctx = s.browser[]
        ECT.install_error_sink(ctx)
        ECT.install_cursor(ctx; start = (800, 780))
        sleep(0.8)

        ECT.record_video(() -> tour(s, ctx, pids), ctx, outpath; fps = 30)

        errs = TK.js_errors(s)
        isempty(errs) || @warn "JS errors during walkthrough" errs
        @info "wrote $outpath"
    finally
        server === nothing && close(s)
    end
    return outpath
end

"""
    stills(; server = nothing, outdir = <docs/src/assets>)

Capture the two docs/README screenshots from the SAME rig states the video
tour shows — no separately staged scene that drifts from the real product:

  • screenshot-chat.png      — the Game-of-Life chat with the grid.jl torus
                               diff expanded above its test run (tour step 8)
  • screenshot-workspace.png — the Lorenz chat with the live density surface
                               docked beside it and lorenz.jl open in a tab
                               (tour steps 4 + 6)

Same prep as `record()` (reload → optional revive → warm → ensure), so run it
right after a recording with `stills(server = s)` and the states are hot.
"""
function stills(; server = nothing,
                  outdir = joinpath(@__DIR__, "..", "docs", "src", "assets"))
    s = server === nothing ? attach_rig() : server
    hide_cursor(s) = TK.eval_js(s,
        "(() => { const c = document.getElementById('__fake_cursor'); if (c) c.style.display = 'none'; return true; })()")
    show_cursor(s) = TK.eval_js(s,
        "(() => { const c = document.getElementById('__fake_cursor'); if (c) c.style.display = ''; return true; })()")
    try
        server === nothing && TK.open_browser(s)
        TK.set_window_size(s, 1600, 900)
        TK.eval_js(s, "location.reload(); true")
        sleep(6)
        TK.install_pane_scope!(s)
        TK.wait_for(s, "app back after reload",
            "!!document.querySelector('.bt-sidebar')"; timeout = 60)
        warm_mirrors!(s)
        pids = rig_pids(s.h.state)
        get(ENV, "BT_WALKTHROUGH_REVIVE", "0") == "1" && revive_live_app!(s, pids)
        warm_chats!(s, pids)
        ensure_live_embed!(s, pids)
        ctx = s.browser[]
        ECT.install_cursor(ctx; start = (800, 780))
        sleep(0.5)

        # A ─ chat still: the torus diff over its test run (tour step 8 state).
        TK.set_window_size(s, 1150, 1050)
        sleep(1.0)
        ECT.click(ctx, ECT.JS(side_chat_js("Game of Life: torus mode")))
        sleep(1.5)
        wheel_to!(s, ctx, pill_js("Edit"; nth = 1))
        if pill_collapsed(s, "Edit"; nth = 1)
            ECT.click(ctx, ECT.JS(el_center_js(pill_js("Edit"; nth = 1) *
                "?.querySelector('.bt-tool-toggle')")))
            TK.wait_for(s, "diff mounts",
                pill_js("Edit"; nth = 1) *
                "?.querySelector('.monaco-diff-editor-div, .monaco-diff-editor') != null";
                timeout = 20)
        end
        sleep(2.0)                                   # Monaco paint settles
        wheel_to!(s, ctx, pill_js("Edit"; nth = 1); at = 0.3)
        sleep(1.0)
        hide_cursor(s)
        chat_png = joinpath(outdir, "screenshot-chat.png")
        TK.screenshot(s, chat_png)
        show_cursor(s)

        # B ─ workspace still: live surface docked + lorenz.jl in a tab
        # (tour steps 4 + 6, minus the camera moves).
        TK.set_window_size(s, 1600, 900)
        sleep(1.0)
        ECT.click(ctx, ECT.JS(side_chat_js("Lorenz attractor explorer")))
        TK.wait_for(s, "live slider present",
            "[...document.querySelectorAll('.bt-embed input[type=range]')].some(e => e.offsetParent)";
            timeout = 60)
        sleep(1.0)
        wheel_to!(s, ctx, """[...document.querySelectorAll('.bt-tool-msg')]
            .filter(e => e.offsetParent && e.querySelector('canvas'))
            .pop()?.querySelector('.bt-tool-detach')""")
        sleep(0.8)
        ECT.click(ctx, ECT.JS(live_detach_js()))
        TK.wait_for(s, "floating app window",
            "[...document.querySelectorAll('.bw-ws-float')].some(f => f.offsetParent && f.querySelector('canvas'))";
            timeout = 30)
        sleep(1.2)
        ECT.drag(ctx, ECT.JS(floattitle("App")),
                 [ECT.JS(groupbody("Chat"; rel = (0.7, 0.5))),
                  ECT.JS(groupbody("Chat"; rel = (0.94, 0.5)))];
                 grab = 0.4, move = 1.1)
        sleep(1.6)
        ECT.move_to(ctx, ECT.JS(side_chat_js("Lorenz attractor explorer")))
        sleep(0.6)
        ECT.real_click(ctx, ECT.JS(el_center_js("""[...document.querySelectorAll('.bt-side-chat')]
            .find(c => (c.innerText||'').includes('Lorenz'))
            ?.querySelector('.bt-side-tree-hint')""")))
        TK.wait_for(s, "file tree open",
            "[...document.querySelectorAll('.bt-tree-row')].some(e => e.offsetParent)"; timeout = 20)
        sleep(0.6)
        ECT.click(ctx, ECT.JS(el_center_js("""[...document.querySelectorAll('.bt-tree-row')]
            .find(x => x.offsetParent && x.innerText.includes('lorenz.jl'))""")))
        TK.wait_for(s, "editor open",
            "!!document.querySelector('.bt-file-editor .monaco-editor-div')"; timeout = 30)
        sleep(3.0)                                   # Monaco + canvas settle
        hide_cursor(s)
        ws_png = joinpath(outdir, "screenshot-workspace.png")
        TK.screenshot(s, ws_png)
        show_cursor(s)
        return chat_png, ws_png
    finally
        server === nothing && close(s)
    end
end

# Auto-run only as a script — `include`-ing the file (a warm seeding session,
# REPL experiments) gets the pieces without kicking off a recording.
abspath(PROGRAM_FILE) == (@__FILE__) && record()
