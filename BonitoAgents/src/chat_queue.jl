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
            "mode" => String(e.mode), "status" => String(e.status), "detail" => e.detail,
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
        # Only a message the user paused stays paused. Anything else was never
        # handed to the agent (a handed-over entry is :sent and not persisted),
        # so it goes out once this chat's consumer runs.
        paused = get(row, "status", "waiting") == "paused"
        push!(model.pending_sends, PendingSend(String(row["id"]),
            UserMessage(bubble.text, collect(AgentClientProtocol.ImageAttachment, images)), bubble,
            send_mode(get(row, "mode", "done")), paused ? :paused : :waiting,
            paused ? String(get(row, "detail", "")) : "", nothing))
    end
    wake_outbox!(model)
    return nothing
end

# Have the consumer look at the outbox again. One pending wakeup is enough; a
# closed channel means the chat is closed, and its outbox waits on disk for the
# next ChatModel of this project.
function wake_outbox!(model)
    s = shared(model)
    (isopen(s.user_messages) && !isready(s.user_messages)) || return nothing
    try
        put!(s.user_messages, UserMessage("", AgentClientProtocol.ImageAttachment[]))
    catch e
        e isa InvalidStateException || rethrow()   # closed between the check and the put
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
    wake_outbox!(s)
    return nothing
end

function next_submission(model)
    s = shared(model)
    lock(s.lock) do
        # Already-steered spans must settle before a new ordinary turn starts.
        for ready in (==(:sent), in((:waiting, :offline)))
            i = findfirst(e -> e isa PendingSend && ready(e.status), s.pending_sends)
            i === nothing && continue
            e = s.pending_sends[i]
            e.status == :sent || (e.status = :sending)
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

# The bring-up `live_client!` is about to do, shown on the message waiting on it.
starting_session!(model, ::Nothing) = nothing
function starting_session!(model, entry::PendingSend)
    entry.detail = "Starting the agent session"
    emit_queue!(model)
    return nothing
end

# Hand one outbox entry to the agent and see its turn through. Returns whether
# the consumer should go on with the next entry.
#
# A message that was not handed over stays in the outbox:
#   * the agent could not be brought up → `:offline`, sent on the next wakeup
#     (a new message, a session coming up, its worker reconnecting). The
#     consumer stops here instead of retrying in a loop;
#   * the chat was closed → `:waiting` on disk, sent when the chat reopens;
#   * anything else failed → `:paused` with the error, for the user to judge.
# What a message sent "when done" waits for: a turn of ours in flight, or a
# cancel winding one down. Not work the agent does on its own (`Unprompted`, an
# auto-wake after backgrounded work, a background subagent reporting): that has
# no end the agent announces, only 30s of quiet, and a background subagent can
# keep it going for as long as it runs. The next prompt is what ends such an
# episode, so waiting for it held the message back for good.
waits_for_turn(::AgentClientProtocol.SessionActivity) = false
waits_for_turn(::AgentClientProtocol.Prompted) = true
waits_for_turn(::AgentClientProtocol.Cancelling) = true

function run_submission!(model, entry)
    emit_queue!(model)
    failure = nothing
    go_on = true
    try
        if entry.span !== nothing
            while_busy(model) do
                finish_turn!(model, entry.span.turn; nstore0=entry.span.nstore0)
            end
        else
            if entry.mode == :done && waits_for_turn(session_activity(model))
                entry.detail = "Waiting until the agent finishes"
                emit_queue!(model)
                while entry.status == :sending && waits_for_turn(session_activity(model))
                    sleep(0.05)
                end
                entry.status == :sending || return true
                entry.detail = ""
            end
            begin_turn(model, entry.message; submission=entry) do turn
                finish_turn!(model, turn; nstore0=entry.span.nstore0)
            end
        end
    catch e
        cause = innermost_cause(e)
        @error "queued message delivery failed" project_id=model.project_id message_id=entry.id exception=(e, catch_backtrace())
        if entry.status == :sending && !is_session_dead_error(cause)
            failure = sprint(showerror, cause)
        else
            # Lost the session (before or after the handoff), or the turn
            # failed after the agent got the message: the chat shows it.
            report_turn_error!(model, e)
        end
    finally
        go_on = settle_submission!(model, entry, failure)
    end
    return go_on
end

function settle_submission!(model, entry, failure)
    go_on = true
    lock(model.lock) do
        if entry.status == :sent
            filter!(e -> e !== entry, model.pending_sends)
        elseif entry.status == :sending
            if failure !== nothing
                entry.status = :paused
                entry.detail = "Not sent: $(failure)"
            elseif !isopen(model.user_messages)
                entry.status = :waiting
                entry.detail = ""
                go_on = false
            else
                err = model.last_error[]
                entry.status = :offline
                entry.detail = "Not sent yet: the agent is not reachable" *
                    (isempty(err) ? "" : " ($(err))") * ". It goes out once the session is back."
                go_on = false
            end
        end
        save_pending_sends!(model)
    end
    emit_queue!(model)
    entry.status == :offline &&
        @warn "agent unreachable; message held" project_id=model.project_id message_id=entry.id error=model.last_error[]
    return go_on
end

function drop_queued_sends!(model::ChatModel)
    s = shared(model)
    count = lock(s.lock) do
        n = 0
        for e in s.pending_sends
            e isa PendingSend && e.status in (:waiting, :offline, :sending) || continue
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
            # prompt! threw, so the agent did not take it. Fall back to the
            # ordinary delivery when the turn ends, which also restarts a
            # session that died under the steer.
            e.status = :waiting
            e.mode = :done
            e.detail = "Could not reach the running turn; sends when it finishes."
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
        i = findfirst(e -> e isa PendingSend && e.id == cmd.id && e.status in (:waiting, :offline, :paused), s.pending_sends)
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
    entry !== nothing && cmd.action == "send" && wake_outbox!(s)
    return nothing
end
