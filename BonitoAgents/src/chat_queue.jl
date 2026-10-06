# Pending text is an outbox, not conversation history. A submission enters
# chat.md only once prompt! has handed it to the agent connection.
mutable struct PendingSend
    id::String
    message::UserMessage
    bubble::UserMsg
    mode::Symbol
    status::Symbol
    detail::String
    span::Any
end

send_mode(s) = s == "interrupt" ? :interrupt : s == "next" ? :next : :done

struct SendModeCommand <: ChatCommand
    command::SendCommand
    mode::Symbol
end
struct QueueActionCommand <: ChatCommand
    id::String
    action::String
end
handle_command!(m::ChatModel, ::Any, c::SendModeCommand) = handle_send!(m, c.command, c.mode)

pending_path(m) = joinpath(m.chat_dir, "pending-messages.json")

function save_pending_sends!(model)
    s = shared(model)
    lock(s.lock) do
        rows = [Dict("id" => e.id, "text" => e.message.text, "auto" => e.bubble.auto,
            "mode" => String(e.mode), "status" => String(e.status),
            "images" => [Dict("mime" => i.mime, "data" => Base64.base64encode(i.data))
                         for i in e.message.images])
            for e in s.pending_sends if e isa PendingSend && e.status != :sent]
        mkpath(s.chat_dir)
        path = pending_path(s)
        open(io -> JSON.print(io, rows), path * ".tmp", "w")
        mv(path * ".tmp", path; force=true)
    end
    return nothing
end

function load_pending_sends!(model)
    path = pending_path(model)
    isfile(path) || return nothing
    for row in JSON.parsefile(path)
        bubble = UserMsg(model, String(row["text"]))
        bubble.auto = get(row, "auto", false)
        images = [AgentClientProtocol.ImageAttachment(Base64.base64decode(i["data"]), String(i["mime"]))
                  for i in get(row, "images", Any[])]
        push!(model.pending_sends, PendingSend(String(row["id"]),
            UserMessage(bubble.text, collect(AgentClientProtocol.ImageAttachment, images)), bubble,
            send_mode(get(row, "mode", "done")), :paused,
            "Paused after restart; delivery was not confirmed. Review before resending.", nothing))
    end
    return nothing
end

function queue_event(model)
    lock(shared(model).lock) do
        items = [Dict("id" => e.id, "text" => e.message.text, "mode" => String(e.mode),
            "status" => String(e.status), "detail" => e.detail)
            for e in shared(model).pending_sends if e isa PendingSend && e.status != :sent]
        return Dict{String,Any}("type" => "queue.state", "items" => items)
    end
end
emit_queue!(model) = chat_emit(model, queue_event(model))

function enqueue_message!(model, msg; images, mode)
    s = shared(model)
    msg.auto || reset!(s.yolo_state)
    mode == :interrupt && handle_command!(s, nothing, CancelCommand())
    bubble = UserMsg(s, msg.text)
    bubble.auto = msg.auto
    entry = PendingSend(string(uuid4()), UserMessage(msg.text,
        collect(AgentClientProtocol.ImageAttachment, images)), bubble, mode, :waiting, "", nothing)
    lock(s.lock) do
        push!(s.pending_sends, entry)
        save_pending_sends!(s)
    end
    @info "message queued" project_id=s.project_id message_id=entry.id mode
    emit_queue!(s)
    # The channel is a wakeup, not the queue itself. Nonblocking coalescing:
    # one outstanding wakeup is enough, regardless of the outbox's size.
    isready(s.user_messages) || put!(s.user_messages, entry.message)
    return nothing
end

function next_submission(model)
    s = shared(model)
    lock(s.lock) do
        # Already-steered spans must settle before a new ordinary turn starts.
        for status in (:sent, :waiting)
            i = findfirst(e -> e isa PendingSend && e.status == status, s.pending_sends)
            i === nothing && continue
            e = s.pending_sends[i]
            e.status == :waiting && (e.status = :sending)
            return e
        end
        return nothing
    end
end

function submission_sent!(model, e, span)
    e.status = :sent
    close(send!(model, e.bubble))
    # A steering span may finish before the consumer starts awaiting it. Its
    # reply baseline must be the handoff, not that later completion callback.
    e.span = (turn=span, nstore0=length(model.msgs_store))
    save_pending_sends!(model)
    emit_queue!(model)
    emit_lens_vocab(model)
    chat_emit(model, Dict{String,Any}("type" => "queue.delivered", "id" => e.id,
        "text" => e.message.text, "idx" => length(model.msgs_store) - 1))
    @info "message sent to agent" project_id=model.project_id message_id=e.id mode=e.mode
    return span
