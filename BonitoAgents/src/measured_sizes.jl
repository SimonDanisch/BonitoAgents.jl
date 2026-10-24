# ── Sizes the browser measured, sent back with later renders ─────────────────
# Two things in a transcript grow after they are in the page. A tool body
# arrives after its row (a `bt_show` file, an eval card's result: a
# `tool.render` round trip), and a picture or a clip has no size until its
# bytes do. Each time, everything below moves. The browser measures both
# anyway, so it reports what it measured once, and every later render carries
# it: the loading placeholder takes the body's height, and the media element
# the file's natural size (`width`/`height`), before anything arrives.
#
# Measured by the browser, not read from the files: a media element is a link
# to the worker's file (`show_media_src`), and the server never holds its bytes.
# The exception is a picture the agent read, whose bytes are in the tool's
# content (`image_size` below).
#
#   {type: "media.size", path, w, h}        a worker file's natural size (images, videos)
#   {type: "tool.size",  id, w, h, extra}   a tool body's height `h`, the transcript `w` px
#                                           wide, `extra` of it not its picture

# Wire `{type: "media.size", path, w, h}`: the natural size of the picture or
# clip at `path` on the chat's worker.
struct MediaSizeCommand <: ChatCommand
    path::String
    w::Int
    h::Int
end

# Wire `{type: "tool.size", id, w, h, extra}`: the body of tool `id` rendered
# `h` px tall (its CONTENT box, what a placeholder in it must fill) in a
# transcript `w` px wide. The transcript's width, not the body's: a body can
# shrink to fit its content, so its own width before the content arrives says
# nothing. `extra` (0 when absent) is the part of `h` that is not the body's
# picture, a Share row above it: at a width the body was never shown at, the
# placeholder is the picture's shape plus that.
struct BodyHeightCommand <: ChatCommand
    tool_id::String
    w::Int
    h::Int
    extra::Int
end

# A pixel count from the wire, or `nothing`: a size no element has.
function wire_pixels(v, limit::Int; least::Int = 1)
    v isa Real && isfinite(v) || return nothing
    n = round(Int, v)
    return least <= n <= limit ? n : nothing
end

function parse_size_command(msg::AbstractDict, type::AbstractString)
    w = wire_pixels(get(msg, "w", nothing), 100_000)
    h = wire_pixels(get(msg, "h", nothing), 100_000)
    (w === nothing || h === nothing) && return UnknownCommand()
    if type == "media.size"
        path = get(msg, "path", "")
        path isa AbstractString && !isempty(path) || return UnknownCommand()
        return MediaSizeCommand(String(path), w, h)
    end
    id = get(msg, "id", "")
    id isa AbstractString && !isempty(id) || return UnknownCommand()
    extra = wire_pixels(get(msg, "extra", 0), h; least = 0)
    extra === nothing && return UnknownCommand()
    return BodyHeightCommand(String(id), w, h, extra)
end

# ── media sizes: per server, by worker file ─────────────────────────────────

media_sizes_file(s::ServerState) = joinpath(s.state_dir, "media_sizes.json")

function save_media_sizes!(state::ServerState)
    rec = state.media_sizes
    lock(rec.lock) do
        data = Dict{String,Any}()
        for ((worker_id, path), (w, h)) in rec.sizes
            get!(() -> Dict{String,Any}(), data, worker_id)[path] = [w, h]
        end
        atomic_write_json(media_sizes_file(state), data)
    end
    return nothing
end

function load_media_sizes!(state::ServerState)
    raw = load_json_tolerant(media_sizes_file(state), "media_sizes.json")
    raw isa AbstractDict || return nothing
    rec = state.media_sizes
    lock(rec.lock) do
        for (worker_id, files) in raw
            files isa AbstractDict || continue
            for (path, wh) in files
                wh isa AbstractVector && length(wh) == 2 && all(x -> x isa Integer, wh) || continue
                rec.sizes[(String(worker_id), String(path))] = (Int(wh[1]), Int(wh[2]))
            end
        end
    end
    return nothing
end

"""
    media_size(state, worker_id, path) -> Union{NTuple{2,Int},Nothing}

The natural `(width, height)` the browser last measured for the picture or clip
at `path` on worker `worker_id`, or `nothing` before it ever showed it.
"""
media_size(state::ServerState, worker_id::AbstractString, path::AbstractString) =
    lock(() -> get(state.media_sizes.sizes, (String(worker_id), String(path)), nothing),
         state.media_sizes.lock)

