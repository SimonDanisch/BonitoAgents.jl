# ── One file renderer, two homes ────────────────────────────────────────────
# `bt_show` (a preview inside a chat bubble) and the workspace file tab answer
# the same question — "what is in this file?" — so they run the same code. The
# only differences are framing:
#
#   • InlineView — inside a tool bubble: compact, read-only, height-capped.
#   • PanelView  — a workspace tab: fills the panel, gets a header with the
#                  WORKER path + actions, and text-backed files get an editable
#                  Monaco with Save.
#
# What each kind renders is chosen by DISPATCH on `file_kind(path)`, not by a
# chain of extension tests at every call site. Adding a format is one `file_kind`
# entry plus one `file_viewer` method (and a `view_input`, if the browser reads
# it from somewhere other than `show_media_src`).
#
# Bytes: media (image/video/audio/pdf/html) is streamed from the worker through
# a stable `/worker-file/` URL with byte-range support. A multi-GB video
# scrubs without ever being copied to the server. Everything we have to parse
# (text, csv, notebooks, geometry) is mirrored to the server first via
# `fetch_show_file`, which re-fetches exactly when the worker's copy changed.

abstract type FileKind end
# The browser reads these itself, from a url: its viewer is given the url.
abstract type StreamedKind <: FileKind end
# The server reads these and builds the page from them: its viewer is given
# the content (`FileContent`).
abstract type ParsedKind <: FileKind end
struct ImageFile    <: StreamedKind end
struct VideoFile    <: StreamedKind end
struct AudioFile    <: StreamedKind end
struct MarkdownFile <: ParsedKind end
struct TableFile    <: ParsedKind end   # csv / tsv
struct NotebookFile <: ParsedKind end   # .ipynb
struct MeshFile     <: StreamedKind end   # .obj / .stl / .ply / .off / .glb / .gltf
struct PDFFile      <: StreamedKind end
struct HTMLFile     <: StreamedKind end
struct TextFile     <: ParsedKind end   # anything Monaco can show — the default
struct BinaryFile   <: ParsedKind end   # known-binary or NUL-sniffed → hex preview

abstract type ViewMode end
struct InlineView <: ViewMode end
struct PanelView  <: ViewMode end

const VIEW_AUDIO_MIME = Dict(".mp3" => "audio/mpeg", ".wav" => "audio/wav",
    ".ogg" => "audio/ogg", ".oga" => "audio/ogg", ".flac" => "audio/flac",
    ".m4a" => "audio/mp4", ".aac" => "audio/aac", ".opus" => "audio/opus")
const VIEW_MESH_EXTS  = (".obj", ".stl", ".ply", ".off", ".glb", ".gltf")
const VIEW_TABLE_EXTS = (".csv", ".tsv")

