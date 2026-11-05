# Homepage demo: scripted conversation, real Julia execution and browser input.
# Build the curve-fitting app before recording, then show its slider, streaming
# cross-validation, code folding and docking. No agent credits are used.
#
# Run in the development environment: julia --project examples/walkthrough_mock.jl
# Output: examples/workflow-raw.mp4. Set BT_WALKTHROUGH_EVAL_ENV to the eval project.

isdefined(@__MODULE__, :tour) || include(joinpath(@__DIR__, "walkthrough.jl"))

const MOCK_EVAL_ENV  = get(ENV, "BT_WALKTHROUGH_EVAL_ENV", "/sim/Programmieren/AgentsDev")
const MOCK_CHAT_TITLE = "CurveFitting"
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
    fig = Figure(; size = (960, 440), backgroundcolor = :white)
    ax = Axis(fig[1, 1]; title = "Polynomial fit", titlesize = 20,
              xlabel = "x", ylabel = "y")
    lines!(ax, xg, truef.(xg); color = (:seagreen, 0.5), linewidth = 2, linestyle = :dash, label = "truth")
    scatter!(ax, DX, DY; color = (:steelblue, 0.55), markersize = 11, label = "samples")
    lines!(ax, xg, map(f -> f.yg, fit); color = :crimson, linewidth = 3.5, label = "fit")
    # top-left: the emptiest corner at every degree, and it never clips against
    # the embed's right edge the way a right-anchored legend does.
    axislegend(ax; position = :lt)
    ylims!(ax, -2.2, 1.7)
    styles = Styles(
        CSS(".demo-fit", "width" => "100%", "min-width" => "0",
            "background" => "white", "border-radius" => "8px"),
        CSS(".demo-fit-header", "display" => "flex", "flex-wrap" => "wrap",
            "align-items" => "center", "gap" => "12px", "padding" => "12px 18px",
            "font" => "600 14px sans-serif", "color" => "#333"),
        CSS(".demo-fit-value", "color" => "#b83732"),
        CSS(".demo-fit-error", "color" => "#555"),
        CSS(".demo-fit-plot", "width" => "100%", "height" => "420px", "min-width" => "0"),
    )
    header = DOM.div(
        DOM.span("polynomial degree"), deg,
        DOM.span(map(d -> "degree $d", deg.value); class = "demo-fit-value"),
        DOM.span(map(f -> "RMSE $(round(f.rmse; digits = 3))", fit); class = "demo-fit-error");
        class = "demo-fit-header")
    plot = DOM.div(WGLMakie.WithConfig(fig; resize_to = :parent); class = "demo-fit-plot")
    DOM.div(styles, header, plot; class = "demo-fit")

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
    c.checkVisibility() && (c.querySelector('.bt-tool-status')?.textContent || '') !== 'completed' &&
    /$(CV_MARK)/.test(c.innerText)).pop()"""
mock_completed_js() = """[...document.querySelectorAll('.bt-tool-msg')].filter(c =>
    c.checkVisibility() && c.querySelector('.bt-tool-status')?.textContent === 'completed' &&
    /$(CV_MARK)/.test(c.innerText)).pop()"""

function make_agent()
    n = Ref(0)
    take = string(BT.uuid4())
    return function (_prompt)
        n[] += 1
        n[] == 1 ?
            Any[TK.text("Here's an interactive least-squares curve-fitting dashboard — a " *
                        "polynomial fit to noisy samples with a degree slider."),
                TK.bt_eval(FIT_APP; env_path = MOCK_EVAL_ENV, id = "fit-$take", timeout = 0)] :
            Any[TK.text("Which degree actually generalizes? Cross-validating, streaming the held-out error:"),
                TK.bt_eval(CV_CODE; env_path = MOCK_EVAL_ENV, id = "cv-$take", timeout = 0)]
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
    e.checkVisibility() && e.querySelector('canvas') && e.querySelector('input[type=range]'))[0]"""
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
    gutter = TK.eval_js(s, """(() => {
        const r = [...document.querySelectorAll('.bt-messages')].find(e => e.checkVisibility()).getBoundingClientRect();
        return [r.x + 6, r.y + r.height / 2];
    })()""")
    ECT.move_to(ctx, (Float64(gutter[1]), Float64(gutter[2])); duration = 0.2)
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
    # Keep the slider and the whole plot in frame.
    TK.wait_for(s, "live slider", "$(embed_slider()) && $(embed_slider()).checkVisibility()"; timeout = 30)
    wheel_into_view!(s, ctx, embed_slider(); at = 0.16)
    sleep(0.8); mark("1 framed")

    # Compare underfitting and overfitting before checking the held-out error.
    for frac in (0.0, 0.26, 0.85)
        ECT.steer_slider(ctx, ".bt-embed input[type=range]", frac; duration = 0.8)
        sleep(0.8)
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
    for st in ["full:true", "full:false", "summary:true"]
        ECT.real_click(ctx, ECT.JS(el_center_js("$code?.querySelector('.bt-subsection-summary')")))
        TK.wait_for(s, "collapse → $st", """(() => { const d = $code;
            return d && (d.dataset.state + ':' + d.hasAttribute('open')) === $(repr(st)); })()"""; timeout = 8)
        sleep(1.0)
    end
    sleep(0.5); mark("3 collapsed")

    # Detach the live app, not the cross-validation card (which returns a scalar).
    wheel_into_view!(s, ctx, "$(fit_pill_js())?.querySelector('.bt-tool-detach')"; at = 0.3)
    sleep(0.6); mark("4 detach-framed")
    ECT.real_click(ctx, ECT.JS(fit_detach_js()))
    TK.wait_for(s, "floating app window",
        "[...document.querySelectorAll('.bw-ws-float')].some(f => f.checkVisibility() && f.querySelector('canvas'))";
        timeout = 20)
    sleep(1.0); mark("4 floating")
    dock_float!(s, ctx) || error("the app did not dock beside the chat")
    sleep(1.4); mark("4 docked")

    # 5 ─ docked + live: one more drag in the plotpane.
    TK.wait_for(s, "docked slider",
        "[...document.querySelectorAll('input[type=range]')].some(e => e.checkVisibility())"; timeout = 15)
    ECT.steer_slider(ctx, "input[type=range]", 0.85; duration = 1.2)
    sleep(1.0)
    ECT.steer_slider(ctx, "input[type=range]", 0.53; duration = 1.2)
    sleep(1.2); mark("5 docked-steer done")
end

function record_mock(; outpath = joinpath(@__DIR__, "workflow-raw.mp4"))
    s = TK.dev_server(agent = make_agent(), name = "Studio")         # mock = true (default)
    try
        TK.open_browser(s)
        TK.set_window_size(s, 1440, 900)
        chatdir = joinpath(mktempdir(; prefix = "bonito-demo-"), "CurveFitting")
        mkpath(chatdir)
        TK.new_chat(s; cwd = chatdir, title = MOCK_CHAT_TITLE)
        # SETUP (off camera): build the dashboard, wait for it to render.
        TK.send_message(s, "Build me an interactive least-squares curve-fitting dashboard with a degree slider.")
        TK.wait_for(s, "app mounts live", mock_app_up_js(); timeout = 240)
        TK.wait_for(s, "app eval completed",
            "!!($(fit_pill_js())) && $(fit_pill_js()).querySelector('.bt-tool-status')?.textContent === 'completed'";
            timeout = 90)
        sleep(1)
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
