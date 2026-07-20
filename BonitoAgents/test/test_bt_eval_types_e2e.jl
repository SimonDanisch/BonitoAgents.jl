# Full-stack e2e for bt_julia_eval's RESULT rendering across output types, exactly
# as a user hits it: a real dev_server + a real electron browser driven by URL.
# The scripted MockAgent emits a `bt_eval` per case (each runs through the REAL
# BonitoMCP.julia_eval_handler → real worker → real ACP wire → the chat's
# bt_julia_eval render path); we assert ONLY on the rendered DOM. NO worker is
# hand-spawned, no internal is called directly — the chat does all the work.
#
# Covers (40+ cases): strings/numbers/bigint, collections (vector, matrix, dict,
# namedtuple, tuple, set, range, pair), scalars (bool, char, symbol, complex,
# rational, regex, function, missing, NaN/Inf), unicode/multiline strings, and
# rich MIME (Markdown → <h1>, color/gray images + SVG → a LOADED <img> served
# over the asset proxy, text/latex → KaTeX, a DataFrame → <table>, a Tables.jl
# table, a Bonito DOM node, raw Base.HTML → real elements). Result assertions
# scope to the `.bt-embed` result mount so the CODE ECHO can't satisfy them.
# Plus: HTML-escaping (a returned string with <script>/<b> stays TEXT), ANSI in
# a returned string (RichText), colored stdout in the OUTPUT section (Pkg.status
# / printstyled), @warn → stderr capture, `nothing` return (no result box),
# stdout+result section separation, worker session state across evals, the
# don't-crash-the-display guards (huge stdout / string / array), a value whose
# `show` throws (inline error, tool completes), and error rendering. The eval
# worker runs in the committed `test/evalenv` project (dev Bonito +
# DataFrames/Colors/ImageShow/Tables), warmed in runtests.jl.

using Test, JSON
# TestKit / TK come from the enclosing @testitem (setup=[SharedServer]) so the
# dispatcher + SERVER_CONTEXT are the shared, live ones. Only the DSL names are
# pulled in here.
using .TestKit: text, bt_eval, end_turn

const EVALENV  = abspath(joinpath(@__DIR__, "evalenv"))
const SHOT_DIR = joinpath(tempdir(), "bt-eval-types")
mkpath(SHOT_DIR)

# ── DOM predicate builders (scoped to one tool bubble by its msg id) ───────────
# The RESULT fragment mounts inside `.bt-embed` (wrap_for_detach); the Code echo
# renders in Monaco and the captured stdout in the Output section. Whole-card
# `innerText` matches the CODE ECHO too — e.g. the marker in `"STRINGMARK"` is
# right there in the Code section — so a result that never renders would still
# pass. Result assertions therefore scope to `.bt-embed`; Output assertions
# require the match OUTSIDE `.bt-embed`.
jsel(id) = ".bt-tool-msg[data-msg-id*=\"$id\"]"
p_text(id, marker)      = "(() => { const e = document.querySelector('$(jsel(id))'); return !!(e && e.innerText && e.innerText.includes($(JSON.json(marker)))); })()"
p_result(id, marker)    = "(() => { const e = document.querySelector('$(jsel(id)) .bt-embed'); return !!(e && e.innerText && e.innerText.includes($(JSON.json(marker)))); })()"
p_result_el(id, css)    = "(() => { const e = document.querySelector('$(jsel(id)) .bt-embed'); return !!(e && e.querySelector($(JSON.json(css)))); })()"
p_result_both(id, css, marker) = "(() => { const e = document.querySelector('$(jsel(id)) .bt-embed'); return !!(e && e.querySelector($(JSON.json(css))) && e.innerText.includes($(JSON.json(marker)))); })()"
# A completed eval whose value is `nothing` mounts NO result box at all (the
# handler ships an explicitly empty final block; the chat skips the mount).
# Requiring `.bt-eval-body` pins the assert to the MOUNTED body — without it the
# predicate would pass trivially before the lazy body renders (sections render
# in one fragment, so body-present ⇒ embed decision already made).
p_no_result(id)         = "(() => { const e = document.querySelector('$(jsel(id))'); return !!(e && e.querySelector('.bt-eval-body') && !e.querySelector('.bt-embed')); })()"
# The rendered <img> actually LOADED — its bytes are served through the eval
# bridge's asset proxy, so `naturalWidth > 0` proves the asset round-trip, not
# just that an <img> tag with a dead src exists.
p_img_loaded(id)        = "(() => { const i = document.querySelector('$(jsel(id)) .bt-embed img'); return !!(i && i.naturalWidth > 0 && i.naturalHeight > 0); })()"
# Colored output: ANSI renders as CLASS-based spans (`sgr31` = red, `sgr1` =
# bold, …) via ANSIColoredPrinters, NOT inline styles. The stdout variant also
# pins the span to the Output section (NOT inside the result mount).
p_out_colored(id, marker) = "(() => { const e = document.querySelector('$(jsel(id))'); if (!e || !e.innerText.includes($(JSON.json(marker)))) return false; return [...e.querySelectorAll('span[class*=\"sgr\"]')].some(s => !s.closest('.bt-embed')); })()"
p_result_colored(id, marker) = "(() => { const e = document.querySelector('$(jsel(id)) .bt-embed'); return !!(e && e.innerText.includes($(JSON.json(marker))) && e.querySelector('span[class*=\"sgr\"]')); })()"
# Output-section text: the marker must appear OUTSIDE the result mount.
p_output(id, marker)    = "(() => { const e = document.querySelector('$(jsel(id))'); if (!e) return false; const em = e.querySelector('.bt-embed'); const cut = em ? em.innerText : ''; return e.innerText.includes($(JSON.json(marker))) && (!em || !cut.includes($(JSON.json(marker)))); })()"