"""
    file_kind(path) -> FileKind

Which viewer a path gets, decided from its extension alone (no IO). The default
is [`TextFile`](@ref) — including for extensionless files (`Makefile`, `LICENSE`)
and unknown extensions — because "show it as text" is almost always better than
"refuse". Content that turns out to be binary anyway is caught at render time by
a NUL sniff and falls back to the hex preview.
"""
function file_kind(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext in SHOW_IMAGE_EXTS          && return ImageFile()
    haskey(SHOW_VIDEO_MIME, ext)    && return VideoFile()
    haskey(VIEW_AUDIO_MIME, ext)    && return AudioFile()
    ext in (".md", ".markdown")     && return MarkdownFile()
    ext in VIEW_TABLE_EXTS          && return TableFile()
    ext == ".ipynb"                 && return NotebookFile()
    ext in VIEW_MESH_EXTS           && return MeshFile()
    ext == ".pdf"                   && return PDFFile()
    ext in (".html", ".htm")        && return HTMLFile()
    ext in EDITOR_BINARY_EXTS       && return BinaryFile()
    return TextFile()
end

# How big a file of this kind may be before we refuse. Streamed kinds have no
# limit — the bytes never touch the server. The parsed kinds do, because we hold
# the whole thing in memory (and then in the DOM).
view_size_limit(::FileKind)    = typemax(Int)          # image/video/audio/pdf: streamed
view_size_limit(::TextFile)    = FILE_EDITOR_MAX_BYTES
view_size_limit(::MarkdownFile)= FILE_EDITOR_MAX_BYTES
view_size_limit(::HTMLFile)    = FILE_EDITOR_MAX_BYTES
# Generous, but bounded by what we can PARSE (not just render): a table is read
# in full even though only the first `TABLE_MAX_ROWS` reach the DOM, and a
# notebook's JSON is decoded whole.
view_size_limit(::TableFile)   = 16 * 1024 * 1024
view_size_limit(::NotebookFile)= 32 * 1024 * 1024
view_size_limit(::MeshFile)    = 512 * 1024 * 1024     # the browser holds it whole, and so does the response
view_size_limit(::BinaryFile)  = 64 * 1024 * 1024      # we only hexdump the head, but we mirror it

# Does this kind's file also make sense as editable SOURCE? A markdown file, an
# HTML page, a CSV and an SVG all have a "rendered" view AND a text you'd want to
# fix — the panel offers both behind one toggle. A PNG does not.
has_source_view(::FileKind, ::AbstractString) = false
has_source_view(::MarkdownFile, ::AbstractString) = true
has_source_view(::TableFile, ::AbstractString)    = true
has_source_view(::HTMLFile, ::AbstractString)     = true
has_source_view(::ImageFile, path::AbstractString) = lowercase(splitext(path)[2]) == ".svg"

# One-glyph kind marker for the panel header / tab. Deliberately monochrome
# glyphs rather than emoji: they inherit text colour and don't shift the header's
# line height between kinds.
kind_icon(::FileKind)    = "◻"
kind_icon(::ImageFile)   = "▦"
kind_icon(::VideoFile)   = "▶"
kind_icon(::AudioFile)   = "♪"
kind_icon(::MarkdownFile)= "¶"
kind_icon(::TableFile)   = "▤"
kind_icon(::NotebookFile)= "❑"
kind_icon(::MeshFile)    = "◈"
kind_icon(::PDFFile)     = "▥"      # distinct from the table's ▤
kind_icon(::HTMLFile)    = "◧"
kind_icon(::TextFile)    = "≡"
kind_icon(::BinaryFile)  = "⬢"

kind_label(::FileKind)     = "file"
kind_label(::ImageFile)    = "image"
kind_label(::VideoFile)    = "video"
kind_label(::AudioFile)    = "audio"
kind_label(::MarkdownFile) = "markdown"
kind_label(::TableFile)    = "table"
kind_label(::NotebookFile) = "notebook"
kind_label(::MeshFile)     = "3D"
kind_label(::PDFFile)      = "pdf"
kind_label(::HTMLFile)     = "html"
kind_label(::TextFile)     = "text"
kind_label(::BinaryFile)   = "binary"

# Is `path` something the Monaco EDITOR can open and save? Kept as its own
# predicate (rather than folded into `file_kind`) because it answers a different
# question than "how do we show this": the ✎/save affordances key on it.
editor_openable(path::AbstractString) = file_kind(path) isa TextFile

# ── the components ──────────────────────────────────────────────────────────

"""
    FileView(file::ShowTool, mode::ViewMode)

A worker-side file rendered for one of the two homes. Pure data — the fetch
happens at render time (inside `jsrender`), so constructing one is free and a
multi-GB transfer only starts when the body is actually shown.
"""
struct FileView
    file :: ShowTool
    mode :: ViewMode
end

FileView(state::ServerState, project_id::AbstractString, cwd::AbstractString,
         path::AbstractString, mode::ViewMode = InlineView()) =
    FileView(ShowTool(state, String(project_id), String(cwd), String(path)), mode)

view_path(fv::FileView) = fv.file.path
view_kind(fv::FileView) = file_kind(fv.file.path)

# Renderers run in two contexts: a live browser session, and HEADLESS — a plain
# `sprint(show, node)` with no session at all, which is how the unit tests (and
# any ad-hoc DOM-shape check) inspect what a kind produces. There is no browser
# in the headless case and no asset server to register a url with, so dispatch
# says so once, here, instead of every renderer carrying a `session === nothing`
# branch.
asset_src(session::Bonito.Session, path::AbstractString) =
    Bonito.url(session, Bonito.Asset(String(path)))
asset_src(::Nothing, path::AbstractString) = Bonito.Asset(String(path))

# Never throw out of `jsrender`: a failed read or parse is the visible
# `.bt-tool-error` node (`viewer_or_error`).
Bonito.jsrender(session::Bonito.Session, fv::FileView) =
    Bonito.jsrender(session, viewer_or_error(() -> render_file(view_kind(fv), fv.mode, fv, session), view_path(fv)))

# What `build` makes, or the error node saying why the file can't be shown. Any
# error: the worker, the network and the format can each fail many ways.
function viewer_or_error(build, path::AbstractString)
    try
        return build()
    catch e
        e isa InterruptException && rethrow()
        @warn "file view: could not render" path exception = (e, catch_backtrace())
        return file_error_node(path, e)
    end
end

file_error_node(path::AbstractString, e) =
    DOM.div(DOM.div("Can't show $(basename(String(path)))"; class = "bt-fv-error-title"),
            DOM.div(first(split(sprint(showerror, e), '\n')); class = "bt-fv-error-detail");
            class = "bt-tool-error bt-fv-error")

# The server-side bytes, with the size guard applied FIRST so a 3 GB "text" file
# reports a refusal instead of a three-minute transfer ending in a frozen tab.
#
# `stamp` is the worker's `(size, mtime)`; pass one in when you've already got it
# (the panel stats for its header anyway) and the whole read costs a single
# round-trip. `missing` means "go and stat".
function view_bytes(fv::FileView; stamp = missing)
    kind = view_kind(fv)
    st = fv.file
    s = stamp === missing ? worker_file_stamp(st, show_worker_path(st)) : stamp
    s === nothing || check_view_size(kind, s.size)
    local_path = fetch_show_file(st; stamp = s)
    # A second check on what actually landed: the pre-check is skipped entirely
    # when the worker couldn't be stat'd, and the file may have grown since.
    check_view_size(kind, filesize(local_path))
    return (local_path, read(local_path))
end

function check_view_size(kind::FileKind, n::Integer)
    limit = view_size_limit(kind)
    n <= limit || error("$(format_bytes(n)) is too large to open as $(kind_label(kind)) " *
                        "(limit $(format_bytes(limit)))")
    return n
end

# A NUL in the first 8 KB means binary no matter what the extension claimed —
# Monaco would render garbage and a save would corrupt the file.
looks_binary(bytes::AbstractVector{UInt8}) = 0x00 in view(bytes, 1:min(length(bytes), 8192))

# ── Viewers ─────────────────────────────────────────────────────────────────
# `file_viewer(kind, input, path, mode)`: `input` is the file's url (`StreamedKind`)
# or its content (`ParsedKind`); `InlineView()` is a block in a bubble, `PanelView()`
# fills its box. Each brings its styles and script: chat, shared page, any app.

"""
    FileContent(bytes; size = length(bytes), link = no_link, raw_html = true)

A parsed kind's input: its bytes (a binary's head; `size` is the file's).
`link` maps a relative reference to a url (`nothing`: as written).
`raw_html = false` leaves out HTML written into markdown.
"""
struct FileContent
    bytes::Vector{UInt8}
    size::Int
    link::Function
    raw_html::Bool
end
FileContent(bytes::Vector{UInt8}; size::Integer = length(bytes), link::Function = no_link,
            raw_html::Bool = true) = FileContent(bytes, Int(size), link, raw_html)

no_link(_) = nothing

# A copy: `String` takes over the vector it is given.
content_text(c::FileContent) = String(copy(c.bytes))

# The file-view driver as a node, for a viewer built without its session. A
# second one in a page is a no-op.
struct FileViewDriver end
Bonito.jsrender(session::Bonito.Session, ::FileViewDriver) =
    Bonito.jsrender(session, file_view_driver(session))

file_viewer(::MeshFile, url, path::AbstractString, mode::ViewMode = InlineView()) =
    MeshViewer(url, path; mode)

# A picture in a bubble at its own size; `worker_path` lets it become the chat's
# icon (chat_icons.jl).
file_viewer(::ImageFile, url, path::AbstractString, ::InlineView = InlineView(); worker_path = "") =
    media_element(url, "", false; filename = basename(path), worker_path)

# Filling a box, it gets a stage: a checkerboard so transparency reads as
# transparency, and the picture shrunk to fit. The driver reports its pixel size
# into a file tab's header.
file_viewer(::ImageFile, url, path::AbstractString, ::PanelView) =
    DOM.div(FileViewStyles, FileViewDriver(), media_element(url, "", false; filename = basename(path));
            class = "bt-fv-image-stage")

video_viewer(url, path::AbstractString) =
    media_element(url, get(SHOW_VIDEO_MIME, lowercase(splitext(path)[2]), "video/mp4"), true;
                  filename = basename(path))

# In a chat bubble the video belongs in the message flow, at its own size.
file_viewer(::VideoFile, url, path::AbstractString, ::InlineView = InlineView()) = video_viewer(url, path)

# Filling a box it needs a stage, like a picture does. Without one the element
# sits at its intrinsic size in the top-left corner of an otherwise empty tab, and
# a video TALLER than the box runs off the bottom, taking its controls with it,
# because `media_element` only constrains width.
file_viewer(::VideoFile, url, path::AbstractString, ::PanelView) =
    DOM.div(FileViewStyles, video_viewer(url, path); class = "bt-fv-video-stage")

file_viewer(::AudioFile, url, path::AbstractString, ::ViewMode = InlineView()) =
    DOM.div(FileViewStyles,
        DOM.audio(DOM.source(; src = url, type = get(VIEW_AUDIO_MIME, lowercase(splitext(path)[2]), "audio/mpeg"));
                  controls = true, class = "bt-fv-audio"),
        DOM.div(basename(path); class = "bt-fv-audio-name");
        class = "bt-fv-audio-wrap")

# What the chat gives a kind's viewer: where the browser reads the file, or
# what it holds (mirrored to the server, `view_bytes`).
render_file(kind::FileKind, mode::ViewMode, fv::FileView, session) =
    file_viewer(kind, view_input(kind, fv, session), view_path(fv), mode)

view_input(::StreamedKind, fv::FileView, session) = show_media_src(fv.file, session)
view_input(::ParsedKind, fv::FileView, session) = FileContent(last(view_bytes(fv)); link = file_link(fv))

render_file(::ImageFile, ::InlineView, fv::FileView, session) =
    file_viewer(ImageFile(), view_input(ImageFile(), fv, session), view_path(fv), InlineView();
                worker_path = show_worker_path(fv.file))

# ── markdown ────────────────────────────────────────────────────────────────
# The SAME renderer the chat uses for agent messages (`markdown_html`), so a
# README reads exactly like a message: GitHub-ish CSS, tables, code blocks. Its
# relative pictures and clips go through `link` (`file_link`): the preview sits
# in the dashboard page, where the browser would resolve them against the
# dashboard's own URL.
markdown_preview_node(text::AbstractString, link::Function; raw_html::Bool = true) =
    DOM.div(FileViewStyles, Bonito.HTML(markdown_html(text, link; raw_html)); class = "bt-fv-markdown")

file_viewer(::MarkdownFile, c::FileContent, path::AbstractString, ::ViewMode = InlineView()) =
    looks_binary(c.bytes) ? hexdump_node(c) : markdown_preview_node(content_text(c), c.link; c.raw_html)

# Where a path relative to `fv`'s file is read from: that file on the worker,
# as a signed link (`worker_folder_url`), streamed when the browser asks and
# never copied. Granted on the project (`reference_folder`), so `../figs/` within
# it reaches; a path that leaves the grant, or any in a chat with no project, is
# left as written.
function file_link(fv::FileView)
    st = fv.file
    proj = get(st.state.projects[], st.project_id, nothing)
    proj === nothing && return no_link
    file = show_worker_path(st)
    folder = reference_folder(proj, file)
    return function (rel)
        path = normpath(joinpath(dirname(file), rel))
        Bonito.is_path_contained(folder, path) || return nothing
        return worker_folder_url(st.state, proj.worker_id, folder, relpath(path, folder))
    end
end

# ── delimited text (csv / tsv) ──────────────────────────────────────────────
# A real table, not a Monaco pane of commas: sticky header, row numbers,
# right-aligned numerics, click-to-sort, and a filter box. That combination is
# the "better than an editor" part — you open a CSV to look at the DATA.

# RFC4180-ish: double quotes group, `""` escapes a quote inside a quoted field.
# Deliberately tolerant — a preview must render the messy CSVs too.
#
# One pass over the string, no `collect` — a 16 MB CSV would otherwise become a
# 64 MB `Vector{Char}` before a single row is parsed. The `""` escape is handled
# with a one-character latch (`pending_quote`) instead of lookahead, so nothing
# needs random access.
function parse_delimited(text::AbstractString, delim::Char)
    rows = Vector{Vector{String}}()
    field = IOBuffer()
    row = String[]
    inquote = false
    pending_quote = false     # saw `"` inside a quoted field; next char decides
    for c in text
        if pending_quote
            pending_quote = false
            if c == '"'
                print(field, '"')     # `""` → a literal quote, still quoted
                continue
            end
            inquote = false           # the quote closed the field; fall through
        end
        if inquote
            c == '"' ? (pending_quote = true) : print(field, c)
        elseif c == '"'
            inquote = true
        elseif c == delim
            push!(row, String(take!(field)))
        elseif c == '\n'
            push!(row, String(take!(field)))
            push!(rows, row); row = String[]
        elseif c != '\r'
            print(field, c)
        end
    end
    # A trailing newline leaves an empty pending row; a file with no trailing
    # newline leaves a real one. Distinguish by "did we accumulate anything".
    last_field = String(take!(field))
    if !isempty(last_field) || !isempty(row)
        push!(row, last_field)
        push!(rows, row)
    end
    return rows
end

# Rows past this stay out of the DOM — a 500k-row CSV would otherwise lock the
# tab. The header says so explicitly; nothing is silently dropped.
const TABLE_MAX_ROWS = 5_000

is_numeric_cell(s::AbstractString) = tryparse(Float64, strip(s)) !== nothing

function file_viewer(::TableFile, c::FileContent, path::AbstractString, mode::ViewMode = InlineView())
    looks_binary(c.bytes) && return hexdump_node(c)
    delim = lowercase(splitext(path)[2]) == ".tsv" ? '\t' : ','
    rows = parse_delimited(content_text(c), delim)
    isempty(rows) && return DOM.div("(empty table)"; class = "bt-tool-empty")
    header = rows[1]
    body   = @view rows[2:end]
    ncols  = maximum(length, rows)
    shown  = min(length(body), mode isa InlineView ? 50 : TABLE_MAX_ROWS)
    # Column alignment from the DATA, not the header: a column is numeric when
    # every non-empty cell in the shown window parses as a number.
    numeric = [all(r -> length(r) < c || isempty(strip(r[c])) || is_numeric_cell(r[c]),
                   @view body[1:shown]) for c in 1:ncols]

    cell(r, c) = length(r) < c ? "" : r[c]
    head = DOM.tr(DOM.th("#"; class = "bt-fv-rownum"),
        (DOM.th(DOM.span(cell(header, c); class = "bt-fv-th-label"),
                DOM.span("⇅"; class = "bt-fv-sort-arrow");
                dataCol = string(c),
                class = numeric[c] ? "bt-fv-num bt-fv-sortable" : "bt-fv-sortable")
         for c in 1:ncols)...)
    trs = [DOM.tr(DOM.td(string(i); class = "bt-fv-rownum"),
                  (DOM.td(cell(body[i], c); class = numeric[c] ? "bt-fv-num" : "")
                   for c in 1:ncols)...)
           for i in 1:shown]

    note = shown < length(body) ?
        "showing the first $(shown) of $(length(body)) rows" :
        "$(length(body)) rows · $(ncols) columns"
    table = DOM.table(DOM.thead(head), DOM.tbody(trs...); class = "bt-fv-table")
    filter_box = DOM.input(; type = "text", class = "bt-fv-table-filter",
        placeholder = "Filter rows…", spellcheck = "false")
    # Sort + filter are wired by the file-view driver when this node appears
    # (assets/fileview.js); see `file_view_driver` for why the behaviour can't
    # ride along with the node.
    return DOM.div(FileViewStyles, FileViewDriver(),
        DOM.div(filter_box, DOM.span(note; class = "bt-fv-table-note");
                class = "bt-fv-table-bar"),
        DOM.div(table; class = "bt-fv-table-scroll");
        class = "bt-fv-table-wrap")
end

# ── Jupyter notebook ────────────────────────────────────────────────────────
# Cells in order: markdown rendered, code in a read-only Monaco with the
# notebook's own language, and outputs (stream text, results, images, errors)
# under each code cell — which is the bit a plain editor can't do at all.
notebook_source(cell) = begin
    src = get(cell, "source", "")
    src isa AbstractString ? String(src) : join(String.(src))
end

function notebook_output_node(out::AbstractDict)
    otype = String(get(out, "output_type", ""))
    data  = get(out, "data", Dict{String,Any}())
    if data isa AbstractDict
        for (mime, ext) in ("image/png" => "png", "image/jpeg" => "jpeg", "image/gif" => "gif")
            haskey(data, mime) || continue
            payload = data[mime]
            b64 = payload isa AbstractString ? String(payload) : join(String.(payload))
            return DOM.img(; src = "data:$(mime);base64,$(replace(b64, "\n" => ""))",
                             class = "bt-fv-nb-image")
        end
        if haskey(data, "text/plain")
            txt = data["text/plain"]
            return DOM.pre(txt isa AbstractString ? String(txt) : join(String.(txt));
                           class = "bt-fv-nb-text")
        end
    end
    if otype == "stream"
        txt = get(out, "text", "")
        return DOM.pre(txt isa AbstractString ? String(txt) : join(String.(txt));
                       class = "bt-fv-nb-text")
    end
    if otype == "error"
        tb = get(out, "traceback", String[])
        body = tb isa AbstractString ? String(tb) : join(String.(tb), "\n")
        return console_block(body)
    end
    return DOM.pre("($(isempty(otype) ? "output" : otype))"; class = "bt-fv-nb-text")
end

function file_viewer(::NotebookFile, c::FileContent, path::AbstractString, mode::ViewMode = InlineView())
    nb = JSON.parse(content_text(c))
    lang = get(get(get(nb, "metadata", Dict()), "kernelspec", Dict()), "language", "python")
    cells = get(nb, "cells", [])
    isempty(cells) && return DOM.div("(notebook has no cells)"; class = "bt-tool-empty")
    limit = mode isa InlineView ? 12 : length(cells)
    nodes = Any[]
    for cell in Iterators.take(cells, limit)
        ctype = String(get(cell, "cell_type", "code"))
        src = notebook_source(cell)
        if ctype == "markdown"
            push!(nodes, DOM.div(markdown_preview_node(src, c.link; c.raw_html); class = "bt-fv-nb-cell bt-fv-nb-md"))
        else
            outs = get(cell, "outputs", [])
            push!(nodes, DOM.div(
                DOM.div(monaco_readonly(src, String(lang)); class = "bt-fv-nb-source"),
                (isempty(outs) ? () :
                    (DOM.div((notebook_output_node(o) for o in outs if o isa AbstractDict)...;
                             class = "bt-fv-nb-outputs"),))...;
                class = "bt-fv-nb-cell bt-fv-nb-code"))
        end
    end
    limit < length(cells) &&
        push!(nodes, DOM.div("… $(length(cells) - limit) more cells (open the file to see them all)";
                             class = "bt-fv-more"))
    return DOM.div(FileViewStyles, nodes...; class = "bt-fv-notebook")
end

# ── The window-level driver ─────────────────────────────────────────────────
# `Bonito.onload(session, node, js)` queues onto the SESSION's document-load
# list, so it runs when that session's document is shown — NOT when the node is
# inserted. Every interesting file body is built off the session task (a worker
# round-trip for a media url, a mesh parse, a table read) and arrives later as an
# Observable update, which makes "did my onload make the flush?" a race against
# how long the fetch took. It was silently lost for images and meshes and won by
# a small CSV, which is the worst kind of bug: no error, just a dead node.
#
# So the per-kind behaviour is installed ONCE per window and adopts nodes as they
# appear, however they were delivered — inline in a chat bubble, in a panel, or
# moved between the two by the workspace.
const FileViewLib = Bonito.ES6Module(joinpath(@__DIR__, "..", "assets", "fileview.js"))
# The 3D viewer is three.js, most of a megabyte: loaded once a model is on screen.
const MeshLib     = Bonito.ES6Module(joinpath(@__DIR__, "..", "assets", "meshview.js"))

"""
    file_view_driver(session) -> Node

An invisible node whose load installs the file-viewer driver for this window.
Mount it once per window (the shell does); a `FilePanel` rendered on its own asks
for it too, and the second request is a no-op.
"""
function file_view_driver(session::Bonito.Session)
    node = DOM.span(""; class = "bt-fv-driver", style = "display:none")
    Bonito.onload(session, node, js"""(el) => {
        $(FileViewLib).then(fv => fv.install(() => $(MeshLib)));
    }""")
    return node
end
file_view_driver(::Nothing) = DOM.span("")   # headless render: no browser to drive

# ── 3D geometry ─────────────────────────────────────────────────────────────

# The viewers' toolbar. Icons are drawn, not typed: a symbol like ⌗ needs a font
# that has it, and without one the button paints empty.
mesh_icon(shapes...) = Bonito.SVG.svg(shapes...;
    viewBox = "0 0 16 16", fill = "none", stroke = "currentColor",
    var"stroke-width" = "1.4", var"stroke-linecap" = "round", var"stroke-linejoin" = "round",
    var"aria-hidden" = "true")
mesh_icon(::Val{:reset}) = mesh_icon(Bonito.SVG.path(d = "M2.5 7.5 8 3l5.5 4.5"),
                                     Bonito.SVG.path(d = "M4 6.5V13h8V6.5"))
# A triangle split into four: the edges the overlay draws.
mesh_icon(::Val{:wire}) = mesh_icon(Bonito.SVG.path(d = "M8 2.5 13.5 13h-11z"),
                                    Bonito.SVG.path(d = "M5.25 7.75h5.5L8 13z"))
# One facet lit, one in shade.
mesh_icon(::Val{:flat}) = mesh_icon(Bonito.SVG.path(d = "M8 2.5 13.5 13h-11z"),
                                    Bonito.SVG.path(d = "M8 2.5V13h5.5z"; fill = "currentColor"))

mesh_button(action::Symbol, title) = DOM.button(mesh_icon(Val(action)); class = "bt-mesh-btn",
    type = "button", title = title, dataMeshAction = string(action), dataOn = "0")

# The folder a file's relative references (a glTF's buffers and textures, an
# OBJ's .mtl, a markdown file's pictures) resolve in: its project, so
# `../textures/` reaches, or its own folder for a file outside any project.
reference_folder(proj::ProjectInfo, path::String) =
    Bonito.is_path_contained(proj.worker_path, path) ? proj.worker_path : dirname(path)

# Where the browser reads a model from: the worker's file, through a signed URL
# for its folder, so whatever the model names next to it is fetched the same way
# when the loader asks. A link, never a copy (see `show_media_src`): a worker
# that does not answer is reported as such. A chat with no project, which has no
# worker to link to, gets the server's copy of the model alone (what it names is
# then out of reach).
function mesh_src(st::ShowTool, session)
    proj = get(st.state.projects[], st.project_id, nothing)
    if proj === nothing
        src = mirror_src(st, session)
        check_view_size(MeshFile(), filesize(show_server_path(st)))
        return src
    end
    info = stat_worker_path(st.state, proj.worker_id, show_worker_path(st))
    info.isfile || error("no such file on the worker: $(info.path)")
    check_view_size(MeshFile(), info.size)
    folder = reference_folder(proj, info.path)
    return worker_folder_url(st.state, proj.worker_id, folder, relpath(info.path, folder))
end

# The browser reads the model itself, with three.js's loader for its format
# (assets/meshview.js).
view_input(::MeshFile, fv::FileView, session) = mesh_src(fv.file, session)

"""
    MeshViewer(url, path; mode = InlineView())

three.js viewer for the model at `url` (format from `path`), with its toolbar,
status line, styles and driver, so it works in any session. `PanelView()` fills
its container; `InlineView()` is a box of its own height.
"""
struct MeshViewer
    url::Any
    format::String
    mode::ViewMode
end
MeshViewer(url, path::AbstractString; mode::ViewMode = InlineView()) =
    MeshViewer(url, String(lstrip(lowercase(splitext(path)[2]), '.')), mode)

# The url rides on the node as a data attribute; the driver (installed once per
# page, a second install is a no-op) mounts the viewer when the node appears.
Bonito.jsrender(session::Bonito.Session, v::MeshViewer) = Bonito.jsrender(session, DOM.div(
    MeshViewStyles, file_view_driver(session),
    DOM.canvas(; class = "bt-mesh-canvas"),
    DOM.div(
        mesh_button(:reset, "Reset the view"),
        mesh_button(:wire, "Wireframe overlay"),
        mesh_button(:flat, "Flat shading");
        class = "bt-mesh-toolbar"),
    DOM.div(""; class = "bt-mesh-status");
    class = "bt-mesh-view", dataMeshUrl = v.url, dataMeshFormat = v.format,
    dataMode = v.mode isa InlineView ? "inline" : "panel"))

# ── pdf / html ──────────────────────────────────────────────────────────────
# Both are handed to the browser as a URL: the embedded PDF viewer and a real
# HTML render beat anything we could reconstruct. The HTML frame is sandboxed
# (scripts allowed, same-origin NOT) so a page in the project can't reach into
# the dashboard's session.

file_viewer(::PDFFile, url, path::AbstractString, ::ViewMode = InlineView()) = frame_viewer(url, path)
# The page runs, in an origin of its own: it cannot reach the page around it.
file_viewer(::HTMLFile, url, path::AbstractString, ::ViewMode = InlineView()) =
    frame_viewer(url, path; sandbox = "allow-scripts")

frame_viewer(src, path::AbstractString; sandbox = nothing) =
    DOM.div(FileViewStyles, FileViewDriver(),
            frame_element(src, basename(path), sandbox === nothing ? (;) : (; sandbox));
            class = "bt-fv-frame-wrap")

# The url rides as `data-frame-src` and the file-view driver assigns it once the
# frame is in the document. An `<iframe src=…>` that arrives ALREADY sourced
# through Bonito's node insertion leaves Chromium's PDF plugin without a live
# view: the panel shows the viewer's dark backdrop and nothing else. See
# `initFrame` in assets/fileview.js.
frame_element(src::AbstractString, title::AbstractString, sandbox::NamedTuple) =
    DOM.iframe(; class = "bt-fv-frame", dataFrameSrc = src, title, sandbox...)
# A headless render (no session) has an `Asset` rather than a url, and no driver
# to hand it to either: there `src` is the only option.
frame_element(src::Bonito.Asset, title::AbstractString, sandbox::NamedTuple) =
    DOM.iframe(; src, class = "bt-fv-frame", title, sandbox...)

# ── plain text ──────────────────────────────────────────────────────────────
# Highlighting follows the worker path, not the mirror's. Inline the editor is
# as tall as the text; `PanelView` fills the box and scrolls.
file_viewer(::TextFile, c::FileContent, path::AbstractString, ::InlineView = InlineView()) =
    looks_binary(c.bytes) ? hexdump_node(c) : monaco_readonly(content_text(c), detect_language(path))

file_viewer(::TextFile, c::FileContent, path::AbstractString, mode::PanelView) =
    looks_binary(c.bytes) ? hexdump_node(c) :
        DOM.div(FileViewStyles, monaco_readonly(content_text(c), detect_language(path), mode); class = "bt-fv-code")

monaco_readonly(text::AbstractString, lang::AbstractString, ::PanelView) =
    BonitoBook.MonacoEditor(text; language = lang, readOnly = true, automaticLayout = true,
        scrollBeyondLastLine = false, minimap = Dict(:enabled => false),
        # Light, as everywhere (see `monaco_readonly`).
        theme = Observable("vs"))

# ── binary ──────────────────────────────────────────────────────────────────
# A hex + ASCII dump of the head. Enough to answer "is this actually a PNG?" /
# "what magic does this blob start with?", which is the only useful thing a
# viewer can say about opaque bytes.
const HEXDUMP_BYTES = 2048

function hexdump_text(bytes::AbstractVector{UInt8}; limit::Int = HEXDUMP_BYTES)
    io = IOBuffer()
    n = min(length(bytes), limit)
    for off in 0:16:(n - 1)
        stop = min(off + 16, n)
        chunk = @view bytes[(off + 1):stop]
        print(io, uppercase(string(off; base = 16, pad = 8)), "  ")
        for i in 1:16
            i <= length(chunk) ? print(io, uppercase(string(chunk[i]; base = 16, pad = 2)), " ") :
                                 print(io, "   ")
            i == 8 && print(io, ' ')
        end
        print(io, " |")
        for b in chunk
            print(io, (0x20 <= b <= 0x7e) ? Char(b) : '.')
        end
        println(io, "|")
    end
    return String(take!(io))
end

hexdump_node(c::FileContent) = hexdump_node(c.bytes, c.size)

# `total`: the whole file's size, when `bytes` is its head.
function hexdump_node(bytes::AbstractVector{UInt8}, total::Integer = length(bytes))
    shown = min(length(bytes), HEXDUMP_BYTES)
    note = shown < total ?
        "first $(format_bytes(shown)) of $(format_bytes(total))" :
        format_bytes(total)
    return DOM.div(FileViewStyles,
        DOM.div(DOM.span("binary"; class = "bt-fv-badge"),
                DOM.span(note; class = "bt-fv-hex-note");
                class = "bt-fv-hex-bar"),
        DOM.pre(hexdump_text(bytes); class = "bt-fv-hex");
        class = "bt-fv-hex-wrap")
end

file_viewer(::BinaryFile, c::FileContent, path::AbstractString, ::ViewMode = InlineView()) = hexdump_node(c)

# ── The workspace tab ───────────────────────────────────────────────────────
# One header for EVERY kind, so opening a png, a csv and a .jl file all feel
# like the same app: kind glyph · the worker path · size/kind badge · status ·
# actions. The body is the kind's renderer from above, plus — for anything
# text-backed — an editable Monaco behind a Preview/Source toggle.
#
# Why the worker path and not the mirror path: that IS the file. The server-side
# copy is transport. Showing `/tmp/bonitoagents-dev-work-xyz/README.md` when the
# user opened `~/code/proj/README.md` made the header actively misleading.

struct FilePanel
    view        :: FileView                    # always PanelView mode
    kind        :: FileKind                    # may DOWNGRADE to BinaryFile after the NUL sniff
    worker_path :: String                      # absolute, on the worker — what the header shows
    size_bytes  :: Int                         # worker-side size at open (header); -1 = unknown
    editor      :: Union{FileEditor,Nothing}   # text-backed kinds only
    reload      :: Observable{Int}             # bump → re-fetch + rebuild the rendered body
end

"""
    FilePanel(state, project_id, server_cwd, path) -> FilePanel

Build the workspace-tab view of the worker file at `path`. Blocks on the fetch
for kinds whose bytes we have to parse (text, csv, notebooks, geometry); media
kinds only resolve a streaming url, so they open instantly regardless of size.

Throws on a file we can't open at all (too large for its kind, unreadable, no
worker) — [`open_project_file!`](@ref) turns that into a toast rather than an
empty panel.
"""
function FilePanel(state::ServerState, project_id::AbstractString,
                   server_cwd::AbstractString, path::AbstractString)
    st = ShowTool(state, String(project_id), String(server_cwd), String(path))
    fv = FileView(st, PanelView())
    kind = file_kind(path)
    worker_path = show_worker_path(st)
    # Captured HERE (this runs on the opener's async task, which is allowed to
    # block) rather than during `jsrender` — a stat is a worker round-trip, and
    # rendering happens on the session's task, which must not wait on the network.
    stamp = worker_file_stamp(st, worker_path)
    editor = nothing
    if kind isa TextFile || has_source_view(kind, path)
        # Reuses the stat above, so a text file opens on ONE worker round-trip
        # plus the transfer instead of three.
        local_path, bytes = view_bytes(fv; stamp)
        if looks_binary(bytes)
            # Extension lied (a `.txt` that's really a blob). The hex preview is
            # the honest answer, and there's nothing safe to edit.
            kind = BinaryFile()
        elseif length(bytes) <= FILE_EDITOR_MAX_BYTES
            editor = FileEditor(state, project_id, local_path, worker_path)
        end
    end
    return FilePanel(fv, kind, worker_path, stamp === nothing ? -1 : stamp.size,
                     editor, Observable(0))
end

# Does this panel show something OTHER than the raw source? A .jl file is source
# and nothing else; a README has a rendered view the source toggle switches away
# from.
has_rendered_view(p::FilePanel) = !(p.kind isa TextFile)

# The panel's initial view: rendered when there is one, else source. Also the
# value of the root's `data-view`, which the CSS keys on.
initial_view(p::FilePanel) = has_rendered_view(p) ? "preview" : "source"

# Header action buttons. Kept as plain glyph buttons with real `title`s rather
# than a menu: there are four of them and they're all one click.
fv_action_btn(action, glyph, title) =
    DOM.button(glyph; class = "bt-fv-act", type = "button", title = title, dataFvAction = action)

"""
    disambiguate_labels(paths) -> Vector{String}

Tab labels for a set of open files: the basename, unless another open file has
the SAME basename — then every file in that collision grows leftwards, one path
segment at a time, until the labels tell them apart.

`src/a/types.jl` and `src/b/types.jl` are not an edge case in a Julia project,
they are Tuesday; two tabs both reading `types.jl` is a coin flip every time you
switch. Only the colliding names grow, so the common case stays short.
"""
function disambiguate_labels(paths::AbstractVector{<:AbstractString})
    segs = [splitpath(String(p)) for p in paths]
    n = ones(Int, length(paths))
    # `joinpath`, not `join(…, "/")`: the first segment of an absolute path IS
    # the root separator, and joining that by hand yields "//f.jl".
    label(i) = joinpath(segs[i][max(1, lastindex(segs[i]) - n[i] + 1):end]...)
    labels = String[label(i) for i in eachindex(paths)]
    while true
        groups = Dict{String,Vector{Int}}()
        for (i, l) in enumerate(labels)
            push!(get!(Vector{Int}, groups, l), i)
        end
        # `grew` also terminates the genuinely unresolvable case (two panels on
        # the same path): every candidate is already at its full length.
        grew = false
        for (_, idxs) in groups
            length(idxs) < 2 && continue
            for i in idxs
                n[i] < length(segs[i]) && (n[i] += 1; grew = true)
            end
        end
        grew || return labels
        labels = String[label(i) for i in eachindex(paths)]
    end
end

"""
    path_span(path; class, title = path) -> Node

A file path that ellipsises from the LEFT, so the filename — the part you are
actually looking for — survives truncation.

`class` supplies the left-truncation (`direction: rtl`); this wraps the text in
the `.bt-path-ltr` run that keeps its characters in order. Both halves are
required: `direction: rtl` alone renders `/tmp/x.png` as `tmp/x.png/`, because
the leading `/` is bidi-neutral and lands at the visual end of an RTL run.
"""
path_span(path::AbstractString; class::AbstractString, title = path) =
    DOM.span(DOM.span(String(path); class = "bt-path-ltr"); class = class, title = title)

# The review header's repo line is an Observable — it re-renders when you compare
# against a different base — so there is no fixed string to hang a tooltip on.
path_span(path::Observable; class::AbstractString) =
    DOM.span(DOM.span(path; class = "bt-path-ltr"); class = class)

# A file of a chat's project can be shared as a link (shares.jl).
share_btn(p::FilePanel) =
    isempty(p.view.file.project_id) ? () :
        (fv_action_btn("share", "↗", "Share a link: anyone with it can open this " *
                       "while the worker is online (Settings lists and ends links)"),)

function file_panel_header(session::Session, p::FilePanel)
    size_txt = p.size_bytes < 0 ? "" : format_bytes(p.size_bytes)
    toggle = has_rendered_view(p) && p.editor !== nothing ?
        (DOM.div(
            DOM.button("Preview"; class = "bt-fv-seg", type = "button", dataFvView = "preview"),
            DOM.button("Source"; class = "bt-fv-seg", type = "button", dataFvView = "source");
            class = "bt-fv-segmented"),) : ()
    # The shortcut is ON the button, not only in its tooltip. Ctrl+S is the one
    # thing people try here without looking, and a tooltip is invisible to anyone
    # who never hovers a button they already know how to click.
    save_btn = p.editor === nothing ? () :
        (DOM.button("Save", DOM.span("Ctrl+S"; class = "bt-btn-kbd");
                    class = "bt-btn bt-btn-sm bt-file-editor-save", type = "button",
                    title = "Write this file on the worker"),)
    status = p.editor === nothing ? Observable("") : p.editor.status
    return DOM.div(
        DOM.span(kind_icon(p.kind); class = "bt-fv-icon"),
        # The full worker path, ellipsised from the LEFT so the filename — the
        # part you're looking for — is always visible.
        path_span(p.worker_path; class = "bt-file-editor-path bt-fv-path"),
        DOM.span(kind_label(p.kind); class = "bt-fv-badge"),
        DOM.span(size_txt; class = "bt-fv-size"),
        DOM.span(""; class = "bt-fv-dims"),
        DOM.span(status; class = "bt-file-editor-status bt-fv-status"),
        DOM.div(
            toggle...,
            fv_action_btn("copy", "⧉", "Copy the worker path"),
            fv_action_btn("download", "⤓", "Download to this computer"),
            fv_action_btn("reload", "⟳", "Reload from the worker"),
            share_btn(p)...,
            save_btn...;
            class = "bt-fv-actions");
        class = "bt-file-editor-header bt-fv-header")
end

function Bonito.jsrender(session::Session, p::FilePanel)
    # The rendered half is built OFF the session task and swapped in when it's
    # ready. Every heavy kind lives here — a mesh gets parsed, a table gets read
    # and split, a media url costs a worker round-trip — and doing that inside the
    # render would park the tab's session task for as long as it takes, freezing
    # every other Observable in the window. So: mount a placeholder, then fill it.
    #
    # Each rebuild goes back through `fetch_show_file`, which re-transfers exactly
    # when the worker file changed — so ⟳ (and a save) genuinely refresh rather
    # than redraw stale bytes.
    rendered_dom = Observable{Any}(DOM.div("loading…"; class = "bt-fv-loading"))
    build_rendered() = viewer_or_error(() -> render_file(p.kind, PanelView(), p.view, session), p.worker_path)
    refresh_rendered!() = Base.errormonitor(@async safe_set!(rendered_dom, build_rendered()))
    has_rendered_view(p) && refresh_rendered!()
    # ⟳ has to reload whatever this panel actually SHOWS. Registering the handler
    # only for kinds with a rendered view meant that on a plain source file — the
    # commonest tab there is — the button flashed "reloaded" and reloaded nothing:
    # no handler was listening, and the editor's text is refreshed elsewhere
    # (`refresh_file_panel!`, on re-activation). So both halves, always.
    on(session, p.reload) do _
        has_rendered_view(p) && refresh_rendered!()
        fe = p.editor
        fe === nothing && return
        Base.errormonitor(@async begin
            fetch_show_file(p.view.file)
            isfile(fe.server_path) && safe_set!(fe.reload, read(fe.server_path, String))
        end)
        # NOT reported here: that a file we could not read on the worker is being
        # served from the last mirror. `fetch_show_file` falls back silently, so ⟳
        # on a deleted file shows the old text as if it were current. Writing that
        # into `fe.status` from here throws in the browser
        # ("Cannot set properties of null") — the binding this observable feeds is
        # not live on this path — so the honest note is in COVERAGE.md rather than
        # a message that only half arrives.
    end
    rendered = has_rendered_view(p) ?
        (DOM.div(rendered_dom; class = "bt-fv-rendered"),) : ()
    source = p.editor === nothing ? () : (DOM.div(p.editor; class = "bt-fv-source"),)

    body = DOM.div(rendered..., source...; class = "bt-file-editor-body bt-fv-body")
    # The panel ROOT is part of this render pass, so its own `onload` is reliable
    # — which makes it the right place to ask for the driver that the panel's
    # asynchronously-delivered body depends on.
    node = DOM.div(file_view_driver(session), file_panel_header(session, p), body;
                   class = "bt-file-view bt-file-editor",
                   dataKind = kind_label(p.kind),
                   dataView = initial_view(p))

    # A save must also refresh the rendered half — the whole point of editing a
    # README's source is seeing the preview update.
    p.editor === nothing || on(session, p.editor.mark_clean) do _
        safe_set!(p.reload, p.reload[] + 1)
    end

    download_url = isempty(p.view.file.project_id) ? "" :
        "/download/" * HTTP.URIs.escapeuri(p.view.file.project_id) *
        "?path=" * HTTP.URIs.escapeuri(p.worker_path)
    save_obs = p.editor === nothing ? Observable{Union{Nothing,String}}(nothing) : p.editor.save_content

    # ↗: the link, or why there is none ("link:…" / "error:…"). Made off the
    # session task: an app is evaluated once first, which can take a minute.
    share_request = Observable(0)
    share_answer = Observable("")
    on(session, share_request) do _
        Base.errormonitor(@async begin
            answer = try
                "link:" * share_project_file!(p.view.file.state, p.view.file.project_id, p.worker_path)
            catch e
                (e isa ErrorException || e isa WorkerUnreachableError) || rethrow()
                @warn "sharing a file failed" path = p.worker_path exception = (e, catch_backtrace())
                "error:" * first(split(sprint(showerror, e), '\n'))
            end
            safe_set!(share_answer, answer)
        end)
    end

    Bonito.onload(session, node, js"""(root) => {
        const reload = $(p.reload);
        const save   = $(save_obs);
        const shareRequest = $(share_request);
        const shareAnswer  = $(share_answer);
        const wpath  = $(p.worker_path);
        const dlurl  = $(download_url);

        const editorOf = () => root.querySelector('.monaco-editor-div')?.__btEditor;
        const flash = (msg) => {
            const s = root.querySelector('.bt-fv-status');
            if (!s) return;
            s.textContent = msg;
            clearTimeout(root.__btFlash);
            root.__btFlash = setTimeout(() => { if (s.textContent === msg) s.textContent = ''; }, 2500);
        };
        const doSave = () => { const ed = editorOf(); if (ed) save.notify(ed.getValue()); };
        // The link stays in the status line (selectable) until the next action.
        shareAnswer.on(m => {
            const s = root.querySelector('.bt-fv-status');
            if (!s || !m) return;
            clearTimeout(root.__btFlash);
            if (m.startsWith('link:')) {
                const url = m.slice(5);
                s.textContent = 'shared: ' + url;
                ($(COPY_TEXT_JS))(url).then(() => { s.textContent = 'link copied: ' + url; }, () => {});
            } else {
                s.textContent = 'not shared: ' + m.slice(6);
            }
        });

        const setView = (v) => {
            root.dataset.view = v;
            root.querySelectorAll('.bt-fv-seg').forEach(
                b => b.dataset.active = (b.dataset.fvView === v) ? '1' : '0');
            // Monaco measures itself on mount; one that mounted while hidden has
            // a zero-size layout cached, so re-layout on the way in.
            if (v === 'source') requestAnimationFrame(() => editorOf()?.layout());
        };
        setView(root.dataset.view || 'preview');

        root.addEventListener('click', (e) => {
            const seg = e.target.closest('.bt-fv-seg');
            if (seg) { setView(seg.dataset.fvView); return; }
            if (e.target.closest('.bt-file-editor-save')) { doSave(); return; }
            const act = e.target.closest('.bt-fv-act');
            if (!act) return;
            if (act.dataset.fvAction === 'reload') {
                reload.notify(Date.now());
                const ed = editorOf();
                // A dirty buffer is the user's work: reload refreshes the
                // rendered half and says so rather than silently keeping the
                // editor stale (the Julia side never clobbers dirty buffers).
                flash(ed && ed.getValue() !== ed.__btOriginal ?
                      'reloaded preview — editor keeps your unsaved edits' : 'reloaded');
            } else if (act.dataset.fvAction === 'copy') {
                ($(COPY_TEXT_JS))(wpath).then(() => flash('path copied'), () => flash('could not copy'));
            } else if (act.dataset.fvAction === 'share') {
                const s = root.querySelector('.bt-fv-status');
                if (s) { clearTimeout(root.__btFlash); s.textContent = 'sharing…'; }
                shareRequest.notify(Date.now());
            } else if (act.dataset.fvAction === 'download') {
                if (!dlurl) { flash('no project to download from'); return; }
                const a = document.createElement('a');
                a.href = dlurl; a.download = '';
                document.body.appendChild(a); a.click(); a.remove();
            }
        });

        // Ctrl+S anywhere in the panel — capture phase beats Monaco's own binding.
        root.addEventListener('keydown', (e) => {
            if ((e.ctrlKey || e.metaKey) && e.key === 's') {
                e.preventDefault(); e.stopPropagation();
                if (root.dataset.view !== 'source') setView('source');
                doSave();
            }
        }, true);
    }""")
    return Bonito.jsrender(session, node)
end

"""
    refresh_file_panel!(p::FilePanel)

Bring an already-open panel back in sync with the worker: re-fetch (a no-op when
the worker's `(size, mtime)` still matches the mirror), rebuild the rendered
half, and offer the fresh text to the editor. The editor's JS side applies it
only to a CLEAN buffer, so unsaved edits are never clobbered.

Same path as the ⟳ button, so the two cannot drift apart.
"""
refresh_file_panel!(p::FilePanel) =
    # One implementation, in the `p.reload` handler that ⟳ also drives — the fetch,
    # the editor hand-off and the rendered rebuild all live there. `safe_set!`
    # because a panel whose tab (or whole window) has gone away must not turn a
    # background refresh into an unhandled error on the caller's task.
    (safe_set!(p.reload, p.reload[] + 1); nothing)
