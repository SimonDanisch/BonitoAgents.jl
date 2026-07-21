# Dashboard-workflow walkthrough: the multi-project experience — every chat as a
# live card on one dashboard, and switching between projects from the cards AND
# the sidebar. This is the START-PAGE hero clip; the focused bt_julia_eval /
# plot demo lives in `walkthrough_mock.jl` and plays UNDER it.
#
# Substrate is the persistent RIG (four real seeded chats with their own plot
# thumbnails: a Julia-set gallery, a Game-of-Life torus refactor, a parallel
# code audit, a Lorenz explorer). Re-recording replays them from disk — no
# tokens, no agent prompts.
#
# STRICT: every on-camera interaction is a REAL, trusted input event —
# `ECT.real_click` (Chromium-level mouse, sets CSS :hover) and `ECT.wheel`
# (trusted WheelEvent, the page really scrolls). `eval_js` is used ONLY to READ
# layout / view state for aiming and gating, never to act. No synthetic
# `.click()`, no `scrollTop`.
#
# Run:  julia --project=/sim/Programmieren/AgentsDev examples/walkthrough_dashboard.jl
# Out:  examples/walkthrough_dashboard.mp4

isdefined(@__MODULE__, :tour) || include(joinpath(@__DIR__, "walkthrough.jl"))

# ── view-state gates (READ ONLY) ───────────────────────────────────────────────
dash_visible_js() = "(document.querySelector('.bt-ov-grid')?.offsetParent ?? null) !== null"
pane_visible_js(pid) = "(document.querySelector('.bt-chatpane[data-pane-pid=$(repr(pid))]')?.offsetParent ?? null) !== null"
# A sidebar chat entry, addressed by project id (robust — no title matching).
side_item_js(pid) = "document.querySelector('.bt-side-item[data-project-id=$(repr(pid))]')"

# ── real-input camera helpers (STRICT: trusted events only) ─────────────────────
# Real wheel: park the cursor in the transcript, then dispatch genuine
# WheelEvents. dy>0 scrolls DOWN (content up).
function dwheel!(s, ctx, dy)
    cursor_to_transcript!(s, ctx)
    ECT.wheel(ctx, dy; steps = 8, step_sleep = 0.05)
    sleep(0.25)
end

wait_dash!(s) = TK.wait_for(s, "dashboard visible", dash_visible_js(); timeout = 20)
wait_pane!(s, pid) = TK.wait_for(s, "chat pane visible", pane_visible_js(pid); timeout = 30)

# Open a chat from a coords target (a dashboard card), settle, then optionally
# wheel to reveal its content.
function open_card!(s, ctx, pid; peek = 0)
    ECT.real_click(ctx, ECT.JS(card_js(pid)))
    wait_pane!(s, pid); sleep(1.3)
    peek != 0 && (dwheel!(s, ctx, peek); sleep(1.1))
    sleep(0.5)
end

# Switch to a chat straight from the sidebar (no trip through the dashboard).
function switch_side!(s, ctx, pid; peek = 0)
    ECT.real_click(ctx, ECT.JS(el_center_js(side_item_js(pid))))
    wait_pane!(s, pid); sleep(1.3)
    peek != 0 && (dwheel!(s, ctx, peek); sleep(1.1))
    sleep(0.5)
end

function go_home!(s, ctx)
    ECT.real_click(ctx, ECT.JS(el_center_js(home_js())))
    wait_dash!(s); sleep(1.0)
end

# ── the recorded tour ───────────────────────────────────────────────────────────
function tour_dashboard(s, ctx, pids)
    T0 = time(); mark(n) = @info "dash" step = n at = round(time() - T0; digits = 1)

    # 1 ─ THE DASHBOARD. Every project on every machine as a live card, each
    #     thumbnail rendered from that chat's own plot. Let it hold in frame — no
    #     aimless cursor wandering; the first move is the one that opens a project.
    wait_dash!(s); sleep(2.6); mark("1 dashboard")

    # 2 ─ open a project straight from its card → its full chat.
    open_card!(s, ctx, pids["FractalGallery"]; peek = 430)
    mark("2 fractal")

    # 3 ─ Home, then a different project from its card.
    go_home!(s, ctx)
    open_card!(s, ctx, pids["GameOfLife"]; peek = 540)
    mark("3 gameoflife")

    # 4 ─ switch projects from the SIDEBAR — instant, no dashboard round-trip.
    switch_side!(s, ctx, pids["TinyServer"]; peek = 470)
    mark("4 audit")
    switch_side!(s, ctx, pids["LorenzExplorer"]; peek = 0)   # rest at its top
    mark("5 lorenz")

    # 5 ─ back to the dashboard: the home base for every machine.
    go_home!(s, ctx); sleep(1.8)
    mark("6 home")
end

function record_dashboard(; outpath = joinpath(@__DIR__, "walkthrough_dashboard.mp4"))
    s = attach_rig()
    try
        TK.open_browser(s)
        TK.set_window_size(s, 1600, 900)
        TK.eval_js(s, "location.reload(); true"); sleep(6)
        TK.install_pane_scope!(s)
        TK.wait_for(s, "app back after reload", "!!document.querySelector('.bt-sidebar')"; timeout = 60)
        warm_mirrors!(s)
        pids = rig_pids(s.h.state)
        warm_chats!(s, pids)          # every chat's session + keep-alive pane up → instant switches
        TK.to_dashboard(s)
        ctx = s.browser[]
        ECT.install_error_sink(ctx)
        ECT.install_cursor(ctx; start = (800, 780))
        sleep(0.8)
        ECT.record_video(() -> tour_dashboard(s, ctx, pids), ctx, outpath; fps = 30)
        errs = TK.js_errors(s)
        isempty(errs) || @warn "JS errors during dashboard walkthrough" errs
        @info "wrote $outpath"
    finally
        close(s)
    end
    return outpath
end

abspath(PROGRAM_FILE) == (@__FILE__) && record_dashboard()
