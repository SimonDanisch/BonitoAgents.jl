# Loaded into every Malt-managed Julia subprocess on startup. Provides two
# pure formatting functions called from the wrapper expression in
# session.jl::execute. Returns a `(; blocks, html, errored, echo)` payload of
# base types only, so Malt's serialiser never sees user-defined types it
# can't reconstruct on the parent side.

module BonitoMCPHelper

using Base64

# Soft-scope transform for REPL-style top-level eval (see `repl_eval`).
#
# `Base.require` rather than `@eval import REPL; REPL.softscope`: the latter
# creates the `REPL` binding and READS it inside one top-level expression, and
# under Julia 1.12's stricter world-age rules for global bindings a
# freshly-created binding is not reliably visible in the world the same
# expression is running in. `require` hands back the module object, so there is
# no binding to see.
#
# The fallback must be LOUD. Degrading to `identity` silently swaps the eval's
# scoping rules for the life of the worker — `acc = 0; for i in 1:5; acc += i;
# end` then dies with "UndefVarError: acc not defined in local scope", which
# reads as a bug in the user's code, not as "REPL didn't load". The two ways it
# actually happens: a LOAD_PATH without `@stdlib` (a parent process exporting
# `JULIA_LOAD_PATH` — `Pkg.test` does exactly that), or a transient failure
# while precompiling/loading REPL.
const REPL_PKGID = Base.PkgId(Base.UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb"), "REPL")

const SOFTSCOPE = try
    getfield(Base.require(REPL_PKGID), :softscope)
catch e
    e isa InterruptException && rethrow()
    @warn "bt_julia_eval: could not load REPL, so evals fall back to FILE (hard) scope — " *
          "a top-level `for`/`while` will NOT be able to assign a global. " *
          "Usually a LOAD_PATH without `@stdlib`." exception = (e, catch_backtrace()) load_path = LOAD_PATH
    identity
end

const DEFAULT_MAX_RESPONSE_BYTES = 10_000
const LARGE_CONTAINER_THRESHOLD  = 100      # array / dict elements

"""
    repl_eval(code) -> value

Evaluate `code` exactly as a Julia REPL would, and return the value of the LAST
top-level statement. Each top-level statement is evaluated SEPARATELY in `Main`
(via `include_string`), which is what makes bt_julia_eval behave like a REPL
and not like a single spliced expression:

  * A `function` / `struct` / `const` definition advances the world age before
    later statements use it — so `f(x) = ...; f(1)` in ONE call no longer warns
    "access to binding `f` in a world prior to its definition" (Julia ≥ 1.12).
  * Soft scope: a top-level `for` / `while` may assign to a global
    (`acc = 0; for i in 1:n; acc += i; end`) — the REPL's behavior, which hard
    (file/`include`) scope rejects.

The previous path spliced the parsed block as a function ARGUMENT
(`format_value(<whole block>, …)`), flattening it into one expression that got
neither property. Backtrace noise from `include_string` is already trimmed
(see `BACKTRACE_NOISE_FRAMES`).
"""
repl_eval(code::AbstractString) =
    Base.include_string(SOFTSCOPE, Main, String(code), "bt_julia_eval")

# The task currently running an eval, set by the wrapper in session.jl::execute.
const EVAL_TASK = Ref{Union{Task,Nothing}}(nothing)

"""
    interrupt_eval() -> Bool

Throw an `InterruptException` into the in-flight eval task, returning whether it
was delivered. False means the host must escalate to SIGINT.

A bare SIGINT goes to whichever task the scheduler happens to be running, which
is very often the 4Hz stdout flusher rather than the eval — hence targeting the
task directly.

Only a task PARKED in a wait queue (`sleep`, blocking IO) can be reached this
way. `schedule` on an executing task silently fails to stop it and is documented
as scheduler-corrupting, so a tight loop reports false and takes the signal.
"""
function interrupt_eval()
    t = EVAL_TASK[]
    (t === nothing || istaskdone(t)) && return false
    t.queue === nothing && return false     # executing, not parked
    schedule(t, InterruptException(); error = true)
    return true
end

# One worker call: REPL-eval the code, then format the result value. A user
# error thrown by the eval propagates to the caller's try/catch (→ format_error).
eval_and_format(code::AbstractString, out_dir::AbstractString, max_bytes::Int, full_output::Bool) =
    format_value(repl_eval(code), out_dir, max_bytes, full_output)

# On-disk cap for rich-output files (PNG/SVG written by try_save_rich).
# This is SEPARATE from `max_bytes` (the per-block RESPONSE cap, 10KB default):
# the rendered bytes go to a FILE on the worker, never into the MCP response —
# only the path + mime + size do. Gating the file on the tiny response cap meant
# essentially every real Makie/Plots PNG (50-500KB) silently degraded to text
# (M14). 50MB is generous enough for any normal figure while still refusing a
# pathological multi-hundred-MB render.
const RICH_FILE_CAP_BYTES = 50 * 1024 * 1024

# Stack frames we strip from error backtraces so the user-visible trace ends
# at the actual call site (not REPL / include_string / Malt internals).
const BACKTRACE_NOISE_FRAMES = (
    r"\bBase\.eval\b", r"\binclude_string\b", r"\beval_user_input\b",
    r"\bclient\.jl\b", r"\brun_main_repl\b", r"\brun_fallback_repl\b",
    r"\brepl_main\b",  r"\b_start\b",
    r"\bMalt\b",                            # Malt's own remote_eval frames
)

# ── Public entries ──────────────────────────────────────────────────────────
# Both formatters return the same typed payload NamedTuple:
#   blocks  — extra agent-facing content blocks (rich-file refs; usually empty)
#   html    — the result DESCRIPTOR json (`{"remote_ref": "...", "errored": ...}`)
#             when a ref was parked, else nothing. NEVER rendered markup.
#   errored — the eval threw (a USER error — typed, never sniffed from text)
#   echo    — text appended to the OUTPUT stream, terminal-faithful: the
#             result's repr (a REPL echoes the value) or the red ERROR text.
"""
    format_value(val, out_dir, max_bytes, full_output)

Turn a Julia value into the eval result payload. In a chat context the value
is PARKED in a page-invisible holder session (`RemoteProxy.remote_ref`) — no
render at eval time; the descriptor identifies it and the chat's `RemoteRef`
mounts it serialize-on-mount over the bridge. The agent reads the value from
the output echo. 2-D color arrays additionally become an on-disk PNG (encoded by
the host — see `pixel_block`); large container reprs are summarised.
"""
function format_value(val, out_dir::AbstractString, max_bytes::Int, full_output::Bool)
    val === nothing &&
        return (; blocks = Dict{String,Any}[], html = nothing, errored = false,
                  echo = nothing)

    repr = truncate_text(
        !full_output && is_large_container(val) ? summarize_container(val) : result_repr(val),
        max_bytes, full_output, "result")

    # Bridge path: park the value for the live embed, and — for a DISPLAY value
    # (App/plot/rich) — pre-render its DOM to compact, assetless HTML for the
    # agent. The pre-render runs the App body HERE (inside the eval's captured
    # stdout), so a render-time error surfaces to the agent as a normal error
    # instead of failing silently at mount. Throwing inside is caught here and
    # degrades to the no-bridge text path below.
    if isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :remote_ref)
        result = try
            bridge_result(val, repr, max_bytes, full_output, out_dir)
        catch e
            @warn "format_value: bridge path failed; falling back to text/file preview" exception = (e, catch_backtrace())
            nothing
        end
        result === nothing || return result
    end

    # No bridge (standalone MCP OR the env's Bonito is too old): no embed, so the
    # repr echo IS the result — append it to the output; add an on-disk rich
    # preview when genuinely visual. `wants_display` flags a value that WOULD have
    # rendered live (a Bonito App / Makie plot / rich image) so the host can offer
    # the version-upgrade card instead of just degrading to text.
    blocks = Dict{String,Any}[]
    show_block = try_save_rich(val, out_dir, max_bytes)
    show_block === nothing || push!(blocks, show_block)
    return (; blocks = blocks, html = nothing, errored = false, echo = repr,
              wants_display = is_display_type(val) || show_block !== nothing)