# (id, eval-code, DOM-predicate). Markers are unique so a stray match can't
# pass; where a marker would also appear literally in the CODE ECHO, either the
# predicate scopes to `.bt-embed` or the eval code builds the marker by
# concatenation ("FOO" * "MARK") so only the RESULT can contain the joined text.
const CASES = [
    # ── plain values (text repr, asserted in the RESULT mount) ────────────────
    ("ty-string",     "\"STRINGMARK_7f3\"",                          p_result("ty-string", "STRINGMARK_7f3")),
    ("ty-int",        "1234567",                                     p_result("ty-int", "1234567")),
    ("ty-float",      "3.14159265",                                  p_result("ty-float", "3.14159")),
    ("ty-bigint",     "factorial(big(25))",                          p_result("ty-bigint", "15511210043330985984000000")),
    ("ty-vector",     "[11, 22, 33]",                                p_result("ty-vector", "22")),
    ("ty-matrix",     "[1.5 2.5; 3.5 4.5]",                          p_result("ty-matrix", "3.5")),
    ("ty-dict",       "Dict(:alphakey => 99887)",                    p_result("ty-dict", "alphakey")),
    ("ty-namedtuple", "(foomark = 42, bar = \"bee\")",               p_result("ty-namedtuple", "foomark")),
    ("ty-tuple",      "(1, \"twomark\", 3.0)",                       p_result("ty-tuple", "twomark")),
    ("ty-range",      "1:9999",                                      p_result("ty-range", "9999")),
    ("ty-set",        "Set([771, 882, 993])",                        p_result("ty-set", "882")),
    ("ty-complex",    "3 + 4im",                                     p_result("ty-complex", "4im")),
    ("ty-rational",   "22 // 7",                                     p_result("ty-rational", "22//7")),
    ("ty-symbol",     ":sym_marker_z",                               p_result("ty-symbol", "sym_marker_z")),
    ("ty-bool",       "true",                                        p_result("ty-bool", "true")),
    ("ty-char",       "'Q'",                                         p_result("ty-char", "Q")),
    ("ty-regex",      "r\"abc_marker+\"",                            p_result("ty-regex", "abc_marker")),
    ("ty-pair",       ":pk => 5150",                                 p_result("ty-pair", "5150")),
    ("ty-function",   "sqrt",                                        p_result("ty-function", "sqrt")),
    ("ty-missing",    "missing",                                     p_result("ty-missing", "missing")),
    ("ty-naninf",     "[NaN, Inf, -Inf]",                            p_result("ty-naninf", "NaN")),
    ("ty-unicode",    "\"Ünïcödé → 🚀 \" * \"EMOJIMARK\"",           p_result("ty-unicode", "🚀 EMOJIMARK")),
    ("ty-multiline",  "join([\"first\" * \"LINEMARK_A\", \"second\" * \"LINEMARK_B\"], \"\\n\")",
                      p_result("ty-multiline", "secondLINEMARK_B")),
    # ── rich MIME (markdown / image / svg / latex / table / dom / raw html) ───
    ("ty-markdown",   "using Markdown; md\"# MDHEADMARK\n\nbody text\"",                         p_result_both("ty-markdown", "h1", "MDHEADMARK")),
    ("ty-image",      "using Colors, ImageShow; fill(RGB{Colors.N0f8}(1.0, 0.0, 0.0), 8, 8)",    p_img_loaded("ty-image")),
    ("ty-gray",       "using Colors, ImageShow; Gray{Colors.N0f8}.(reshape(range(0,1,length=64), 8, 8))", p_img_loaded("ty-gray")),
    ("ty-svg",        "struct SvgT_ end; " *
                      "Base.show(io::IO, ::MIME\"image/svg+xml\", ::SvgT_) = " *
                      "print(io, \"<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' fill='red'/></svg>\"); " *
                      "SvgT_()",                                     p_img_loaded("ty-svg")),
    ("ty-latex",      "struct TexT_ end; " *
                      "Base.show(io::IO, ::MIME\"text/latex\", ::TexT_) = print(io, \"\\\\frac{1}{2}\"); " *
                      "TexT_()",                                     p_result_el("ty-latex", ".katex-container")),
    ("ty-dataframe",  "using DataFrames; DataFrame(colmark = [1,2,3], who = [\"a\",\"b\",\"c\"])", p_result_both("ty-dataframe", "table", "colmark")),
    ("ty-table",      "using Tables; Tables.columntable((tabmark = [10,20], q = [30,40]))",       p_result("ty-table", "tabmark")),
    ("ty-dom",        "using Bonito; DOM.div(\"DOMMARKER\"; class = \"t-eval-dom\")",             p_result_both("ty-dom", ".t-eval-dom", "DOMMARKER")),
    # Raw `Base.HTML` must pass through as REAL elements (regression for the
    # session_dom/App(value) top-level wrap in Bonito).
    ("ty-rawhtml",    "Base.HTML(\"<b class='raw-html-b'>RAW\" * \"HTMLMARK</b>\")",
                      p_result_both("ty-rawhtml", "b.raw-html-b", "RAWHTMLMARK")),
    # ── escaping: a returned STRING with markup renders as TEXT, not elements ──
    ("ty-xss",        "\"<script>window.XSSPWNED = true<\" * \"/script><b id='xss-bold'>XSST\" * \"EXTMARK</b>\"",
                      "(() => { const e = document.querySelector('$(jsel("ty-xss")) .bt-embed'); " *
                      "return !!(e && e.innerText.includes('XSSTEXTMARK') " *
                      "&& !document.querySelector('#xss-bold') && !window.XSSPWNED); })()"),
    # ── ANSI in a RETURNED string (RichText path, distinct from stdout) ───────
    ("ty-ansiret",    "\"\\e[31mANSI\" * \"RETMARK\\e[0m plain tail\"",  p_result_colored("ty-ansiret", "ANSIRETMARK")),
    # ── session STATE persists across evals in the same chat ──────────────────
    ("st-state1",     "EVALSTATE_COUNTER_X = 424241; nothing",       p_no_result("st-state1")),
    ("st-state2",     "EVALSTATE_COUNTER_X + 1",                     p_result("st-state2", "424242")),
    # ── nothing return: completed, NO result box mounted ──────────────────────
    ("ev-nothing",    "40 + 2; nothing",                             p_no_result("ev-nothing")),
    # ── stdout AND result in one eval land in their OWN sections ──────────────
    ("ev-stdout-result", "println(\"OUT\" * \"MARK_D1\"); \"RES\" * \"MARK_D2\"",
                      "(() => { return $(p_output("ev-stdout-result", "OUTMARK_D1")) && $(p_result("ev-stdout-result", "RESMARK_D2")); })()"),
    # ── colored stdout (in the Output section, NOT the result mount) ──────────
    ("st-pkg",        "using Pkg; Pkg.status(); nothing",                                         p_out_colored("st-pkg", "Bonito")),
    ("st-printstyled","printstyled(\"COLORMARK line\\n\"; color = :red, bold = true); nothing",   p_out_colored("st-printstyled", "COLORMARK")),
    # ── logging goes to stderr and still shows up in Output ───────────────────
    ("st-warn",       "@warn(\"WARN\" * \"LOGMARK_w1\"); nothing",   p_output("st-warn", "WARNLOGMARK_w1")),
    # ── don't crash the display on huge output ────────────────────────────────
    ("sf-stdout",     "for i in 1:300_000; println(\"LINE \", i, \" filler filler filler\"); end; nothing", p_text("sf-stdout", "truncated")),
    ("sf-string",     "\"Z\"^2_000_000",                            p_result("sf-string", "truncated")),
    ("sf-array",      "rand(4000, 4000)",                           p_result("sf-array", "4000×4000")),
    # ── a value whose `show` THROWS renders an inline error, tool completes ───
    ("sf-showerr",    "struct BoomT_ end; " *
                      "Base.show(io::IO, ::MIME\"text/plain\", ::BoomT_) = error(\"SHOW\" * \"BOOMMARK\"); " *
                      "BoomT_()",                                    p_result("sf-showerr", "SHOWBOOMMARK")),
    # ── errors render ─────────────────────────────────────────────────────────
    ("er-throw",      "error(\"BOOMMARK custom error\")",            p_text("er-throw", "BOOMMARK")),
    ("er-bounds",     "[1, 2, 3][99]",                              p_text("er-bounds", "BoundsError")),
]

