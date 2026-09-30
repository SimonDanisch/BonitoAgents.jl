# ── Julia runs in the chat ───────────────────────────────────────────────────
# A RUN is one `bt_julia_eval` (BonitoMCP runs.jl): it has an id (`r4`) and can
# outlive the tool call that started it — `bt_julia_eval(background = true)`
# returns at once, a foreground eval can pass its checkpoint. The chat follows
# the RUN, not the call:
#
#   * its card stays live (status, timer, live output tail) until the run ends,
#     then shows the run's own result, whenever the agent gets round to it;
#   * while the call is over and the run is not, it sits in the task bar
#     (`r4 · MacBook · BonitoAgents/test`), and its ⊗ stops that run only;
#   * when a run the agent has not collected ends, the agent is told, in one
#     note per batch, once it is idle (the user chose this over UI-only).
#
# What the chat knows comes from `run_update` frames: the chat's own MCP sends
# them for runs on its worker, an eval host for runs on another (`host_worker`),
# at a run's start, its end (with the content the card shows) and when the agent
# collects it. On (re)connect each process announces its open runs again, so a
# server restart loses nothing it can still see.

# How long several finishing runs are given to share one note — and a
# `bt_julia_wait` already blocked on them to collect them, which makes the note
# unnecessary.
const RUN_NOTE_BATCH_S = 3.0
# How often a note waiting for the agent to go idle looks again.
const RUN_NOTE_POLL_S  = 2.0
# How long a run whose process lost its channel keeps running in the chat before
# it counts as lost: a reconnect (link blip, server restart on the other side)
# announces it again within seconds.
const RUN_LOST_GRACE_S = 60.0

run_live(m::JuliaEvalToolMsg) = m.run !== nothing && m.run.status == "running"
run_live(::JuliaEvalCall) = false

# ── The card follows its run ─────────────────────────────────────────────────
eval_streaming(m::JuliaEvalToolMsg) =
    tool_status(m) in ("pending", "in_progress") || run_live(m)

in_taskbar(m::JuliaEvalToolMsg) = m.task_bar !== nothing
# A run takes a task-bar slot once its call is over and it is not: a background
# run from the start, a foreground one when it passed its checkpoint. A run that
# ends inside its call never flashes into the bar.
is_taskbar_item(m::JuliaEvalToolMsg) =
    run_live(m) && (m.run.background || tool_status(m) in ("completed", "failed"))
is_live(m::JuliaEvalToolMsg) = in_taskbar(m) || run_live(m) ||
    (tool_finished_at(m) === nothing && !(tool_status(m) in ("completed", "failed")))

# Out of the bar once the run ended and the agent has its result — or a while
# after the end, so a finished row never waits on the agent forever.
function isdone(m::JuliaEvalToolMsg)
    r = m.run
    r === nothing && return true
    r.status == "running" && return false
    return r.collected || time() - r.finished > REPORT_WAIT_SECONDS
end

finalize!(m::JuliaEvalToolMsg) = close(m)

# History holds a card once, however many ends it has (its call's, its run's).
function Base.close(m::JuliaEvalToolMsg)
    m.closed && return nothing
    m.closed = true
    return invoke(close, Tuple{ToolMsg}, m)
end

# The result the card shows: the run's own once it ended, the call's for an eval
# that ended inside its call, and nothing while a run is still going (the live
# tail owns the Output then). `nothing` is "no final content yet" to
# `eval_result!`.
result_content(::JuliaEvalCall, acp_content) = acp_content
function result_content(m::JuliaEvalToolMsg, acp_content)
    rc = run_content(m)
    rc === nothing || return rc
    (m.background || run_live(m)) && return nothing
    return acp_content
end

# The finished run's content: in memory, or from its file after a restart.
function run_content(m::JuliaEvalToolMsg)
    r = m.run
    r !== nothing && !isempty(r.content) && return r.content
    chat = tool_chat(m)
    chat === nothing && return nothing
    path = run_content_file(chat.chat_dir, tool_id(m))
    isfile(path) || return nothing
    return AgentClientProtocol.parse_tool_content(get(open(JSON.parse, path), "content", Any[]))
