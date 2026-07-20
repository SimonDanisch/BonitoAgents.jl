# Dashboard walkthrough, driven by the DETERMINISTIC MockACP agent.
#
# MockACP invokes the REAL bt_julia_eval (real Malt worker, real streaming, a
# real live/steerable app) but the CONVERSATION is exactly scripted — no
# fumbling, no failed cards, repeatable. So we pre-build the app off camera and
# open directly on it.
#
# STRICT: every on-camera interaction is a REAL input event — `ECT.wheel`
# (trusted WheelEvent, app scroll handlers fire), `ECT.real_click` (trusted
# press/release, sets CSS :hover for hover-gated controls), `ECT.steer_slider`
# (trusted thumb drag), `ECT.drag`. No `scrollTop`, no synthetic `.click()`.
# `eval_js` is used ONLY to READ layout (element rects) for aiming, never to act.
#
# The demo is a live curve-fitting dashboard: noisy samples + a least-squares
# polynomial fit, a DEGREE slider that walks underfit → overfit (RMSE live), and
# a streaming k-fold cross-validation sweep that finds the best degree.
#
# Run:  julia --project=BonitoAgents/test examples/walkthrough_mock.jl
# Out:  examples/walkthrough.mp4

isdefined(@__MODULE__, :tour) || include(joinpath(@__DIR__, "walkthrough.jl"))

const MOCK_EVAL_ENV  = get(ENV, "BT_WALKTHROUGH_EVAL_ENV", "/sim/Programmieren/AgentsDev")
const MOCK_CHAT_TITLE = "RegressionExplorer"        # NO spaces — new_chat's bind hangs on a spaced title
const SHOTDIR = get(ENV, "BT_WALKTHROUGH_SHOTS", "/tmp/wshots")

# ── the app: an interactive least-squares curve-fitting dashboard ──────────────
# Defines the data (DX, DY) at top level so the streaming CV eval below can reuse
# it in the SAME warm session.
const FIT_APP = raw"""using WGLMakie, Bonito, Statistics, LinearAlgebra, Random
Random.seed!(42)
truef(x) = sin(2π*x) + 0.45*sin(5π*x)
const DX = sort(rand(90))
const DY = truef.(DX) .+ 0.16 .* randn(90)

App() do session
    deg = Bonito.Slider(1:20; value = 4)
    xg  = collect(range(0, 1; length = 400))
    fit = map(deg.value) do d
        V = [x^p for x in DX, p in 0:d]
        coef = V \ DY
        yg = [sum(coef[p+1]*x^p for p in 0:d) for x in xg]
        rmse = sqrt(mean((V*coef .- DY) .^ 2))
        (; yg, rmse)
    end
    fig = Figure(; size = (1120, 520), backgroundcolor = :white)
    ax = Axis(fig[1, 1]; title = "Least-squares polynomial fit", titlesize = 22,
              xlabel = "x", ylabel = "y")
    lines!(ax, xg, truef.(xg); color = (:seagreen, 0.5), linewidth = 2, linestyle = :dash, label = "truth")
    scatter!(ax, DX, DY; color = (:steelblue, 0.55), markersize = 11, label = "samples")
    lines!(ax, xg, map(f -> f.yg, fit); color = :crimson, linewidth = 3.5, label = "fit")
    # top-left: the emptiest corner at every degree, and it never clips against
    # the embed's right edge the way a right-anchored legend does.
    axislegend(ax; position = :lt)
    ylims!(ax, -2.2, 1.7)
    header = DOM.div(
        DOM.span("polynomial degree"; style = "color:#333; font:600 15px sans-serif;"),
        deg,
        DOM.span(map(d -> "degree $d", deg.value); style = "color:#c0392b; font:700 15px monospace; margin-left:6px;"),
        DOM.span(map(f -> "RMSE $(round(f.rmse; digits = 3))", fit); style = "color:#555; font:600 15px monospace; margin-left:18px;");
        style = "display:flex; align-items:center; gap:12px; padding:12px 18px;")
    DOM.div(header, fig; style = "background:white; padding:6px; border-radius:10px;")
end"""

# Streaming k-fold cross-validation over the SAME data (reuses DX/DY): the
# held-out error per degree — a U-shape whose minimum is the "right" degree.
const CV_CODE = raw"""using Random, Statistics, LinearAlgebra
perm = shuffle(Random.MersenneTwister(1), 1:length(DX)); folds = 5
println("5-fold cross-validation — mean held-out RMSE per polynomial degree:")
best = (deg = 0, err = Inf)
for d in 1:16
    errs = Float64[]
    for f in 1:folds
        te = perm[f:folds:end]; tr = setdiff(1:length(DX), te)
        V  = [DX[i]^p for i in tr, p in 0:d];  coef = V \ DY[tr]
        Vt = [DX[i]^p for i in te, p in 0:d]
        push!(errs, sqrt(mean((Vt*coef .- DY[te]) .^ 2)))
    end
    e = mean(errs); e < best.err && (best = (deg = d, err = e))
    println("degree ", lpad(d, 2), "   CV-RMSE = ", round(e; digits = 4))
    sleep(0.4)
end
println("→ best generalizing degree: ", best.deg)
best.deg"""

