messaging_owner(state, p) = isempty(p.owner) ? default_owner(state.auth) : p.owner

function peer_messaging_allowed(state, source_id, target_id)
    source = get(state.projects[], source_id, nothing)
    target = get(state.projects[], target_id, nothing)
    return source !== nothing && target !== nothing && source.id != target.id &&
        source.chat_messaging && target.chat_messaging && !source.dismissed && !target.dismissed &&
        messaging_owner(state, source) == messaging_owner(state, target)
end

"""
    set_chat_messaging!(state, project_id, on)

Enable or disable peer messaging for one chat. Both chats must opt in. Changes
take effect without restarting the agent; disabling pauses unsubmitted peer input.
"""
function set_chat_messaging!(state::ServerState, project_id::AbstractString, on::Bool)
    p = dev_project(state, project_id)
    visible(state, p) || error("chat is not available")
    p.chat_messaging == on && return p
    p.chat_messaging = on
    lock(state.lock) do; save_projects!(state); end
    notify_projects!(state)
    if !on
        root = root_state(state)
        models = lock(() -> copy(root.chat_models), root.lock)
        for model in values(models)
            pause_disallowed_peer_sends!(shared(model); revoked_project = p.id)
        end
        # Closed chats also have durable queues. Revocation must survive an
        # off/on cycle before such a chat is reopened.
        for target in values(root.projects[])
            haskey(models, target.id) && continue
            path = joinpath(root.state_dir, "chats", target.id, "pending-messages.json")
            rows = load_json_tolerant(path, "pending messages")
            rows isa AbstractVector || continue
            changed = false
            for row in rows
                origin = get(row, "origin", nothing)
                origin isa AbstractDict || continue
                get(row, "status", "waiting") in ("waiting", "offline", "sending") || continue
                # Preserve this revocation even if another tab re-enables it
                # while these durable queues are being saved.
                (target.id == p.id || get(origin, "project_id", "") == p.id) || continue
                row["status"] = "paused"
                row["detail"] = PEER_DISABLED_DETAIL
                changed = true
            end
            changed && atomic_write_json(path, rows)
        end
    end
    @info "chat messaging switched" project_id=p.id on
    return p
end

function messaging_source(state, caller)
    isempty(caller) && error("Chat messaging needs an authenticated chat")
    p = get(state.projects[], caller, nothing)
    p === nothing && error("Chat messaging source is no longer available")
    p.chat_messaging || error("Chat messaging is off for this chat. Enable 'Chat messaging' in its ⋯ menu. Both chats must opt in; dev mode does not grant messaging.")
    p.dismissed && error("The sending chat is closed")
    return p
end

function send_peer_message!(state, caller, args)
    source = messaging_source(state, caller)
    target = get(state.projects[], String(get(args, "project_id", "")), nothing)
    (target === nothing || messaging_owner(state, source) != messaging_owner(state, target)) &&
        error("Target chat is not available for messaging")
    target.id == source.id && error("Choose another chat")
    target.chat_messaging || error("Chat messaging is off for the receiving chat. Enable it in that chat's ⋯ menu first.")
    target.dismissed && error("The receiving chat is closed")
    text = String(get(args, "text", ""))
    isempty(strip(text)) && error("`text` is empty; nothing to send")
    worker = get(state.workers[], source.worker_id, nothing)
    origin = PeerMessageOrigin(string(uuid4()), source.id, source.title[], source.worker_id,
        worker === nothing ? source.worker_id : worker.name, now(UTC))
    model = ensure_project_session!(state, target)
    model === nothing && error("Could not bring up the receiving chat")
    # Bring-up can yield while the user changes either switch.
    peer_messaging_allowed(state, source.id, target.id) || error("Chat messaging permission changed; message was not queued")
    send_message!(model, UserMsg(text); mode = :next, origin)
    return Dict{String,Any}("ok" => true, "status" => "queued", "project_id" => target.id,
        "message_id" => origin.id, "sent_at" => message_timestamp(origin.sent_at),
        "detail" => "Accepted into the recipient's queue. This does not confirm agent receipt or a reply.")
end

function dev_op(state::ServerState, ::Val{:chat_messaging}, args::AbstractDict, caller::String)
    action = String(get(args, "action", "list"))
    action == "send" && return send_peer_message!(state, caller, args)
    action == "list" || error("Unknown chat messaging action: $action")
    source = get(state.projects[], caller, nothing)
    source === nothing && error("Chat messaging needs an authenticated chat")
    enabled = source.chat_messaging && !source.dismissed
    chats = enabled ? [Dict{String,Any}("project_id" => p.id, "title" => p.title[],
        "worker" => (w = get(state.workers[], p.worker_id, nothing); w === nothing ? p.worker_id : w.name))
        for p in values(state.projects[]) if peer_messaging_allowed(state, source.id, p.id)] : Any[]
    sort!(chats; by = p -> (p["title"], p["project_id"]))
    return Dict{String,Any}("enabled" => enabled, "chats" => chats,
        "detail" => "Both chats must enable Chat messaging in their ⋯ menus. Dev mode is independent.")
end