end

run_content_file(chat_dir::AbstractString, tool_id::AbstractString) =
    joinpath(tools_dir(chat_dir), String(tool_id) * ".run.json")

# The header of a run's card, whoever builds it (a live update or a re-render
# from the store): live while the run is, in the bar when it is.
function run_header_extras!(d::Dict, m::JuliaEvalToolMsg)
    run_live(m) || return nothing
    d["status"] = "in_progress"
    delete!(d, "finished_at")
    d["taskbar"] = is_taskbar_item(m)
    m.run.background && (d["background"] = true)
    return nothing
end
run_header_extras!(::Dict, ::JuliaEvalCall) = nothing

# ── Labels ───────────────────────────────────────────────────────────────────
function run_worker_name(state::ServerState, chat::ChatModel, r::ChatRun)
    wid = isempty(r.worker_id) ? bg_worker_id(state, chat) : r.worker_id
    wid === nothing && return "this worker"
    w = get(state.workers[], wid, nothing)
    return w === nothing ? wid : w.name
end

# `BonitoAgents/test` for `/home/me/code/BonitoAgents/test`, `temp env` for none.
function short_env(env::AbstractString)
    isempty(env) && return "temp env"
    parts = splitpath(rstrip(env, '/'))
    return join(parts[max(1, end - 1):end], "/")
end

# How a run ended, short (the task bar's row has its own clock) …
run_verdict(r::ChatRun) =
    r.status == "passed" ? "✓ passed" :
    r.status == "running" ? "running" :
    "✗ " * r.status * (isempty(r.summary) ? "" : " — " * r.summary)

# … and with its duration, for the card and the note to the agent.
function run_outcome(r::ChatRun)
    took = elapsed_str(r.finished - r.started)
    took = isempty(took) ? "" : " after " * took
    r.status == "passed" && return "✓ passed" * took
    return "✗ " * r.status * took * (isempty(r.summary) ? "" : " — " * r.summary)
end

function eval_env_summary(m::JuliaEvalToolMsg)
    base = eval_env_label(m)
    r = m.run
    r === nothing && return base
    r.status == "running" && return "$(r.id) · running · $(base)"
    return "$(r.id) · $(run_outcome(r)) · $(base)"
end

taskbar_icon(::JuliaEvalToolMsg) = "▶"
# `r4 · BonitoAgents/test`, and the worker only when it is another one: the row
# is narrow, and "agent waiting" has to fit next to it.
function taskbar_label(m::JuliaEvalToolMsg)
    r = m.run
    chat = tool_chat(m)
    (r === nothing || chat === nothing) && return first(pretty_tool_title(tool_title(m)))
    on = isempty(r.worker_id) ? "" : " · " * run_worker_name(chat.state, chat, r)
    return "$(r.id)$(on) · $(short_env(r.env_path))"
end
# The row says how a run ended once it has; while it runs, its clock is the
# news (the live output is on the card). A row's content is its KeyedList key,
# and a key that followed the output would rebuild a chatty run's row twice a
# second — under the pointer, so its ⊗ could not be clicked.
has_activity_feed(::JuliaEvalToolMsg) = true
function taskbar_activity(m::JuliaEvalToolMsg, ::Float64)
    r = m.run
    r === nothing && return nothing
    r.status == "running" || return run_verdict(r)
    return awaited(m) ? "agent waiting" : nothing
end
taskbar_dyn_key(m::JuliaEvalToolMsg) =
    m.run === nothing ? "" : string(m.run.status, awaited(m) ? "|awaited" : "")