# The size a bt_show (or a file tab) shows its file at, when one was measured.
function media_size(st::ShowTool)
    proj = get(st.state.projects[], st.project_id, nothing)
    proj === nothing && return nothing
    return media_size(st.state, proj.worker_id, show_worker_path(st))
end

function record_media_size!(state::ServerState, worker_id::AbstractString,
                            path::AbstractString, w::Int, h::Int)
    rec = state.media_sizes
    key = (String(worker_id), String(path))
    changed = lock(rec.lock) do
        get(rec.sizes, key, nothing) == (w, h) && return false
        rec.sizes[key] = (w, h)
        return true
    end
    changed && save_media_sizes!(state)
    return changed
end

function handle_command!(model::ChatModel, ::Session, cmd::MediaSizeCommand)
    proj = get(model.state.projects[], model.project_id, nothing)
    proj === nothing && return nothing
    record_media_size!(model.state, proj.worker_id, cmd.path, cmd.w, cmd.h)
    return nothing
end

# ── sizes read from bytes the server holds ──────────────────────────────────
# A picture the agent read (`Read` on a PNG) comes with its bytes, as base64 in
# the tool's content: its size is in its header, so even a chat opened for the
# first time can lay it out at its final size. Only the header is read.

"""
    image_size(bytes) -> Union{NTuple{2,Int},Nothing}

The `(width, height)` a PNG, JPEG, GIF or WebP declares in its header, or
`nothing` for another format or a header cut short. A JPEG's EXIF orientation
is not applied: a turned photo is reported as stored.
"""
image_size(b::AbstractVector{UInt8}) = image_size(image_format(b), b)
image_size(::Nothing, ::AbstractVector{UInt8}) = nothing

function image_format(b::AbstractVector{UInt8})
    length(b) >= 12 || return nothing
    view(b, 1:8) == b"\x89PNG\r\n\x1a\n" && return Val(:png)
    b[1] == 0xff && b[2] == 0xd8 && return Val(:jpeg)
    view(b, 1:4) == b"GIF8" && return Val(:gif)
    view(b, 1:4) == b"RIFF" && view(b, 9:12) == b"WEBP" && return Val(:webp)
    return nothing
end

be16(b, i) = Int(b[i]) << 8 | Int(b[i+1])
le16(b, i) = Int(b[i]) | Int(b[i+1]) << 8
be32(b, i) = be16(b, i) << 16 | be16(b, i + 2)
le24(b, i) = Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16

# The IHDR chunk comes first: width and height, big-endian, right after it.
image_size(::Val{:png}, b) =
    length(b) >= 24 && view(b, 13:16) == b"IHDR" ? (be32(b, 17), be32(b, 21)) : nothing

image_size(::Val{:gif}, b) = (le16(b, 7), le16(b, 9))

# Segments until the frame header (SOF0..SOF15, but not DHT, JPG or DAC, which
# share the range): height, then width, after the length and the precision.
function image_size(::Val{:jpeg}, b)
    i = 3
    while i + 8 <= length(b)
        b[i] == 0xff || return nothing
        marker = b[i+1]
        marker == 0xff && (i += 1; continue)                              # fill byte
        (0xd0 <= marker <= 0xd9 || marker == 0x01) && (i += 2; continue)  # no length
        0xc0 <= marker <= 0xcf && !(marker in (0xc4, 0xc8, 0xcc)) &&
            return (be16(b, i + 7), be16(b, i + 5))
        i += 2 + be16(b, i + 2)
    end
    return nothing
end

# The first chunk says which: lossy (VP8), lossless (VP8L) or extended (VP8X).
function image_size(::Val{:webp}, b)
    length(b) >= 16 || return nothing
    chunk = view(b, 13:16)
    if chunk == b"VP8 "
        length(b) >= 30 || return nothing
        return (le16(b, 27) & 0x3fff, le16(b, 29) & 0x3fff)
    elseif chunk == b"VP8L"
        length(b) >= 25 || return nothing
        bits = le16(b, 22) | le16(b, 24) << 16
        return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
    elseif chunk == b"VP8X"
        length(b) >= 30 || return nothing
        return (le24(b, 25) + 1, le24(b, 28) + 1)
    end
    return nothing
end

# From the start of the base64 an image content holds: `head` bytes are enough
# for any of the headers above (a JPEG's frame header follows its EXIF block,
# which can be tens of kilobytes).
function image_size(c::ImageContent; head::Int = 1 << 16)
    n = min(length(c.data), 4 * cld(head, 3))
    n -= n % 4
    bytes = try
        base64decode(n == length(c.data) ? c.data : c.data[1:n])
    catch e
        e isa ArgumentError || rethrow()
        return nothing                       # not base64: no size to read
    end
    return image_size(bytes)