end

# The bridge result: parks `val` for the live embed and builds the agent-facing
# descriptor. A DISPLAY value (App/plot/rich) is pre-rendered to compact,
# assetless HTML (`RemoteProxy.summary_html`) so the agent sees the REAL DOM,
# not a bare note — and because that render runs the App body, a render-time
# failure comes back as a `CapturedException`: surface it like an error value
# (park the exception so the embed shows it via `jsrender(::CapturedException)`,
# echo the terminal-faithful red error so it lands in the agent's captured
# stdout) while the MCP-level `errored` stays FALSE — the eval succeeded, only
# the display failed. A plain value keeps its short text repr. Any throw here
# propagates to `format_value`, which degrades to the no-bridge text path.
function bridge_result(val, repr::AbstractString, max_bytes::Int, full_output::Bool,
                       out_dir::AbstractString)
    RP = Main.RemoteProxy
    # An image is a FILE, not a summary. `summary_html` renders the value's
    # richest mime inline for the agent, and a Colorant matrix's richest mime —
    # absent ImageShow, which an eval worker normally does not have — is Colors'
    # swatch SVG: one `<rect>` per pixel, 155KB for a small image, inlined into
    # the response as markup that no agent can look at. The PNG on disk is the
    # route that actually shows an image: the agent opens the path and the chat
    # previews it. The value is still parked, so the live embed is unchanged.
    if looks_like_image(val)
        blocks = Dict{String,Any}[]
        block = try_save_rich(val, out_dir, max_bytes)
        block === nothing || push!(blocks, block)
        ref = RP.remote_ref(val)
        return (; blocks = blocks,
                  html = result_descriptor(ref, false,
                           truncate_text(repr, max_bytes, full_output, "result")),
                  errored = false, echo = nothing)
    end
    if is_display_type(val)
        sm = RP.summary_html(val)
        if sm isa CapturedException
            ref = RP.remote_ref(sm)
            echo = "\e[91mERROR: " *
                   truncate_text(sprint(showerror, sm), max_bytes, full_output, "result") *
                   "\e[39m"
            return (; blocks = Dict{String,Any}[],
                      html = result_descriptor(ref, true, ""), errored = false, echo = echo)
        end
        ref = RP.remote_ref(val)
        return (; blocks = Dict{String,Any}[],
                  html = result_descriptor(ref, false,
                           truncate_text(sm, max_bytes, full_output, "result")),
                  errored = false, echo = nothing)
    end
    # Plain value: park for the embed, keep the short text repr (rendering
    # `App(42)` to `<div>42</div>` is more tokens and less clear than "42").
    ref = RP.remote_ref(val)
    return (; blocks = Dict{String,Any}[],
              html = result_descriptor(ref, false, display_repr(val, repr)),
              errored = false, echo = nothing)