# ── What the processes tell us ───────────────────────────────────────────────
"""
    run_update!(state, project_id, host_worker, frame)

Apply a `run_update` frame from a chat's MCP (`host_worker == ""`) or from its
eval host on another worker.
"""
function run_update!(state::ServerState, project_id::AbstractString,
                     host_worker::AbstractString, d::AbstractDict)
    chat = lock(() -> get(state.chat_models, String(project_id), nothing), state.lock)
    chat === nothing && return nothing
    chat = shared(chat)
    id = String(get(d, "run", ""))
    isempty(id) && return nothing
    book = chat.runs
    r = lock(book.lock) do
        get!(book.runs, id) do
            ChatRun(id, "", String(host_worker), "", "", false, time(), "running", 0.0, "",
                    false, false, Any[], nothing)
        end
    end
    tuid = String(get(d, "tool_use_id", ""))
    isempty(tuid) || (r.tool_use_id = tuid)
    was = r.status
    if haskey(d, "status")
        r.worker_id  = String(host_worker)
        route        = String(get(d, "route", ""))
        r.route      = isempty(host_worker) ? route : String(host_worker) * "\0" * route
        env          = get(d, "env_path", nothing)
        r.env_path   = env isa AbstractString ? String(env) : ""
        r.background = get(d, "background", false) === true
        r.started    = Float64(get(d, "started", r.started))
        r.status     = String(d["status"])
        r.summary    = String(get(d, "summary", ""))
        r.status == "running" || (r.finished = r.started + Float64(get(d, "elapsed", 0.0)))
    end
    get(d, "collected", false) === true && (r.collected = true)
    if r.status != "running" && haskey(d, "content")
        r.content = Any[AgentClientProtocol.parse_content_block(c) for c in d["content"]
                        if c isa AbstractDict]
    end
    r.card === nothing && bind_card!(chat, r)
    card = r.card
    if r.status == "running"
        card === nothing || run_running!(chat, card; reopened = was != "running")
    elseif was == "running" || haskey(d, "content")
        card === nothing || run_ended!(chat, card)
        r.collected || note_finished_runs!(chat)
    end
    return nothing
end

# The card-side half of binding: an eval card that appears after its run was
# announced (`adopt_run!` runs on each of its frames until it has one) takes
# the run over and catches up on where it is.
adopt_run!(::JuliaEvalCall) = nothing
function adopt_run!(m::JuliaEvalToolMsg)
    m.run === nothing || return nothing
    chat = tool_chat(m)
    chat === nothing && return nothing
    chat = shared(chat)
    state = chat.state
    r = lock(chat.runs.lock) do
        best = nothing
        for c in values(chat.runs.runs)
            c.card === nothing && run_matches(state, c, m) || continue
            (best === nothing || c.started > best.started) && (best = c)
        end
        best
    end
    r === nothing && return nothing
    m.run = r
    r.card = m
    if r.status == "running"
        run_running!(chat, m)
    else
        run_ended!(chat, m)
    end
    return nothing
end

# Is `m` the card of run `r`? By the id Claude names, else by worker + env.
run_matches(state::ServerState, r::ChatRun, m::JuliaEvalToolMsg) =
    isempty(r.tool_use_id) ? eval_route_key(state, m) == r.route :
                             r.tool_use_id == tool_id(m)

# The card a run belongs to: the one Claude Code named (its tool id is the
# card's), else the newest eval card for the same worker + env that has no run
# yet (agents that name nothing). It may not exist yet — see `adopt_run!`.
function bind_card!(chat::ChatModel, r::ChatRun)
    state = chat.state
    card = lock(chat.lock) do
        store = chat.msgs_store
        i = findlast(m -> m isa JuliaEvalToolMsg && m.run === nothing &&
                          run_matches(state, r, m), store)
        i === nothing ? nothing : store[i]
    end
    card === nothing && return nothing
    card.run = r
    r.card = card
    return card
end

# A running run: its card live, in the bar when due, its tail listening.
function run_running!(chat::ChatModel, m::JuliaEvalToolMsg; reopened::Bool = false)
    h = m.message
    if reopened && h.finished_at !== nothing
        # Its call ended before we heard of the run (the two travel separate
        # roads): the card comes back to life.
        h.finished_at = nothing
    end
    is_taskbar_item(m) && push!(chat_taskbar(chat), m)
    h.summary = eval_env_summary(m)
    d = Dict{String,Any}("type" => "tool_update", "id" => h.id, "summary" => h.summary)
    if is_taskbar_item(m)
        d["status"] = "in_progress"
        d["taskbar"] = true
        m.run.background && (d["background"] = true)
        d["reopen"] = true           # drops a frozen timer from the call's end
    end
    chat_emit(chat, d)
    isempty(m.code) || start_eval_stream!(m)
    return nothing