end

function run_submission!(model, entry)
    emit_queue!(model)
    try
        if entry.span !== nothing
            while_busy(model) do
                finish_turn!(model, entry.span.turn; nstore0=entry.span.nstore0)
            end
        else
            if entry.mode == :done && AgentClientProtocol.is_working(session_activity(model))
                entry.detail = "Waiting until the agent finishes"
                emit_queue!(model)
                while entry.status == :sending && AgentClientProtocol.is_working(session_activity(model))
                    sleep(0.05)
                end
                entry.status == :sending || return nothing
                entry.detail = ""
            end
            begin_turn(model, entry.message; submission=entry) do turn
                finish_turn!(model, turn; nstore0=entry.span.nstore0)
            end
        end
    catch e
        entry.status == :sending && (entry.detail =
            "Delivery was not confirmed. Review the conversation before retrying.")
        @error "queued message delivery failed" project_id=model.project_id message_id=entry.id exception=(e, catch_backtrace())
        report_turn_error!(model, e)
    finally
        lock(model.lock) do
            if entry.status == :sent
                filter!(e -> e !== entry, model.pending_sends)
            elseif entry.status == :sending
                entry.status = :paused
                isempty(entry.detail) && (entry.detail =
                    "Not sent: the agent could not accept this message. Retry when connected.")
            end
            save_pending_sends!(model)
        end
        emit_queue!(model)
    end
    return nothing
end

function drop_queued_sends!(model::ChatModel)
    s = shared(model)
    count = lock(s.lock) do
        n = 0
        for e in s.pending_sends
            e isa PendingSend && e.status in (:waiting, :sending) || continue
            e.status = :paused
            e.detail = "Not sent: paused by Stop. Send it again or remove it."
            n += 1
        end
        save_pending_sends!(s)
        n
    end
    @info "message queue paused" project_id=s.project_id count
    emit_queue!(s)
    return count
end

function deliver_boundary_message!(model)
    s = shared(model)
    c = client(s.agent)
    c === nothing && return nothing
    AgentClientProtocol.session_live(c) || return nothing
    AgentClientProtocol.session_activity(c.conn) isa AgentClientProtocol.Cancelling && return nothing
    lock(s.lock) do
        i = findfirst(e -> e isa PendingSend && e.status == :waiting && e.mode == :next, s.pending_sends)
        i === nothing && return nothing
        e = s.pending_sends[i]
        if !get(c.session_result, "bonitoPromptQueueing", false)
            e.mode = :done
            e.detail = "This agent does not advertise steering; waiting until the turn finishes."
            save_pending_sends!(s)
            emit_queue!(s)
            return nothing
        end
        e.status = :sending
        try
            span = AgentClientProtocol.prompt!(c, with_prelude(s, e.message.text); images=e.message.images)
            submission_sent!(s, e, span)
        catch err
            e.status = :paused
            e.detail = "Steering failed; delivery was not confirmed. Review before retrying."
            save_pending_sends!(s)
            emit_queue!(s)
            @error "message steering failed" project_id=s.project_id message_id=e.id exception=(err, catch_backtrace())
        end
    end
    return nothing
end

function handle_command!(model::ChatModel, ::Any, cmd::QueueActionCommand)
    s = shared(model)
    entry = lock(s.lock) do
        i = findfirst(e -> e isa PendingSend && e.id == cmd.id && e.status in (:waiting, :paused), s.pending_sends)
        i === nothing && return nothing
        e = s.pending_sends[i]
        if cmd.action == "remove"
            deleteat!(s.pending_sends, i)
        elseif cmd.action == "send"
            e.status = :waiting
            e.mode = :done
            e.detail = ""
        else
            return nothing
        end
        save_pending_sends!(s)
        e
    end
    entry === nothing || @info "message queue action" project_id=s.project_id message_id=entry.id action=cmd.action
    emit_queue!(s)
    if entry !== nothing && cmd.action == "send"
        isready(s.user_messages) || put!(s.user_messages, entry.message)
    end
    return nothing
end