end

# The agent-facing `repr` for a value parked as a LIVE embed. For a plain value
# the repr IS the value, so keep it. For an INTERACTIVE display (a Bonito `App`
# or a Makie plot/figure) the bare type repr — a lone "App" — reads like nothing
# happened and leaves the agent unsure the display worked; replace it with an
# explicit note that the value is now shown live & interactive in the chat. Type
# match is by name so no Bonito/Makie dependency is needed in the worker env.
function display_repr(val, repr::AbstractString)
    n = string(nameof(typeof(val)))
    kind = n == "App" ? "interactive app" :
           (startswith(n, "Figure") || n == "Scene" || endswith(n, "Plot")) ? "interactive plot" :
           nothing
    kind === nothing && return repr
    return "⟨$(kind) displayed live in the chat — the user can see and interact with it now⟩"
end

# A rich, INTERACTIVE display value (Bonito `App` or a Makie plot) by type name —
# no Bonito/Makie dependency needed in the worker env. Used to decide whether a
# value that couldn't reach the live bridge would have WANTED to display (so the
# host can offer the version-upgrade card instead of silently degrading to text).
is_display_type(val) = let n = string(nameof(typeof(val)))
    n == "App" || startswith(n, "Figure") || n == "Scene" || endswith(n, "Plot")
end

# The result descriptor json the chat decodes (BonitoAgents remote_app.jl):
# `{"remote_ref": "...", "errored": bool, "repr": "..."}`. `repr` is the result
# echo for the AGENT (the chat renders the live embed instead, and never shows
# `repr` — the value is already displayed). No JSON dep in the worker env, so
# escape the string by hand.
result_descriptor(ref::AbstractString, errored::Bool, repr::AbstractString) =
    string("{\"remote_ref\":\"", ref, "\",\"errored\":", errored ? "true" : "false",
           ",\"repr\":\"", json_escape_string(repr), "\"}")