end

# The run ended: its content becomes the card's result. Kept in its own file
# next to the call's content (which the call's completion may still overwrite),
# so a reload shows the run's result, not the call's start notice.
function run_ended!(chat::ChatModel, m::JuliaEvalToolMsg)
    r = m.run
    h = m.message
    content = r.content
    isempty(content) || atomic_write(run_content_file(chat.chat_dir, h.id)) do io
        JSON.print(io, Dict{String,Any}("content" => [tool_content_to_dict(c) for c in content]))
    end
    h.summary = eval_env_summary(m)
    d = Dict{String,Any}("type" => "tool_update", "id" => h.id, "summary" => h.summary)
    # A foreground run that ended INSIDE its call: the call's own completion
    # finishes the card (the consumer is still iterating its frames, and two
    # writers would flip its status back and forth). Otherwise it is ours.
    if in_taskbar(m) || tool_status(m) in ("completed", "failed")
        h.status = "completed"
        h.finished_at = r.finished > 0 ? r.finished : time()
        d["status"] = h.status
        d["finished_at"] = h.finished_at
    end
    eval_result!(m, result_content(m, content))
    auto_expand_body(m, content) && (d["expand"] = true)
    auto_expand_full(m, content) && (d["expand_full"] = true)
    live_result_embed(m, content) && (d["live_embed"] = true)
    chat_emit(chat, d)
    # In the bar, the bar's loop takes it out (`isdone`) once the agent has the
    # result; a call that is over and never reached the bar is closed here.
    in_taskbar(m) || (haskey(d, "status") && close(m))
    return nothing
end

# ── Stopping a run (the card's ⊗) ────────────────────────────────────────────
"""
    stop_run!(model, t) -> Bool

Stop the run of eval card `t` through the process that runs it. False when the
card has no live run (the caller falls back to the env-wide interrupt).
"""
stop_run!(::ChatModel, ::JuliaEvalCall) = false
function stop_run!(model::ChatModel, t::JuliaEvalToolMsg)
    run_live(t) || return false
    r = t.run
    tid = tool_id(t)
    chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => tid,
        "status" => "in_progress", "summary" => "$(r.id) · stopping…"))
    Base.errormonitor(@async try
        interrupt_run!(model.state, model.project_id, r) ||
            chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => tid,
                "status" => "in_progress", "summary" => "$(r.id) had already finished"))
    catch e
        e isa InterruptException && rethrow()
        @warn "run interrupt failed" run = r.id tool_id = tid exception = e
        chat_emit(model, Dict{String,Any}("type" => "tool_update", "id" => tid,
            "status" => "in_progress", "summary" => "$(r.id) · stop failed: $(sprint(showerror, e))"))
    end)
    return true
end

# ── Telling the agent ────────────────────────────────────────────────────────
# One task per chat at a time: waits for a batch to gather, then for the agent
# to be idle, and says which runs finished. Runs collected meanwhile (the agent
# was already waiting on them) are left out; with none left, nothing is sent.
function note_finished_runs!(chat::ChatModel)
    book = shared(chat).runs
    lock(book.lock) do
        book.notifier === nothing || return nothing
        book.notifier = Base.errormonitor(@async deliver_run_notes!(shared(chat)))
    end
    return nothing
end

due_notes(book::RunBook) = lock(book.lock) do
    sort!([r for r in values(book.runs) if r.status != "running" && !r.collected && !r.notified];
          by = r -> r.finished)
end

chat_open(chat::ChatModel) =
    lock(() -> get(chat.state.chat_models, chat.project_id, nothing) === chat, chat.state.lock)