const CV_MARK = "CV-RMSE"
mock_streaming_js() = """[...document.querySelectorAll('.bt-tool-msg')].filter(c =>
    c.offsetParent && (c.querySelector('.bt-tool-status')?.textContent || '') !== 'completed' &&
    /$(CV_MARK)/.test(c.innerText)).pop()"""
mock_completed_js() = """[...document.querySelectorAll('.bt-tool-msg')].filter(c =>
    c.offsetParent && c.querySelector('.bt-tool-status')?.textContent === 'completed' &&
    /$(CV_MARK)/.test(c.innerText)).pop()"""

function make_agent()
    n = Ref(0)
    return function (_prompt)
        n[] += 1
        n[] == 1 ?
            Any[TK.text("Here's an interactive least-squares curve-fitting dashboard — a " *
                        "polynomial fit to noisy samples with a degree slider."),
                TK.bt_eval(FIT_APP; env_path = MOCK_EVAL_ENV, id = "fit-app")] :
            Any[TK.text("Which degree actually generalizes? Cross-validating, streaming the held-out error:"),
                TK.bt_eval(CV_CODE; env_path = MOCK_EVAL_ENV, id = "cv-sweep")]
    end
end

# ── real-input camera helpers (STRICT: trusted events only) ────────────────────
mock_app_up_js() = """[...document.querySelectorAll('.bt-embed')].some(e =>
    e.querySelector('canvas') && e.querySelector('input[type=range]'))"""
embed_slider() = "document.querySelector('.bt-embed input[type=range]')"

# The dashboard eval pill, identified UNIQUELY by having both a canvas AND the
# degree slider — the second eval (cross-validation) returns a scalar `11`, so a
# plain `.filter(canvas)` would ambiguously match it and detach the wrong card
# (that was the "detaches an App that just shows 11" bug). Requiring the slider
# pins it to the plot.
fit_pill_js() = """[...document.querySelectorAll('.bt-tool-msg')].filter(e =>
    e.offsetParent && e.querySelector('canvas') && e.querySelector('input[type=range]'))[0]"""
fit_detach_js() = """(() => {
    const pill = $(fit_pill_js());
    const b = pill && pill.querySelector('.bt-tool-detach');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
})()"""

# Real wheel scroll: park the cursor in the transcript gutter, then dispatch
# genuine WheelEvents. `dy>0` scrolls DOWN (content up).
function wheel!(s, ctx, dy)
    cursor_to_transcript!(s, ctx)
    ECT.wheel(ctx, dy; steps = 8, step_sleep = 0.05)
    sleep(0.2)
end

# Wheel until `js_el`'s centre sits at viewport fraction `at`. READS the rect via
# el_offscreen (layout read only); ACTS only via real wheel. Stops the moment a
# wheel stops moving the element — i.e. the scroller hit its top/bottom limit and
# the target simply cannot reach `at`. Without this the loop wheels against a
# dead stop for all `maxticks` (~0.6s each), which is exactly the multi-second
# "frozen card" dead time that used to sit between the stream and the detach.
function wheel_into_view!(s, ctx, js_el; at = 0.42, maxticks = 20)
    prev = nothing
    for _ in 1:maxticks
        off = el_offscreen(s, js_el; at)
        off === nothing && return false
        off == 0 && return true
        prev !== nothing && abs(off - prev) < 2.0 && return false   # at a scroll limit
        prev = off
        wheel!(s, ctx, clamp(off, -320.0, 320.0))
    end
    el_offscreen(s, js_el; at) == 0
end

shot(s, name) = (mkpath(SHOTDIR); TK.screenshot(s, joinpath(SHOTDIR, name)); @info "shot" name)

