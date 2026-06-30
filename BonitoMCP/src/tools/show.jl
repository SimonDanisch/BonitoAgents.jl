# bt_show — display a file from the worker's disk in the chat as a
# collapsible preview. Trivial wrapper: takes a path, returns a `shown:`
# text reference. The chat-side render_tool_body parses the reference,
# fetches the file via the worker control WS's fetch_blob command, and
# renders an inline preview based on the file's extension/MIME.
#
# bt_julia_eval already auto-saves rich values to <env>/.bonitoAgents/show/
# when their richest MIME is image/HTML/SVG, so the typical flow is:
#
#   1. agent calls bt_julia_eval(some_makie_figure) — gets `shown: …`
#      reference back alongside the text repr; bytes stay on disk
#   2. agent decides the user should see it; calls bt_show(path=…)
#      with the path from step 1, OR with any other file already on
#      the worker's disk (downloads, generated files, etc.)
#
# The bt_show response intentionally has no MIME chain or eval — those
# live in bt_julia_eval. Here we just emit a reference; the chat side
# infers MIME from the extension at render time.

const SHOW_KNOWN_MIMES = Dict{String,String}(
    ".png" => "image/png",   ".jpg" => "image/jpeg",  ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",   ".webp" => "image/webp", ".svg" => "image/svg+xml",
    ".bmp" => "image/bmp",
    ".mp4" => "video/mp4",   ".webm" => "video/webm", ".mov" => "video/quicktime",
    ".html" => "text/html",  ".htm" => "text/html",
    ".json" => "application/json",
    ".md" => "text/markdown", ".txt" => "text/plain",  ".log" => "text/plain",
    ".jl" => "text/x-julia",  ".py" => "text/x-python", ".js" => "text/javascript",
    ".csv" => "text/csv",
)

function show_mime_from_path(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    return get(SHOW_KNOWN_MIMES, ext, "application/octet-stream")
end

function bt_show_format_bytes(n::Integer)
    n < 1024     && return "$(n)B"
    n < 1024^2   && return string(round(n / 1024;     digits = 1), "KB")
    n < 1024^3   && return string(round(n / 1024^2;   digits = 1), "MB")
                    return string(round(n / 1024^3;   digits = 2), "GB")
end

function julia_show_handler(args::AbstractDict)
    path = String(get(args, "path", ""))
    isempty(path) && return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => "error: missing `path`")],
        "isError" => true,
    )
    isfile(path) || return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => "error: not a file: $path")],
        "isError" => true,
    )
    mime = show_mime_from_path(path)
    sz   = filesize(path)
    text = "shown: $path ($mime, $(bt_show_format_bytes(sz)))"
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
    )
end

const SHOW_DESCRIPTION = """
Display a file from the worker's disk in the chat as a collapsible preview.

Trivial: just hand it a path. The chat-side renderer fetches the file
lazily and inlines a preview based on the file's extension:

  • image/png · jpeg · gif · webp · svg · bmp → inline `<img>`
  • video/mp4 · webm · mov                    → `<video controls>`
  • text/html                                 → sandboxed `<iframe>`
  • text/* and code files                     → Monaco editor
  • anything else                             → caption only

The file's bytes never enter your conversation context. You only emit a
reference; the chat does the rest.

Common flow:
  1. Run `bt_julia_eval` for any value with rich output (Makie / Plots
     figure, Colorant matrix, DataFrame with HTML show). The eval
     auto-writes the rendered output to <env>/.bonitoAgents/show/<id>.<ext>
     and returns the `shown: …` path alongside the text repr.
  2. Pass that path to `bt_show` (or any other path on the worker) when
     you want the user to see the file inline.

Use this for: showing a Makie figure you just rendered; surfacing a log
or HTML report you just generated; displaying any image / video on the
worker's disk.
"""

register!(
    "bt_show", SHOW_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path" => Dict("type"=>"string",
                            "description"=>"Path on the worker to a file to display in the chat. Absolute or relative to the worker's cwd."),
        ),
        "required" => ["path"],
    ),
    julia_show_handler,
)