function json_escape_string(s::AbstractString)
    io = IOBuffer()
    for c in s
        if     c == '"';  print(io, "\\\"")
        elseif c == '\\'; print(io, "\\\\")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        elseif c == '\t'; print(io, "\\t")
        elseif c < ' ';   print(io, "\\u", lpad(string(UInt16(c), base = 16), 4, '0'))
        else              print(io, c)
        end
    end
    return String(take!(io))
end

# Walk the IMAGE MIME chain (PNG → SVG) and write the first match to disk.
# Returns a `shown: <relpath> (<mime>, <size>)` text block that the chat-side
# render_tool_body detects and previews inline. nothing if no rich MIME was
# renderable. A colour matrix skips the chain: it goes to the host as pixels
# (`pixel_block`) and comes back as the same `shown:` block, encoded there.
# `max_bytes` is accepted for call-site compatibility but the file-size gate uses
# the generous RICH_FILE_CAP_BYTES — the bytes go to disk, not the response (M14).
#
# Deliberately NO text/html arm: an html show method is ubiquitous on values
# whose text/plain form (already in the response) is perfectly readable —
# `Vector{Method}`, DataFrames, … — and the chat renders html show files as
# read-only SOURCE (never a live document; see render_show_file +
# e2e:chat_show_extras), so an html rich file could only ever degrade the
# display to a wall of raw markup. Rich files are for genuinely VISUAL
# values, i.e. images.
function try_save_rich(val, out_dir::AbstractString, max_bytes::Int)
    val === nothing && return nothing
    # One path for every colour matrix, whatever the user's env could otherwise
    # render it as: the same PNG either way, and never the per-pixel SVG below.
    looks_like_image(val) && return pixel_block(val, out_dir)
    mkpath(out_dir)
    base = string(time_ns(), base = 16) * "-" * string(rand(UInt32), base = 16)
    cap = RICH_FILE_CAP_BYTES

    if showable_safe(MIME"image/png"(), val)
        png = sprint_mime(val, MIME"image/png"())
        if !isempty(png) && length(png) <= cap
            return write_show_file(out_dir, base, ".png", "image/png", png, val)
        end
    end

    if showable_safe(MIME"image/svg+xml"(), val)
        svg = sprint_mime(val, MIME"image/svg+xml"())
        if !isempty(svg) && length(svg) <= cap
            return write_show_file(out_dir, base, ".svg", "image/svg+xml", svg, val)
        end
    end

    return nothing  # text/plain is already in the response — no file
end

# Write the rendered bytes to disk and produce the reference content block.
function write_show_file(out_dir::AbstractString, base::AbstractString,
                          ext::AbstractString, mime::AbstractString,
                          bytes, val)
    fname = base * ext
    path  = joinpath(out_dir, fname)
    open(io -> write(io, bytes), path, "w")
    # Relative path so the chat side can resolve under either cwd. Path is
    # stable across server restarts because it lives on disk.
    relpath_str = joinpath(".bonitoAgents", "show", fname)
    text = string("shown: ", relpath_str,
                  " (", mime, ", ", format_bytes_short(length(bytes)), ")",
                  "\ntype: ", typeof_short(val))
    # try_save_rich returns ONE block — the caller (format_value) appends it
    # to the existing text result. No more `[text_block(text)]` wrapping.
    return text_block(text)
end

text_block(text::AbstractString) = Dict{String,Any}(
    "type" => "text",
    "text" => text,
)

typeof_short(val) = string(typeof(val).name.name)

# `showable` can throw for some types (e.g. Makie pre-display lifecycle bugs);
# we don't want a failed probe to abort the whole render path, just to fall
# through to the next MIME.
function showable_safe(mime::MIME, val)
    try
        return showable(mime, val)
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

function sprint_mime(val, mime::MIME)
    try
        # Some types' MIME shows write binary, others write text — reading
        # back as Vector{UInt8} via take! handles both, and base64encode +
        # codeunits work on either path uniformly.
        io = IOBuffer()
        show(io, mime, val)
        return take!(io)
    catch e
        e isa InterruptException && rethrow()
        return UInt8[]
    end
end

function format_bytes_short(n::Integer)
    n < 1024     && return "$(n)B"
    n < 1024^2   && return string(round(n / 1024; digits=1), "KB")
    n < 1024^3   && return string(round(n / 1024^2; digits=1), "MB")
                    return string(round(n / 1024^3; digits=2), "GB")
end

