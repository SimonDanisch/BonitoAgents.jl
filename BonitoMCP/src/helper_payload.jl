# Loaded into every Malt-managed Julia subprocess on startup. Provides two
# pure formatting functions called from the wrapper expression in
# session.jl::execute. Returns Vector{Dict{String,Any}} of MCP content
# blocks — base types only, so Malt's serialiser never sees user-defined
# types it can't reconstruct on the parent side.

module BonitoMCPHelper

using Base64

const DEFAULT_MAX_RESPONSE_BYTES = 10_000
const LARGE_CONTAINER_THRESHOLD  = 100      # array / dict elements

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
"""
    format_value(val, max_bytes, full_output) → Vector{Dict{String,Any}}

Turn a Julia value into MCP content blocks. `nothing` returns are suppressed.
2-D color arrays render to PNG when PNGFiles is loaded in the env. Large
containers are summarised. Always-text blocks use the `result:\\n<body>` shape
so the chat-side renderer picks them up as labeled Monaco sections.
"""
function format_value(val, out_dir::AbstractString, max_bytes::Int, full_output::Bool)
    # A `nothing` result still gets an (empty) html result block so the chat's
    # invariant holds — content ALWAYS ends with the result, and everything
    # between the code echo and it is stdout/console. Without this, a
    # `Pkg.status(); nothing` (output, no value) leaves no result block and the
    # chat would mount the stdout block AS the result, hiding the Output section.
    val === nothing && return (; blocks = Dict{String,Any}[], html = "")

    # Chat context (proxy bridge loaded): the result is PARKED in a
    # page-invisible holder session (`RemoteProxy.remote_ref`) — NO render at
    # eval time. The final content block becomes a tiny JSON descriptor; the
    # chat's typed render builds a `RemoteRef` from it and rendering happens
    # per-mount over the bridge (serialize-on-mount). Ids are uuid/uuid
    # strings, so the hand-built JSON needs no escaping.
    ref = nothing
    if isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :remote_ref)
        ref = try
            Main.RemoteProxy.remote_ref(val)
        catch e
            @warn "format_value: remote_ref failed; falling back to text/file preview" exception = (e, catch_backtrace())
            nothing
        end
    end
    ref === nothing ||
        return (; blocks = Dict{String,Any}[], html = "{\"remote_ref\":\"$(ref)\"}")

    # No bridge (standalone MCP): fall back to a text repr + on-disk rich preview
    # so the agent still has a readable result without a live render.
    blocks = Dict{String,Any}[]
    repr = !full_output && is_large_container(val) ?
        summarize_container(val) : sprint(show, "text/plain", val)
    push!(blocks, Dict{String,Any}(
        "type" => "text",
        "text" => "result:\n$(truncate_text(repr, max_bytes, full_output, "result"))",
    ))
    show_block = try_save_rich(val, out_dir, max_bytes)
    show_block === nothing || push!(blocks, show_block)
    return (; blocks = blocks, html = nothing)
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
    format_error(err, bt, max_bytes, full_output) → Vector{Dict{String,Any}}

Render an exception + trimmed backtrace as a single error block.
"""
function format_error(err, bt, max_bytes::Int, full_output::Bool)
    text = sprint() do io
        showerror(io, err)
        println(io)
        Base.show_backtrace(io, bt)
    end
    text = trim_backtrace(text)
    # Same `(; blocks, html)` shape as format_value. bt_julia_eval ALWAYS renders
    # an HTML fragment (when the bridge is up) — errors included — so the chat's
    # EvalMsg can uniformly mount "the result render" without ever testing block
    # content. The error renders as the exception itself (App(err) → its repr);
    # the full backtrace stays in the text block for the agent.
    html = nothing
    if isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :render_eval_html)
        html = try
            Main.RemoteProxy.render_eval_html(err)
        catch
            nothing
        end
    end
    return (; blocks = [Dict{String,Any}(
        "type" => "text",
        "text" => "error:\n$(truncate_text(text, max_bytes, full_output, "error"))",
    )], html = html)
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
