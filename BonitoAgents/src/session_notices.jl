session_notice_path(model) = joinpath(model.chat_dir, "session-notice.json")

function save_session_notice!(model, info)
    atomic_write_json(session_notice_path(model), info)
    model.session_notice[] = info
    return nothing
end

function load_session_notice!(model)
    info = load_json_tolerant(session_notice_path(model), "session notice")
    info === nothing && return nothing
    model.session_notice[] = Dict{String,Any}(info)
    return nothing
end

# A retry may allocate a new ID for identical information. Dismiss that same
# active problem once; a different problem or a failure after recovery is new.
function same_session_notice(a, b)
    return all(k -> get(a, k, nothing) == get(b, k, nothing),
               ("severity", "category", "title", "details"))
end

function process!(chat::ChatModel, m::AgentClientProtocol.SessionNotice)
    s = shared(chat)
    lock(s.lock) do
        previous = s.session_notice[]
        retired = get(previous, "retired_ids", String[])
        m.record["id"] in retired && return nothing
        same_id = get(previous, "id", nothing) == m.record["id"]
        if same_id
            # Keep the incident as a tombstone, so delayed frames or a session
            # replay cannot revive a recovered problem.
            escalated = previous["severity"] == "warning" && m.record["severity"] == "error"
            get(previous, "resolved", false) && !escalated && return nothing
            get(previous, "revision", -1) >= m.record["revision"] && return nothing
        end
        dismissed = get(previous, "dismissed", false) &&
            !get(previous, "resolved", false) &&
            ((same_id && previous["severity"] == m.record["severity"]) ||
             same_session_notice(previous, m.record))
        if !same_id && haskey(previous, "id")
            # A replay can include older incidents before the latest one. Keep
            # their IDs too, bounded so unattended retries cannot grow the file.
            retired = last([retired; previous["id"]], 128)
        end
        info = merge(m.record, Dict{String,Any}("dismissed" => dismissed,
            "resolved" => false, "retired_ids" => retired))
        save_session_notice!(s, info)
    end
    return nothing
end

function resolve_session_notice!(model; warnings_only = false)
    s = shared(model)
    lock(s.lock) do
        info = s.session_notice[]
        (isempty(info) || get(info, "resolved", false)) && return nothing
        warnings_only && info["severity"] != "warning" && return nothing
        save_session_notice!(s, merge(info, Dict("resolved" => true)))
    end
    return nothing
end

struct DismissNoticeCommand <: ChatCommand
    id::String
end

function handle_command!(model::ChatModel, ::Any, command::DismissNoticeCommand)
    s = shared(model)
    lock(s.lock) do
        info = s.session_notice[]
        # A click from an older tab must not dismiss a different, newer failure.
        get(info, "id", nothing) == command.id || return nothing
        get(info, "dismissed", false) && return nothing
        save_session_notice!(s, merge(info, Dict("dismissed" => true)))
    end
    return nothing
end
