# Loaded into every Malt-managed Julia subprocess on startup. Provides two
# pure formatting functions called from the wrapper expression in
# session.jl::execute. Returns a `(; blocks, html, errored, echo)` payload of
# base types only, so Malt's serialiser never sees user-defined types it
# can't reconstruct on the parent side.

module BonitoMCPHelper

using Base64

# Soft-scope transform for REPL-style top-level eval (see `repl_eval`). REPL is
# a stdlib (always in the sysimage), so this import is essentially free; fall
# back to hard scope (identity) only if it somehow can't resolve.
const SOFTSCOPE = try
    @eval import REPL
    REPL.softscope
catch
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
the output echo. 2-D color arrays additionally render to an on-disk PNG when
PNGFiles is loaded in the env; large container reprs are summarised.
"""
function format_value(val, out_dir::AbstractString, max_bytes::Int, full_output::Bool)
    val === nothing &&
        return (; blocks = Dict{String,Any}[], html = nothing, errored = false,
                  echo = nothing)

    repr = truncate_text(
        !full_output && is_large_container(val) ? summarize_container(val) : result_repr(val),
        max_bytes, full_output, "result")

    ref = nothing
    if isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :remote_ref)
        ref = try
            Main.RemoteProxy.remote_ref(val)
        catch e
            @warn "format_value: remote_ref failed; falling back to text/file preview" exception = (e, catch_backtrace())
            nothing
        end
    end
    # A parked ref IS displayed live as the result embed — the pane shows the
    # value, so there must be ZERO Output for it (`echo = nothing`): the Output
    # section is captured STDOUT only, never the result repr. The agent still
    # reads the result from the descriptor's `repr` field.
    ref === nothing ||
        return (; blocks = Dict{String,Any}[],
                  html = result_descriptor(ref, false, repr),
                  errored = false, echo = nothing)

    # No bridge (standalone MCP): no embed, so the repr echo IS the result —
    # append it to the output; add an on-disk rich preview when genuinely visual.
    blocks = Dict{String,Any}[]
    show_block = try_save_rich(val, out_dir, max_bytes)
    show_block === nothing || push!(blocks, show_block)
    return (; blocks = blocks, html = nothing, errored = false, echo = repr)
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

# Walk the IMAGE MIME chain (PNG → SVG, plus PNGFiles for Colorant matrices)
# and write the first match to disk. Returns a `shown: <relpath>
# (<mime>, <size>)` text block that the chat-side render_tool_body
# detects and previews inline. nothing if no rich MIME was renderable.
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
    mkpath(out_dir)
    base = string(time_ns(), base = 16) * "-" * string(rand(UInt32), base = 16)
    cap = RICH_FILE_CAP_BYTES

    if showable_safe(MIME"image/png"(), val)
        png = sprint_mime(val, MIME"image/png"())
        if !isempty(png) && length(png) <= cap
            return write_show_file(out_dir, base, ".png", "image/png", png, val)
        end
    end

    if looks_like_image(val)
        try
            png = value_to_png(val)
            if length(png) <= cap
                return write_show_file(out_dir, base, ".png", "image/png", png, val)
            end
        catch
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
    catch
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
    catch
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
    # renders the exception too — redundancy is warranted for errors.
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

function looks_like_image(value)
    value isa AbstractArray || return false
    ndims(value) == 2       || return false
    name = string(eltype(value))
    return occursin("RGB", name) || occursin("RGBA", name) ||
           occursin("Gray", name) || occursin("Colorant", name)
end

# Best-effort: only renders if the user has PNGFiles loaded in the env.
function value_to_png(value)
    if Base.isbindingresolved(Main, :PNGFiles) && isdefined(Main, :PNGFiles)
        io = IOBuffer()
        Base.invokelatest(Main.PNGFiles.save, io, value)
        return take!(io)
    end
    error("PNG encoding requires PNGFiles in the env")
end

end # module BonitoMCPHelper
