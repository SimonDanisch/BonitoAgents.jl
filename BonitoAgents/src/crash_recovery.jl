# ── Continuing chats after a worker crash ────────────────────────────────────
# A worker that crashes (killed, out of memory, segfault, power loss) takes its
# agents with it, and a chat that was in the middle of a turn just stops. When
# the worker is back, such a chat gets ONE automatic message asking the agent to
# carry on. Only then, and never on a guess:
#
#   * the CRASH is the worker's own statement. Every run of a worker has an id
#     (its hello's `instance`), kept in its pidfile, which a run removes when it
#     exits, a service stop (SIGTERM) included. A new run that finds the file of
#     a run that is gone reports that run as its `crashed_instance`
#     (BonitoWorker's `crashed_instance`). A network drop keeps the same run (the
#     link resumes), a stop or an update removes the file, and a worker from
#     before this reports nothing.
#   * the TURN is the server's record: when a worker's link first stops being
#     connected, every chat of that worker with a turn of ours in flight, its
#     prompt delivered and nothing queued behind it, is noted with the worker's
#     run and the chat's turn number (`note_interrupted_turns!`). A link that
#     resumes drops the notes: the turns carry on by themselves.
#   * a new link whose `crashed_instance` is the noted run continues exactly
#     those chats (`recover_interrupted_turns!`), if nothing happened in them
#     since: a message sent, a stop clicked or the chat closed drops the note
#     (`forget_interrupted_turn!`), and the turn number must still be the noted
#     one.
#   * a turn that was itself such a continuation is not continued again: a turn
#     that crashes its worker would otherwise crash it forever.
# The notes live in memory: a server restart in between forgets them, and then
# nothing is continued.

const CRASH_CONTINUE_PROMPT =
    "The worker running this chat crashed while you were working on the request above, " *
    "and has restarted. Whatever was running (tools, background processes, Julia sessions) " *
    "was stopped. Check where things stand, then carry on where you left off."

crash_continue_msg() = UserMsg(CRASH_CONTINUE_PROMPT, false, 0, true, nothing)

"""
    interrupted_turn(chat) -> Union{Nothing,Tuple{Int,Bool}}

The turn of ours `chat` is in the middle of, as (turn number, whether it is a
crash continuation), or `nothing`: no turn in flight, its prompt not delivered
yet (the agent never saw it), or messages the user sent queued behind it (those
carry the chat on by themselves).
"""
function interrupted_turn(chat::ChatModel)
    s = shared(chat)
    return lock(s.lock) do
        # The outbox keeps the message being answered (status :sent) until its
        # turn ends, so only a message not delivered yet is one queued behind it.
        queued_behind = any(e -> e isa PendingSend && e.status !== :sent, s.pending_sends)
        (s.turn_in_flight[] && !queued_behind) || return nothing
        i = findlast(m -> m isa UserMsg, s.msgs_store)
        prompt = i === nothing ? nothing : s.msgs_store[i]
        (s.turn_seq[], prompt !== nothing && prompt.auto && prompt.text == CRASH_CONTINUE_PROMPT)
    end
end

"""
    note_interrupted_turns!(state, worker_id)

The worker's link stopped being connected: note the chats it had in the middle
of a turn, with the run of the worker they ran on. Once per outage of a run, at
its first moment: the link's later `:dead` must not note a chat again whose note
the user dropped meanwhile (a stop clicked while the worker was away), while its
turn still looks in flight.
"""
function note_interrupted_turns!(state::ServerState, worker_id::AbstractString)
    watch = state.crash_watch
    instance, candidates = lock(state.lock) do
        run = get(watch.instances, worker_id, "")
        (isempty(run) || get(watch.noted, worker_id, "") == run) && return (run, ChatModel[])
        watch.noted[String(worker_id)] = run
        chats = ChatModel[m for (pid, m) in state.chat_models
                          if (p = get(state.projects[], pid, nothing)) !== nothing && p.worker_id == worker_id]
        (run, chats)
    end
    noted = String[]
    for m in candidates
        turn = interrupted_turn(m)
        turn === nothing && continue
        lock(state.lock) do
            haskey(watch.interrupted, m.project_id) ||
                (watch.interrupted[m.project_id] = InterruptedTurn(String(worker_id), instance,
                                                                   turn[1], turn[2], time()))
        end
        push!(noted, m.project_id)
    end
    isempty(noted) || @info "worker link down with turns in flight" worker_id instance chats = noted
    return nothing
end

# The same run of the worker carries on (its link resumed): so do its turns.
function forget_interrupted_turns!(state::ServerState, worker_id::AbstractString)
    lock(state.lock) do
        filter!(kv -> kv.second.worker_id != worker_id, state.crash_watch.interrupted)
        delete!(state.crash_watch.noted, String(worker_id))
    end
    return nothing
end

"The user acted on the chat (sent, stopped, closed it): it is theirs, not ours to continue."
forget_interrupted_turn!(state::ServerState, project_id::AbstractString) =
    (lock(() -> delete!(state.crash_watch.interrupted, String(project_id)), state.lock); nothing)

"""
    worker_run_started!(state, worker_id, hello)

A new link from the worker (a new run of it, or the same run after its link was
reset): remember which run it is, and continue what the run it says crashed cut
off.
"""
function worker_run_started!(state::ServerState, worker_id::AbstractString, hello::AbstractDict)
    crashed = String(get(hello, "crashed_instance", ""))
    lock(state.lock) do
        state.crash_watch.instances[String(worker_id)] = String(get(hello, "instance", ""))
    end
    isempty(crashed) || @warn "worker restarted after a crash" worker_id crashed_instance = crashed
    recover_interrupted_turns!(state, worker_id, crashed)
    return nothing
end

"""
    recover_interrupted_turns!(state, worker_id, crashed) -> Vector{String}

Settle the worker's notes: continue each chat whose turn ran on the run that
crashed (`crashed`, "" when none did), and drop the rest. Returns the chats
continued.
"""
function recover_interrupted_turns!(state::ServerState, worker_id::AbstractString, crashed::AbstractString)
    notes = lock(state.lock) do
        mine = [(pid, t) for (pid, t) in state.crash_watch.interrupted if t.worker_id == worker_id]
        foreach(n -> delete!(state.crash_watch.interrupted, n[1]), mine)
        delete!(state.crash_watch.noted, String(worker_id))   # the next outage is a new one
        mine
    end
    continued = String[]
    for (pid, t) in notes
        if isempty(crashed) || t.instance != crashed
            @info "a turn was cut off, but its worker did not crash (it stopped or restarted cleanly): not continued" project_id = pid worker_id
        elseif t.was_continue
            @warn "not continuing a chat again: its worker crashed during the last continuation" project_id = pid worker_id
        elseif continue_after_crash!(state, pid, t)
            push!(continued, pid)
        end
    end
    return continued
end

function continue_after_crash!(state::ServerState, project_id::AbstractString, t::InterruptedTurn)
    m = lock(() -> get(state.chat_models, String(project_id), nothing), state.lock)
    m === nothing && return false
    if shared(m).turn_seq[] != t.turn_seq
        @info "not continuing a chat after a crash: it has had another turn since" project_id
        return false
    end
    @info "continuing a chat its worker's crash cut off" project_id worker_id = t.worker_id
    send_message!(m, crash_continue_msg())
    return true
end
