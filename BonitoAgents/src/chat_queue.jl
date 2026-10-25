# Pending text is an outbox, not conversation history. A submission enters
# chat.md only once prompt! has handed it to the agent connection.
#
# `riders`: what the chat would have told the agent on its own while the user
# had it stopped (`stopped`). They go out with this message, the user's next:
# shown before it and in the same prompt (`message`), never as a turn of their own.
struct PeerMessageOrigin
    id::String
    project_id::String
    title::String
    worker_id::String
    worker_name::String
    sent_at::DateTime
end

mutable struct PendingSend
    id::String
    message::UserMessage
    bubble::UserMsg
    riders::Vector{UserMsg}
    mode::Symbol
    status::Symbol
    detail::String
    span::Any
    origin::Union{PeerMessageOrigin,Nothing}
end
PendingSend(id, message, bubble, riders, mode, status, detail, span) =
    PendingSend(id, message, bubble, riders, mode, status, detail, span, nothing)

message_timestamp(at::DateTime) = Dates.format(at, dateformat"yyyy-mm-dd\THH:MM:SS.sss\Z")

function peer_message_text(origin::PeerMessageOrigin, text; dispatched_at = nothing)
    header = "Message from chat $(repr(origin.title)) (chat ID: $(origin.project_id))\n" *
        "Worker: $(repr(origin.worker_name)) (worker ID: $(origin.worker_id))\n" *
        "Message ID: $(origin.id)\nSent at (server UTC): $(message_timestamp(origin.sent_at))"
    if dispatched_at !== nothing
        delay = max(0, Dates.value(dispatched_at - origin.sent_at)) / 1000
        header *= "\nDispatched at (server UTC): $(message_timestamp(dispatched_at))\nQueued for: $(delay)s"
    end
    return header * "\n\n" * text
end

function submission_payload(entry; dispatched_at = now(UTC))
    entry.origin === nothing && return (message = entry.message, text = entry.bubble.text)
    text = peer_message_text(entry.origin, entry.bubble.text; dispatched_at)
    return (message = UserMessage(with_riders(entry.riders, text), entry.message.images), text = text)
end

origin_wire(::Nothing) = nothing
origin_wire(o::PeerMessageOrigin) = Dict("id" => o.id, "project_id" => o.project_id,
    "title" => o.title, "worker_id" => o.worker_id, "worker_name" => o.worker_name,
    "sent_at" => string(o.sent_at))
origin_from_wire(::Nothing) = nothing
origin_from_wire(o::AbstractDict) = PeerMessageOrigin(String(o["id"]), String(o["project_id"]),
    String(o["title"]), String(o["worker_id"]), String(o["worker_name"]), DateTime(o["sent_at"]))

const HELD_DETAIL = "You pressed Stop: this goes out with your next message."

# The prompt of a message with riders: theirs first, as they happened before it.
with_riders(riders::Vector{UserMsg}, text::AbstractString) =
    isempty(riders) ? String(text) : join([[r.text for r in riders]; String(text)], "\n\n")

"""
    user_ended!(model)

The user ended what the chat was doing: Stop, a restart, another agent, dev
mode. Nothing continues it on its own: a turn a worker crash cut off is not
continued, and what the chat would tell the agent unasked waits for the user's
next message (`stopped`).
"""
function user_ended!(model::ChatModel)
    forget_interrupted_turn!(model.state, model.project_id)
    shared(model).stopped[] = true
    return nothing
end

send_mode(s) = s == "interrupt" ? :interrupt : s == "next" ? :next : :done

# Continuations are idle work, unlike user/peer input or a completed job's
# notification. They are disposable as soon as there is something else to do.
function yolo_ready(model)
    s = shared(model)
    return s.yolo[] && !s.stopped[] && isempty(AgentClientProtocol.open_turns(s)) &&
        !any(e -> e isa PendingSend && e.status in (:waiting, :offline, :sending), s.pending_sends)
end

# Caller holds the chat lock and persists/broadcasts the resulting queue.
function drop_idle_sends!(model)
    for e in model.pending_sends
        e isa PendingSend && e.mode === :idle && e.status !== :sent || continue
        e.status = :superseded
    end
    filter!(e -> !(e isa PendingSend && e.status === :superseded), model.pending_sends)
    return nothing
end

# Migration for queues written before continuations had their own delivery mode.
# Match our complete generated prompt, and only on an auto message, not prose.
function persisted_idle_send(row)
    get(row, "mode", "done") == "idle" && return true
    get(row, "auto", false) || return false
    text = get(row, "text", "")
    return startswith(text, YOLO_CONTINUE_PROMPT) || startswith(text, YOLO_CONFIRM_PROMPT)