"""
    format_error(err, bt, max_bytes, full_output)

An error is a VALUE: the `CapturedException` is parked via `remote_ref`
exactly like any result (the chat mounts it live and Bonito renders it via
`jsrender(::Session, ::CapturedException)`), the descriptor carries
`errored: true`, and the terminal-faithful red `ERROR: …` text (with the
trimmed backtrace) goes to the output echo — what a REPL would print.
"""
function format_error(err, bt, max_bytes::Int, full_output::Bool)
    ce = CapturedException(err, bt)
    text = trim_backtrace(sprint(showerror, ce))
    echo = "\e[91mERROR: " * truncate_text(text, max_bytes, full_output, "error") * "\e[39m"

    ref = nothing
    if isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :remote_ref)
        ref = try
            Main.RemoteProxy.remote_ref(ce)
        catch e
            @warn "format_error: remote_ref failed; error stays text-only" exception = (e, catch_backtrace())
            nothing
        end
    end
    # Unlike a value, an ERROR keeps its echo in the output stream: the agent
    # must SEE the failure prominently (not buried in a descriptor) to fix the
    # code, and the red console error is the terminal-faithful view. The embed
    # renders the exception too — redundancy is warranted for errors. `remote_ref`
    # returns the holder id; this IS the error, so the descriptor is always errored.
    html = ref === nothing ? nothing : result_descriptor(ref, true, "")
    return (; blocks = Dict{String,Any}[], html = html, errored = true, echo = echo)
end

# ── Output discipline ──────────────────────────────────────────────────────
function truncate_text(text::AbstractString, max_bytes::Int, full_output::Bool,
                       label::AbstractString)
    full_output && return text
    n = length(text)
    n <= max_bytes && return text
    keep = max_bytes
    cut  = SubString(text, 1, prevind(text, keep + 1))
    return cut * "\n[truncated: $label was $n bytes; kept first $keep. " *
                  "call with full_output=true to see all]"
end

function trim_backtrace(text::AbstractString)
    lines = split(text, '\n')
    cut = something(findfirst(line -> any(p -> occursin(p, line), BACKTRACE_NOISE_FRAMES),
                              lines), length(lines) + 1)
    cut > length(lines) && return strip(text)
    kept       = lines[1:cut-1]
    suppressed = length(lines) - length(kept)
    suppressed > 1 && push!(kept, "  [+ $suppressed internal frames]")
    return strip(join(kept, "\n"))
end

# The result repr — the AGENT-facing text of the value (it rides in the
# descriptor's `repr`, or the output stream in the no-bridge fallback).
# Terminal-faithful: normally the value's `show(text/plain)` repr. BUT a value
# with a rich display (a Bonito App, a Makie figure) has NO meaningful text
# form: `show(text/plain)` falls back to the default struct dump (opaque
# closures / Refs / `nothing`s), which a real REPL would never print — it
# would DISPLAY the object instead. In the chat that display IS the live
# result embed, so a struct dump would be useless to the agent. For those,
# use a concise `summary` (e.g. "Bonito.App"). Plain data structs (no rich
# display) keep their struct dump — that IS their REPL repr and it's useful.
const GENERIC_SHOW2 = which(Base.show, (IO, Any))
const GENERIC_SHOW3 = which(Base.show, (IO, MIME"text/plain", Any))
has_readable_repr(v) =
    which(Base.show, (IO, typeof(v))) !== GENERIC_SHOW2 ||
    which(Base.show, (IO, MIME"text/plain", typeof(v))) !== GENERIC_SHOW3
is_richly_displayable(v) =
    showable(MIME"text/html"(), v) || showable(MIME"image/png"(), v) ||
    showable(MIME"image/svg+xml"(), v)
function result_repr(v)
    (!has_readable_repr(v) && is_richly_displayable(v)) && return summary(v)
    return sprint(show, "text/plain", v)
end

function is_large_container(value)
    value isa AbstractArray && return length(value) > LARGE_CONTAINER_THRESHOLD
    value isa AbstractDict  && return length(value) > LARGE_CONTAINER_THRESHOLD
    return false
end

function summarize_container(value)
    sz     = value isa AbstractArray ? length(value) :
             value isa AbstractDict  ? length(value) : 0
    head_n = min(10, sz)
    head = value isa AbstractArray ? first(value, head_n) :
           Dict(k => v for (k, v) in Iterators.take(value, head_n))
    return string(typeof(value), " with $sz elements; first $head_n:\n",
                  sprint(show, "text/plain", head))
