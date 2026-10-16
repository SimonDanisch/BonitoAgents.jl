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
#
#   {type: "media.size", path, w, h}   a worker file's natural size (images, videos)
#   {type: "tool.size",  id,   w, h}   a tool body's height `h`, the transcript `w` px wide

# Wire `{type: "media.size", path, w, h}`: the natural size of the picture or
# clip at `path` on the chat's worker.
struct MediaSizeCommand <: ChatCommand
    path::String
    w::Int
    h::Int
end

# Wire `{type: "tool.size", id, w, h}`: the body of tool `id` rendered `h` px
# tall (its CONTENT box, what a placeholder in it must fill) in a transcript
# `w` px wide. The transcript's width, not the body's: a body can shrink to fit
# its content, so its own width before the content arrives says nothing.
struct BodyHeightCommand <: ChatCommand
    tool_id::String
    w::Int
    h::Int
end

# A pixel count from the wire, or `nothing`: a size no element has.
function wire_pixels(v, limit::Int)
    v isa Real && isfinite(v) || return nothing
    n = round(Int, v)
    return 1 <= n <= limit ? n : nothing
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
    return BodyHeightCommand(String(id), w, h)
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

# ── body heights: per chat, by tool ─────────────────────────────────────────

body_heights_file(chat_dir::AbstractString) = joinpath(chat_dir, "body_heights.json")

function load_body_heights(chat_dir::AbstractString)
    rec = BodyHeights()
    raw = load_json_tolerant(body_heights_file(chat_dir), "body_heights.json")
    raw isa AbstractDict || return rec
    for (id, list) in raw
        list isa AbstractVector || continue
        rec.heights[String(id)] = NTuple{2,Int}[(Int(wh[1]), Int(wh[2])) for wh in list
            if wh isa AbstractVector && length(wh) == 2 && all(x -> x isa Integer, wh)]
    end
    return rec
end

function save_body_heights(model::ChatModel)
    rec = shared(model).body_heights
    lock(rec.lock) do
        atomic_write_json(body_heights_file(model.chat_dir),
            Dict{String,Any}(id => [[w, h] for (w, h) in list] for (id, list) in rec.heights))
    end
    return nothing
end

# A body is measured at one width at a time; a phone and a desktop take turns.
# The `kept` last widths each keep their height, a width within 2 px counting
# as the same.
function record_body_height!(model::ChatModel, tool_id::AbstractString, w::Int, h::Int;
                             kept::Int = 4)
    rec = shared(model).body_heights
    changed = lock(rec.lock) do
        list = get!(() -> NTuple{2,Int}[], rec.heights, String(tool_id))
        i = findfirst(((w0, _),) -> abs(w0 - w) <= 2, list)
        i !== nothing && list[i] == (w, h) && return false
        i === nothing || deleteat!(list, i)
        push!(list, (w, h))
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
        Dict{String,Int}(string(w) => h for (w, h) in list)
    end
end

function handle_command!(model::ChatModel, ::Session, cmd::BodyHeightCommand)
    record_body_height!(model, cmd.tool_id, cmd.w, cmd.h)
    return nothing
end

# A transcript row as the browser gets it from history: the message's wire
# form plus, for a tool, the heights its body rendered at.
function row_dict(model::ChatModel, m::ChatMsg)
    d = msg_to_dict(m, model.chat_dir)
    if m isa ToolMsg
        hs = body_heights(model, tool_id(m))
        hs === nothing || (d["body_h"] = hs)
    end
    return d
end