end

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
        rows = [Dict("id" => e.id, "text" => e.bubble.text, "auto" => e.bubble.auto,
            "origin" => origin_wire(e.origin),
            "riders" => [r.text for r in e.riders],
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
    dropped_idle = false
    for row in JSON.parsefile(path)
        # A continuation of an old turn is stale after restoring the chat.
        if persisted_idle_send(row)
            dropped_idle = true
            continue
        end
        bubble = UserMsg(model, String(row["text"]))
        bubble.auto = get(row, "auto", false)
        riders = UserMsg[]
        for t in get(row, "riders", Any[])
            r = UserMsg(model, String(t)); r.auto = true
            push!(riders, r)
        end
        images = [AgentClientProtocol.ImageAttachment(Base64.base64decode(i["data"]), String(i["mime"]))
                  for i in get(row, "images", Any[])]
        # A message the user paused stays paused, and one held after a Stop
        # stays held (the chat stays stopped). Anything else was never handed
        # to the agent (a handed-over entry is :sent and not persisted), so it
        # goes out once this chat's consumer runs.
        status = get(row, "status", "waiting")
        kept = status == "paused" ? :paused : status == "held" ? :held : :waiting
        kept === :held && (model.stopped[] = true)
        push!(model.pending_sends, PendingSend(String(row["id"]),
            UserMessage(with_riders(riders, bubble.text), collect(AgentClientProtocol.ImageAttachment, images)),
            bubble, riders, send_mode(get(row, "mode", "done")), kept,
            kept === :waiting ? "" : String(get(row, "detail", "")), nothing,
            origin_from_wire(get(row, "origin", nothing))))
    end
    dropped_idle && save_pending_sends!(model)
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
        items = [Dict("id" => e.id,
            "text" => e.origin === nothing ? e.bubble.text : peer_message_text(e.origin, e.bubble.text), "mode" => String(e.mode),
            "status" => String(e.status), "detail" => e.detail)
            for e in shared(model).pending_sends if e isa PendingSend && e.status != :sent]
        return Dict{String,Any}("type" => "queue.state", "items" => items)
    end
end
emit_queue!(model) = chat_emit(model, queue_event(model))

# What the chat sends on its own (`msg.auto`) while the user has it stopped is
# held; the user's next message takes everything held along (`riders`) and ends
# the stop.
function enqueue_message!(model, msg; images, mode, origin = nothing)
    s = shared(model)
    mode == :interrupt && handle_command!(s, nothing, CancelCommand())
    bubble = UserMsg(s, msg.text)
    bubble.auto = msg.auto
    entry = lock(s.lock) do
        if mode === :idle
            yolo_ready(s) || return nothing
        else
            # A new task/result supersedes any pending "are you done?" question,
            # even when it is an automatic job notification or peer message.
            reset!(s.yolo_state)
            drop_idle_sends!(s)
        end
        held = msg.auto && s.stopped[]
        riders = UserMsg[]
        if !msg.auto
            for e in s.pending_sends
                e isa PendingSend && e.status === :held && append!(riders, e.riders, [e.bubble])
            end
            filter!(e -> !(e isa PendingSend && e.status === :held), s.pending_sends)
            s.stopped[] = false
        end
        e = PendingSend(origin === nothing ? string(uuid4()) : origin.id, UserMessage(with_riders(riders, msg.text),
                collect(AgentClientProtocol.ImageAttachment, images)), bubble, riders, mode,
            held ? :held : :waiting, held ? HELD_DETAIL : "", nothing, origin)
        push!(s.pending_sends, e)
        save_pending_sends!(s)
        e
    end
    entry === nothing && return nothing
    @info "message queued" project_id=s.project_id message_id=entry.id mode status=entry.status riders=length(entry.riders)
    emit_queue!(s)
    entry.status === :held || wake_outbox!(s)
    # Native steering is safe during a quiet tool call too. Waiting for the
    # next output/tool boundary can otherwise strand input behind bt_wait.
    c = client(s.agent)
    if entry.status === :waiting && mode === :next && c !== nothing &&
            get(c.session_result, "bonitoActiveSteering", false)
        Base.errormonitor(@async deliver_boundary_message!(s))
    end
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

function submission_sent!(model, e, span; text = e.bubble.text)
    e.status = :sent
    e.bubble.text = text
    foreach(r -> close(send!(model, r)), e.riders)
    close(send!(model, e.bubble))
    # A steering span may finish before the consumer starts awaiting it. Its
    # reply baseline must be the handoff, not that later completion callback.
    e.span = span === nothing ? nothing : (turn=span, nstore0=length(model.msgs_store))
    # Native steering joins an existing turn, whose original prompt already
    # owns completion. It creates no second span to await or finalize.
    span === nothing && lock(model.lock) do
        filter!(x -> x !== e, model.pending_sends)
    end
    save_pending_sends!(model)
    emit_queue!(model)
    emit_lens_vocab(model)
    chat_emit(model, Dict{String,Any}("type" => "queue.delivered", "id" => e.id,
        "text" => e.bubble.text, "idx" => length(model.msgs_store) - 1))
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

# What a "when done" message waits for: our prompts the agent has not answered.
# Not the agent's own turns, which fold a new prompt in; a Stop winding down is
# `begin_turn`'s wait.
prompts_ahead(model) =
    filter(t -> t isa AgentClientProtocol.PromptTurn, AgentClientProtocol.open_turns(model))

# Hand one outbox entry to the agent and see its turn through. Returns whether
# the consumer should go on with the next entry.
#
# A message that was not handed over stays in the outbox:
#   * the agent could not be brought up → `:offline`, sent on the next wakeup
#     (a new message, a session coming up, its worker reconnecting). The
#     consumer stops here instead of retrying in a loop;
#   * the chat was closed → `:waiting` on disk, sent when the chat reopens;
#   * anything else failed → `:paused` with the error, for the user to judge.
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
            # Asked again after each wait: a "next" message steered in
            # meanwhile is a new prompt this one must also wait for.
            while entry.mode in (:done, :idle) && entry.status == :sending
                ahead = entry.mode === :idle ? AgentClientProtocol.open_turns(model) : prompts_ahead(model)
                isempty(ahead) && break
                entry.detail = "Waiting until the agent finishes"
                emit_queue!(model)
                foreach(wait, ahead)
            end
            entry.status == :sending || return true
            entry.detail = ""
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

# Stop: what the user queued is paused (they send it again or remove it); what
# the chat queued on its own is held for the user's next message.
function drop_queued_sends!(model::ChatModel)
    s = shared(model)
    count = lock(s.lock) do
        n = 0
        for e in s.pending_sends
            e isa PendingSend && e.status in (:waiting, :offline, :sending) || continue
            if e.bubble.auto
                e.status = :held
                e.detail = HELD_DETAIL
            else
                e.status = :paused
                e.detail = "Not sent: paused by Stop. Send it again or remove it."
            end
            n += 1
        end
        drop_idle_sends!(s)
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
    isempty(AgentClientProtocol.open_turns(c)) && return nothing
    cancelling(s) && return nothing
    native = get(c.session_result, "bonitoActiveSteering", false)
    entry = lock(s.lock) do
        i = findfirst(e -> e isa PendingSend && e.status == :waiting && e.mode == :next, s.pending_sends)
        i === nothing && return nothing
        e = s.pending_sends[i]
        if !native && !get(c.session_result, "bonitoPromptQueueing", false)
            e.mode = :done
            e.detail = "This agent does not advertise steering; waiting until the turn finishes."
            save_pending_sends!(s)
            emit_queue!(s)
            return nothing
        end
        e.status = :sending
        e
    end
    entry === nothing && return nothing
    try
        payload = submission_payload(entry)
        span = if native
            injected = AgentClientProtocol.steer!(c, with_prelude(s, payload.message.text); images=payload.message.images)
            if !injected
                lock(s.lock) do
                    if entry.status === :sending
                        entry.status = :waiting
                        entry.mode = :done
                        entry.detail = "The running turn finished; sending as the next prompt."
                    end
                    save_pending_sends!(s)
                end
                emit_queue!(s)
                wake_outbox!(s)
                return nothing
            end
            nothing
        else
            lock(s.lock) do
                entry.status === :sending || return nothing
                AgentClientProtocol.prompt!(c, with_prelude(s, payload.message.text); images=payload.message.images)
            end
        end
        !native && span === nothing && return nothing
        lock(s.lock) do
            submission_sent!(s, entry, span; text = payload.text)
        end
        native && wake_agent_waits!(s)
    catch err
        lock(s.lock) do
            # A rejected steer was not delivered. Preserve a concurrent Stop
            # rather than rearming its paused entry when the response arrives.
            if entry.status === :sending
                entry.status = native ? :paused : :waiting
                entry.mode = :done
                entry.detail = native ? "Delivery was not confirmed: $(sprint(showerror, err)). Send again or remove it." :
                    "Could not reach the running turn; sends when it finishes."
            end
            save_pending_sends!(s)
        end
        emit_queue!(s)
        wake_outbox!(s)
        @error "message steering failed" project_id=s.project_id message_id=entry.id exception=(err, catch_backtrace())
    end
    return nothing
end

function handle_command!(model::ChatModel, ::Any, cmd::QueueActionCommand)
    s = shared(model)
    entry = lock(s.lock) do
        i = findfirst(e -> e isa PendingSend && e.id == cmd.id && e.status in (:waiting, :offline, :paused, :held), s.pending_sends)
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
