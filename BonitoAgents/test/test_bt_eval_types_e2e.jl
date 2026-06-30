# Full-stack e2e for bt_julia_eval's RESULT rendering across output types, exactly
# as a user hits it: a real dev_server + a real electron browser driven by URL.
# The scripted MockAgent emits a `bt_eval` per case (each runs through the REAL
# BonitoMCP.julia_eval_handler → real worker → real ACP wire → the chat's
# bt_julia_eval render path); we assert ONLY on the rendered DOM. NO worker is
# hand-spawned, no internal is called directly — the chat does all the work.
#
# Covers (≥20 output types): strings/numbers/bigint, collections (vector, matrix,
# dict, namedtuple, tuple, set, range, pair), scalars (bool, char, symbol, complex,
# rational, regex, function), and rich MIME (Markdown → <h1>, a color image →
# <img>, a DataFrame → <table>, a Tables.jl table, a Bonito DOM node). Plus:
# colored stdout (Pkg.status / printstyled → colored terminal block), and the
# don't-crash-the-display guards (huge stdout, huge string return, huge array) and
# error rendering. The eval worker runs in the committed `test/evalenv` project
# (dev Bonito + DataFrames/Colors/ImageShow/Tables), warmed in runtests.jl.

using Test, JSON
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit
const TK = TestKit
using .TestKit: text, bt_eval, end_turn

const EVALENV  = abspath(joinpath(@__DIR__, "evalenv"))
const SHOT_DIR = joinpath(tempdir(), "bt-eval-types")
mkpath(SHOT_DIR)

# ── DOM predicate builders (scoped to one tool bubble by its msg id) ───────────
jsel(id) = ".bt-tool-msg[data-msg-id*=\"$id\"]"
p_text(id, marker)      = "(() => { const e = document.querySelector('$(jsel(id))'); return !!(e && e.innerText && e.innerText.includes($(JSON.json(marker)))); })()"
p_el(id, css)           = "(() => { const e = document.querySelector('$(jsel(id))'); return !!(e && e.querySelector($(JSON.json(css)))); })()"
p_both(id, css, marker) = "(() => { const e = document.querySelector('$(jsel(id))'); return !!(e && e.querySelector($(JSON.json(css))) && e.innerText.includes($(JSON.json(marker)))); })()"
# Colored stdout: the tool body has the marker AND an ANSI-derived colored span.
# `Bonito.RichText` (via ANSIColoredPrinters) renders ANSI as CLASS-based spans
# (`sgr31` = red, `sgr1` = bold, …) inside `.terminal-output`, NOT inline styles —
# a `span[class*="sgr"]` proves the stdout color survived to the DOM.
p_colored(id, marker)   = "(() => { const e = document.querySelector('$(jsel(id))'); return !!(e && e.innerText.includes($(JSON.json(marker))) && e.querySelector('span[class*=\"sgr\"]')); })()"