# ── the recorded tour ──────────────────────────────────────────────────────────
function tour_mock(s, ctx)
    T0 = time(); mark(n) = @info "tour" step = n at = round(time() - T0; digits = 1)
    # 1 ─ OPEN ON THE DASHBOARD. Wheel it so the DEGREE SLIDER sits just below the
    #     composer — the slider AND the whole plot are then in frame, so the
    #     viewer sees the control that drives the fit and the fit itself.
    TK.wait_for(s, "live slider", "$(embed_slider()) && $(embed_slider()).offsetParent"; timeout = 30)
    wheel_into_view!(s, ctx, embed_slider(); at = 0.16)
    sleep(1.4); mark("1 framed")

    # 2 ─ DRAG the degree slider through the bias/variance story, RMSE updating
    #     live: underfit (deg 1, a straight line) → a clean fit (deg 6) → overfit
    #     (deg 20, chasing the noise) → back to the clean fit. Trusted thumb drag;
    #     the fit recomputes in the worker on release.
    for frac in (0.0, 0.26, 1.0, 0.26)
        ECT.steer_slider(ctx, ".bt-embed input[type=range]", frac; duration = 1.2)
        sleep(1.1)
    end
    sleep(0.6); mark("2 swept")

    # 3 ─ a LIVE bt_julia_eval: stream the cross-validation sweep + three-state
    #     section collapse.
    TK.send_message(s, "Cross-validate the fit and stream the held-out error per degree.")
    TK.wait_for(s, "eval streaming", "!!($(mock_streaming_js()))"; timeout = 90)
    wheel_into_view!(s, ctx, mock_streaming_js(); at = 0.5)
    mark("3 streaming"); sleep(6.5)
    TK.wait_for(s, "eval completed", "!!($(mock_completed_js()))"; timeout = 40)
    sleep(1.2); mark("3 completed")
    code = "($(mock_completed_js()))?.querySelector('.bt-subsection')"
    wheel_into_view!(s, ctx, "$code?.querySelector('.bt-subsection-summary')"; at = 0.35)
    sleep(0.6)
    for st in ["summary:false", "full:true", "summary:true"]
        ECT.real_click(ctx, ECT.JS(el_center_js("$code?.querySelector('.bt-subsection-summary')")))
        TK.wait_for(s, "collapse → $st", """(() => { const d = $code;
            return d && (d.dataset.state + ':' + d.hasAttribute('open')) === $(repr(st)); })()"""; timeout = 8)
        sleep(1.0)
    end
    sleep(0.5); mark("3 collapsed")

    # 4 ─ detach the dashboard into the workspace and dock it beside the chat.
    #     Wheel the app back into view, then a TRUSTED click on its ⤢ button.
    #     Target the DASHBOARD pill specifically (canvas + slider) so we never
    #     grab the cross-validation card, whose result is a bare scalar.
    wheel_into_view!(s, ctx, "$(fit_pill_js())?.querySelector('.bt-tool-detach')"; at = 0.3)
    sleep(0.6); mark("4 detach-framed")
    ECT.real_click(ctx, ECT.JS(fit_detach_js()))
    TK.wait_for(s, "floating app window",
        "[...document.querySelectorAll('.bw-ws-float')].some(f => f.offsetParent && f.querySelector('canvas'))";
        timeout = 20)
    sleep(1.0); mark("4 floating")
    ECT.drag(ctx, ECT.JS(floattitle("App")),
             [ECT.JS(groupbody("Chat"; rel = (0.7, 0.5))),
              ECT.JS(groupbody("Chat"; rel = (0.94, 0.5)))];
             grab = 0.4, move = 1.1)
    sleep(1.4); mark("4 docked")

    # 5 ─ docked + live: one more drag in the plotpane.
    TK.wait_for(s, "docked slider",
        "[...document.querySelectorAll('input[type=range]')].some(e => e.offsetParent)"; timeout = 15)
    ECT.steer_slider(ctx, "input[type=range]", 0.85; duration = 1.2)
    sleep(1.0)
    ECT.steer_slider(ctx, "input[type=range]", 0.2; duration = 1.2)
    sleep(1.2); mark("5 docked-steer done")
end

function record_mock(; outpath = joinpath(@__DIR__, "walkthrough.mp4"))
    s = TK.dev_server(agent = make_agent())         # mock = true (default)
    try
        TK.open_browser(s)
        TK.set_window_size(s, 1600, 900)
        chatdir = mktempdir(; prefix = "bt-reg-")
        TK.new_chat(s; cwd = chatdir, title = MOCK_CHAT_TITLE)
        # SETUP (off camera): build the dashboard, wait for it to render.
        TK.send_message(s, "Build me an interactive least-squares curve-fitting dashboard with a degree slider.")
        TK.wait_for(s, "app mounts live", mock_app_up_js(); timeout = 240)
        sleep(4)
        ctx = s.browser[]
        ECT.install_error_sink(ctx)
        ECT.install_cursor(ctx; start = (800, 780))
        sleep(1.0)
        ECT.record_video(() -> tour_mock(s, ctx), ctx, outpath; fps = 30)
        errs = TK.js_errors(s)
        isempty(errs) || @warn "JS errors during walkthrough" errs
        @info "wrote $outpath"
    finally
        close(s)
    end
    return outpath
end

abspath(PROGRAM_FILE) == (@__FILE__) && record_mock()