end

# The module a LOADED package resolves to, or nothing. Not the same question as
# `isdefined(Main, :ColorTypes)`: that is only true when the user typed `using
# ColorTypes` at the top level, while a value whose type comes from the package
# proves the package is loaded either way.
function loaded_module(name::AbstractString)
    for (pkg, m) in Base.loaded_modules
        pkg.name == name && return m
    end
    return nothing
end

# A 2-D array of colors, by TYPE. This used to match on the eltype's printed
# NAME ("RGB" / "Gray" / "Colorant"), which missed every other colorspace (HSV,
# Lab, …) and would have matched a user struct called `RGBHistogram`.
function looks_like_image(value)
    value isa AbstractArray && ndims(value) == 2 || return false
    ct = loaded_module("ColorTypes")
    ct === nothing && return false      # no Colorant can exist in this worker
    return eltype(value) <: ct.Colorant
end

# 0-255 from a color component. Out-of-gamut values clamp (an HDR render is
# still worth looking at) and non-finite ones go black rather than throwing.
component8(v) = round(UInt8, 255 * (isfinite(v) ? clamp(float(v), 0.0, 1.0) : 0.0))

# (4, width, height) of 8-bit RGBA. Images index [row, column], so the matrix's
# FIRST dimension is the image's height — same convention as PNGFiles/ImageShow.
# `T` (RGBA{Float64}) comes in as a type parameter so the conversion inside the
# loop is a typed call rather than a dynamic dispatch per pixel; `convert` is
# what makes every colorspace work (Gray, HSV, Lab, N0f8, …).
function rgba8_pixels(m::AbstractMatrix, ::Type{T}) where {T}
    h, w = size(m, 1), size(m, 2)
    out = Array{UInt8,3}(undef, 4, w, h)
    for (yi, i) in enumerate(axes(m, 1)), (xi, j) in enumerate(axes(m, 2))
        p = convert(T, m[i, j])
        out[1, xi, yi] = component8(p.r)
        out[2, xi, yi] = component8(p.g)
        out[3, xi, yi] = component8(p.b)
        out[4, xi, yi] = component8(p.alpha)
    end
    return out
end

"""
    pixel_block(m, out_dir) -> Union{Dict{String,Any},Nothing}

A colour matrix, handed to the BonitoMCP host to encode as a PNG: 8-bit RGBA
bytes, row by row. `nothing` for an image too large to ship (the file cap) or an
empty one.

Encoding is not done here because this file runs inside the eval worker, i.e. in
the USER's project, where PNGFiles is normally not loadable — and without it a
colour matrix has no `image/png` show method at all, only Colors' swatch SVG
(one `<rect>` per pixel, unreadable to an agent). The host runs in our own
environment and encodes with PNGFiles; see `write_eval_image` in eval_image.jl.
Only the colour conversion stays here, because only this process has the
user's colour types.
"""
function pixel_block(m::AbstractMatrix, out_dir::AbstractString)
    h, w = size(m, 1), size(m, 2)
    (w == 0 || h == 0 || 4 * w * h > RICH_FILE_CAP_BYTES) && return nothing
    ct = loaded_module("ColorTypes")   # loaded: `looks_like_image` said so
    px = try
        rgba8_pixels(m, ct.RGBA{Float64})
    catch e
        # The one expected failure: a colorspace whose conversion to RGB is not
        # loaded (HSV/Lab with only ColorTypes, no Colors). The eval itself
        # succeeded, so say why there is no image and keep the text repr —
        # anything else is a real error.
        (e isa MethodError && e.f === convert) || rethrow()
        @warn "bt_julia_eval: no conversion from $(eltype(m)) to RGBA is loaded; not rendered as an image"
        return nothing
    end
    base = string(time_ns(), base = 16) * "-" * string(rand(UInt32), base = 16)
    return Dict{String,Any}(
        "type"   => "bt_pixels",          # BonitoMCP.PIXEL_BLOCK
        "path"   => abspath(joinpath(out_dir, base * ".png")),
        "width"  => w,
        "height" => h,
        "opaque" => all(==(0xff), @view px[4, :, :]),
        "pixels" => vec(px),              # channel fastest, then x, then y
        "typeof" => typeof_short(m))
end

end # module BonitoMCPHelper