function deliver_run_notes!(chat::ChatModel)
    book = chat.runs
    try
        sleep(RUN_NOTE_BATCH_S)
        while chat_open(chat)
            due = due_notes(book)
            isempty(due) && return nothing
            if chat.busy_active[]
                sleep(RUN_NOTE_POLL_S)
                continue
            end
            lock(book.lock) do
                foreach(r -> r.notified = true, due)
            end
            note = UserMsg(chat, run_note_text(chat, due))
            note.auto = true
            send_message!(chat, note)
            return nothing
        end
    finally
        lock(book.lock) do; book.notifier = nothing; end
    end
    return nothing
end

function run_note_text(chat::ChatModel, runs::Vector{ChatRun})
    line(r) = "$(r.id) ($(short_env(r.env_path)) on $(run_worker_name(chat.state, chat, r))): " *
              run_outcome(r)
    ids = join(("\"$(r.id)\"" for r in runs), ", ")
    head = length(runs) == 1 ? "Background Julia run finished: " * line(only(runs)) :
           "Background Julia runs finished:\n" * join(("- " * line(r) for r in runs), "\n")
    return head * "\nCollect the result$(length(runs) == 1 ? "" : "s") with " *
           "bt_julia_wait(runs = [$(ids)], seconds = 60)."
end

# ── A process that went away ─────────────────────────────────────────────────
"""
    runs_channel_closed!(state, project_id, host_worker)

The channel of the process running some of a chat's runs closed. Unless it is
back within `RUN_LOST_GRACE_S` (and has announced them again), its running runs
end as `lost`: that process, and the evals in it, are gone.
"""
function runs_channel_closed!(state::ServerState, project_id::AbstractString,
                              host_worker::AbstractString; grace::Real = RUN_LOST_GRACE_S)
    Base.errormonitor(@async begin
        sleep(grace)
        back = isempty(host_worker) ? mcp_ctrl_for(state, project_id) !== nothing :
                                      eval_host_ws(state, project_id, host_worker) !== nothing
        back && return nothing
        chat = lock(() -> get(state.chat_models, String(project_id), nothing), state.lock)
        chat === nothing && return nothing
        chat = shared(chat)
        lost = lock(chat.runs.lock) do
            [r for r in values(chat.runs.runs) if r.status == "running" && r.worker_id == host_worker]
        end
        for r in lost
            r.status  = "lost"
            r.summary = "the process running it went away"
            r.finished = time()
            r.card === nothing || run_ended!(chat, r.card)
        end
        isempty(lost) || @info "runs lost with their process" project_id host_worker runs = [r.id for r in lost]
    end)
    return nothing
end

# ── What a continue or a wait is waiting on ──────────────────────────────────
# A `bt_julia_continue` can come long after its eval, with half a conversation
# in between, and on its own it said only "env …". So a continue (and a
# `bt_julia_wait`) names the eval it waits on — its run id and the first line
# of its code — and carries a ↑ chip that brings that eval's card into view.
# While the agent is blocked on a run, that run's task-bar row says so.

"""
    continued_eval(m) -> Union{JuliaEvalToolMsg,Nothing}

The eval card a `bt_julia_continue` waits on: its run's card when it names a
run, else the newest eval card before it on the same worker and env (how every
continue addressed an eval before there were runs).
"""
function continued_eval(m::JuliaContinueToolMsg)
    chat = tool_chat(m)
    chat === nothing && return nothing
    chat = shared(chat)
    if !isempty(m.run)
        r = lock(() -> get(chat.runs.runs, m.run, nothing), chat.runs.lock)
        return r === nothing ? nothing : r.card
    end
    key = eval_route_key(chat.state, m)
    return lock(chat.lock) do
        store = chat.msgs_store
        me = findlast(x -> x === m, store)
        i = findprev(x -> x isa JuliaEvalToolMsg && eval_route_key(chat.state, x) == key, store,
                     me === nothing ? length(store) : me - 1)
        i === nothing ? nothing : store[i]
    end
end