# (id, eval-code, DOM-predicate). Markers are unique so a stray match can't pass.
const CASES = [
    # ── plain values (text repr) ──────────────────────────────────────────────
    ("ty-string",     "\"STRINGMARK_7f3\"",                          p_text("ty-string", "STRINGMARK_7f3")),
    ("ty-int",        "1234567",                                     p_text("ty-int", "1234567")),
    ("ty-float",      "3.14159265",                                  p_text("ty-float", "3.14159")),
    ("ty-bigint",     "factorial(big(25))",                          p_text("ty-bigint", "15511210043330985984000000")),
    ("ty-vector",     "[11, 22, 33]",                                p_text("ty-vector", "22")),
    ("ty-matrix",     "[1.5 2.5; 3.5 4.5]",                          p_text("ty-matrix", "3.5")),
    ("ty-dict",       "Dict(:alphakey => 99887)",                    p_text("ty-dict", "alphakey")),
    ("ty-namedtuple", "(foomark = 42, bar = \"bee\")",               p_text("ty-namedtuple", "foomark")),
    ("ty-tuple",      "(1, \"twomark\", 3.0)",                       p_text("ty-tuple", "twomark")),
    ("ty-range",      "1:9999",                                      p_text("ty-range", "9999")),
    ("ty-set",        "Set([771, 882, 993])",                        p_text("ty-set", "882")),
    ("ty-complex",    "3 + 4im",                                     p_text("ty-complex", "4im")),
    ("ty-rational",   "22 // 7",                                     p_text("ty-rational", "22//7")),
    ("ty-symbol",     ":sym_marker_z",                               p_text("ty-symbol", "sym_marker_z")),
    ("ty-bool",       "true",                                        p_text("ty-bool", "true")),
    ("ty-char",       "'Q'",                                         p_text("ty-char", "Q")),
    ("ty-regex",      "r\"abc_marker+\"",                            p_text("ty-regex", "abc_marker")),
    ("ty-pair",       ":pk => 5150",                                 p_text("ty-pair", "5150")),
    ("ty-function",   "sqrt",                                        p_text("ty-function", "sqrt")),
    # ── rich MIME (markdown / image / table / dom) ────────────────────────────
    ("ty-markdown",   "using Markdown; md\"# MDHEADMARK\n\nbody text\"",                         p_both("ty-markdown", "h1", "MDHEADMARK")),
    ("ty-image",      "using Colors, ImageShow; fill(RGB{Colors.N0f8}(1.0, 0.0, 0.0), 8, 8)",    p_el("ty-image", "img")),
    ("ty-gray",       "using Colors, ImageShow; Gray{Colors.N0f8}.(reshape(range(0,1,length=64), 8, 8))", p_el("ty-gray", "img")),
    ("ty-dataframe",  "using DataFrames; DataFrame(colmark = [1,2,3], who = [\"a\",\"b\",\"c\"])", p_both("ty-dataframe", "table", "colmark")),
    ("ty-table",      "using Tables; Tables.columntable((tabmark = [10,20], q = [30,40]))",       p_text("ty-table", "tabmark")),
    ("ty-dom",        "using Bonito; DOM.div(\"DOMMARKER\"; class = \"t-eval-dom\")",             p_both("ty-dom", ".t-eval-dom", "DOMMARKER")),
    # ── colored stdout ────────────────────────────────────────────────────────
    ("st-pkg",        "using Pkg; Pkg.status(); nothing",                                         p_colored("st-pkg", "Bonito")),
    ("st-printstyled","printstyled(\"COLORMARK line\\n\"; color = :red, bold = true); nothing",   p_colored("st-printstyled", "COLORMARK")),
    # ── don't crash the display on huge output ────────────────────────────────
    ("sf-stdout",     "for i in 1:300_000; println(\"LINE \", i, \" filler filler filler\"); end; nothing", p_text("sf-stdout", "truncated")),
    ("sf-string",     "\"Z\"^2_000_000",                            p_text("sf-string", "truncated")),
    ("sf-array",      "rand(4000, 4000)",                           p_text("sf-array", "4000×4000")),
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
    s = TK.dev_server(; agent = msg -> begin
        code = get(BY_ID, String(msg), nothing)
        code === nothing ? Any[text("unknown case"), end_turn()] :
            Any[bt_eval(code; env_path = EVALENV, id = String(msg)), end_turn()]
    end)
    try
        TK.open_browser(s; width = 1280, height = 900)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        sleep(1)

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
            ok = TK.wait_for(s, "$id rendered", predicate; timeout = 40) == true
            ok || @info "case body dump" id body = TK.eval_js(s, "document.querySelector('$(jsel(id))')?.innerText?.slice(0,400) ?? '(none)'")
            @test ok
        end

        TK.screenshot(s, joinpath(SHOT_DIR, "bt_eval-types.png"))
    finally
        close(s)
    end
end