# One eval per turn — exactly how a user works (one prompt → one eval), and the
# only flow the harness/chat supports cleanly (multiple tool_calls in a single
# mock turn don't all render). The user message IS the case id; the scripted agent
# looks it up and emits that case's bt_eval. One chat → one reused eval worker.
const BY_ID = Dict(id => code for (id, code, _) in CASES)

@testset "bt_julia_eval renders $(length(CASES)) output types / stdout / safety / errors (live chat)" begin
    # The one per-worker shared server + browser (see SharedServer). We only swap
    # in this suite's scenario agent and open a fresh chat on it — never close it.
    s = SharedServer.server()
    s.agent_fn[] = msg -> begin
        code = get(BY_ID, String(msg), nothing)
        code === nothing ? Any[text("unknown case"), end_turn()] :
            Any[bt_eval(code; env_path = EVALENV, id = String(msg)), end_turn()]
    end
    begin
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)
        # Fresh evalenv session: the eval-session pool is PROCESS-GLOBAL and the
        # eval bridge is keyed by project_id, so a worker left by an earlier chat
        # (this item's OR a prior e2e item's) is registered under a DIFFERENT
        # project_id — its live-render bridge would miss and every embed degrades
        # to "worker gone". Drop it so THIS chat's first eval dials a fresh bridge
        # under THIS project_id (`ensure_eval_dialed!` won't re-dial a live worker).

        # Per case: send the prompt, wait for ITS tool to reach a terminal status
        # (the first eval pays worker-spawn + first `using DataFrames`/dev-Bonito
        # compile), expand the body (lazy-mounted on header click), assert the
        # rendered DOM. Errors land as status "failed" (mock maps is_error); both
        # terminal.
        @testset "$id" for (i, (id, _, predicate)) in enumerate(CASES)
            TK.send_message(s, id)
            tmo = i == 1 ? 240 : 60
            @test TK.wait_for(s, "$id terminal",
                "['completed','failed'].includes(document.querySelector('$(jsel(id)) .bt-tool-status')?.textContent)";
                timeout = tmo) == true
            TK.click(s, "$(jsel(id)) .bt-tool-header")
            # wait_for THROWS on timeout — catch it so the failure dump below
            # actually runs (an exception would skip straight past it).
            ok = try
                TK.wait_for(s, "$id rendered", predicate; timeout = 40) == true
            catch
                false
            end
            ok || @info "case body dump" id body = TK.eval_js(s,
                "document.querySelector('$(jsel(id))')?.innerText?.slice(0,400) ?? '(none)'") embed = TK.eval_js(s,
                "document.querySelector('$(jsel(id)) .bt-embed')?.innerText?.slice(0,200) ?? '(no embed)'")
            @test ok
        end

        TK.screenshot(s, joinpath(SHOT_DIR, "bt_eval-types.png"))
    end
end