"The eval cards a `bt_julia_wait` waits on: its runs' cards (every open run's, when it names none)."
function waited_evals(m::JuliaWaitToolMsg)
    chat = tool_chat(m)
    chat === nothing && return JuliaEvalToolMsg[]
    book = shared(chat).runs
    runs = lock(book.lock) do
        isempty(m.runs) ?
            sort!([r for r in values(book.runs) if r.status == "running" || !r.collected]; by = r -> r.started) :
            [book.runs[id] for id in m.runs if haskey(book.runs, id)]
    end
    return JuliaEvalToolMsg[r.card for r in runs if r.card !== nothing]
end

# How a waiter names an eval: its run id, else just "eval".
eval_ref(e::JuliaEvalToolMsg) = e.run === nothing ? "eval" : e.run.id

# The first line of an eval's code, short enough for a header.
function code_gist(e::JuliaEvalToolMsg; width::Int = 48)
    for l in split(e.code, '\n')
        s = strip(l)
        isempty(s) && continue
        return length(s) <= width ? String(s) : String(first(s, width - 1)) * "…"
    end
    return ""
end

function continue_summary(m::JuliaContinueToolMsg)
    e = continued_eval(m)
    e === nothing && return isempty(m.run) ? eval_env_label(m) : "continue " * m.run
    gist = code_gist(e)
    head = "↳ " * eval_ref(e) * (isempty(gist) ? "" : " · " * gist)
    tool_status(m) in ("pending", "in_progress") && return head
    r = e.run
    r === nothing && return head
    return head * " · " * (r.status == "running" ? "still running" : run_verdict(r))
end
eval_env_summary(m::JuliaContinueToolMsg) = continue_summary(m)

# The ↑ chips a card's header shows: where each eval it waits on sits in the
# chat (its store index — the client scrolls there by its own geometry, so it
# works for a card that is not rendered) and its id (to light it up).
function jump_to(e::JuliaEvalToolMsg)
    chat = tool_chat(e)
    chat === nothing && return nothing
    idx = lock(() -> findfirst(x -> x === e, shared(chat).msgs_store), shared(chat).lock)
    idx === nothing && return nothing
    gist = code_gist(e)
    return Dict{String,Any}("label" => eval_ref(e), "index" => idx - 1, "id" => tool_id(e),
                            "title" => "Show the eval this waits on" * (isempty(gist) ? "" : ": " * gist))
end

jump_extras!(::Dict, ::MCPToolMsg) = nothing
function jump_extras!(d::Dict, m::JuliaContinueToolMsg)
    e = continued_eval(m)
    j = e === nothing ? nothing : jump_to(e)
    j === nothing || (d["jumps"] = Any[j])
    # The summary rides along: a header can be built before any update has
    # set one (an agent that sends its arguments up front), and "↳ r4 · …" is
    # the point of this card.
    e === nothing || (d["summary"] = m.message.summary = continue_summary(m))
    return nothing
end
function jump_extras!(d::Dict, m::JuliaWaitToolMsg)
    js = Any[j for j in (jump_to(e) for e in waited_evals(m)) if j !== nothing]
    isempty(js) || (d["jumps"] = js)
    return nothing
end

# Is the agent blocked on this eval's run right now (a pending continue or wait
# for it)? Asked by the task-bar row, once a second.
waits_on(w::JuliaContinueToolMsg, e::JuliaEvalToolMsg) = continued_eval(w) === e
waits_on(w::JuliaWaitToolMsg, e::JuliaEvalToolMsg) =
    e.run !== nothing && (isempty(w.runs) || e.run.id in w.runs)
function awaited(e::JuliaEvalToolMsg)
    chat = tool_chat(e)
    chat === nothing && return false
    chat = shared(chat)
    waiters = lock(chat.lock) do
        [x for x in chat.msgs_store if (x isa JuliaContinueToolMsg || x isa JuliaWaitToolMsg) &&
                                      tool_status(x) in ("pending", "in_progress")]
    end
    return any(w -> waits_on(w, e), waiters)
end