end

"The size of the picture a tool's content holds the bytes of, or `nothing`."
function tool_media_size(content)
    for c in content
        c isa ImageContent && return image_size(c)
    end
    return nothing
end

# ── body heights: per chat, by tool ─────────────────────────────────────────

body_heights_file(chat_dir::AbstractString) = joinpath(chat_dir, "body_heights.json")

function load_body_heights(chat_dir::AbstractString)
    rec = BodyHeights()
    raw = load_json_tolerant(body_heights_file(chat_dir), "body_heights.json")
    raw isa AbstractDict || return rec
    for (id, list) in raw
        list isa AbstractVector || continue
        # `[w, h]` from before `extra` was measured: none known.
        rec.heights[String(id)] = NTuple{3,Int}[(Int(e[1]), Int(e[2]), length(e) == 3 ? Int(e[3]) : 0)
            for e in list if e isa AbstractVector && length(e) in (2, 3) && all(x -> x isa Integer, e)]
    end
    return rec
end

function save_body_heights(model::ChatModel)
    rec = shared(model).body_heights
    lock(rec.lock) do
        atomic_write_json(body_heights_file(model.chat_dir),
            Dict{String,Any}(id => [collect(e) for e in list] for (id, list) in rec.heights))
    end
    return nothing
end

# A body is measured at one width at a time; a phone and a desktop take turns.
# The `kept` last widths each keep their height, a width within 2 px counting
# as the same.
function record_body_height!(model::ChatModel, tool_id::AbstractString, w::Int, h::Int,
                             extra::Int = 0; kept::Int = 4)
    rec = shared(model).body_heights
    changed = lock(rec.lock) do
        list = get!(() -> NTuple{3,Int}[], rec.heights, String(tool_id))
        i = findfirst(e -> abs(e[1] - w) <= 2, list)
        i !== nothing && list[i] == (w, h, extra) && return false
        i === nothing || deleteat!(list, i)
        push!(list, (w, h, extra))
        length(list) > kept && popfirst!(list)
        return true
    end
    changed && save_body_heights(model)
    return changed
end

"""
    body_heights(model, tool_id) -> Union{Dict{String,Int},Nothing}

The heights tool `tool_id`'s body rendered at, by width (`"640" => 312`), for
the wire's `body_h`; `nothing` before it was ever measured.
"""
function body_heights(model::ChatModel, tool_id::AbstractString)
    rec = shared(model).body_heights
    return lock(rec.lock) do
        list = get(rec.heights, String(tool_id), nothing)
        (list === nothing || isempty(list)) && return nothing
        Dict{String,Int}(string(w) => h for (w, h, _) in list)
    end
end

# The part of tool `tool_id`'s body that is not its picture, as last measured;
# 0 before it was.
function media_extra(model::ChatModel, tool_id::AbstractString)
    rec = shared(model).body_heights
    return lock(rec.lock) do
        list = get(rec.heights, String(tool_id), nothing)
        (list === nothing || isempty(list)) ? 0 : last(list)[3]
    end
end

function handle_command!(model::ChatModel, ::Session, cmd::BodyHeightCommand)
    record_body_height!(model, cmd.tool_id, cmd.w, cmd.h, cmd.extra)
    return nothing
end

# A transcript row as the browser gets it from history: the message's wire
# form plus, for a tool, what its body's placeholder needs to hold its size.
row_dict(model::ChatModel, m::ChatMsg) = msg_to_dict(m, model.chat_dir)

# The heights the body rendered at, and the picture's size (`media`) with what
# the body holds besides it (`media_extra`). A picture shown from a file carries
# no bytes to read it from (bt_show, codex's view): the size the browser
# measured for that file, if it ever showed it.
function row_dict(model::ChatModel, m::ToolMsg)
    d = msg_to_dict(m, model.chat_dir)
    id = tool_id(m)
    hs = body_heights(model, id)
    hs === nothing || (d["body_h"] = hs)
    if haskey(d, "show_mime") && !haskey(d, "media")
        st = shown_file(model.state, model.project_id, model.cwd,
                        tool_content_for_render(m, model.chat_dir))
        size = st === nothing ? nothing : media_size(st)
        size === nothing || (d["media"] = [size...])
    end
    if haskey(d, "media")
        extra = media_extra(model, id)
        extra > 0 && (d["media_extra"] = extra)
    end
    return d
end
