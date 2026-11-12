mutable struct ProcessBook
    lock::ReentrantLock
    jobs::Dict{String,Any}
    tasks::Dict{String,Any}
    epoch::String
    retired::Vector{String}
    path::String
    last_saved::Float64
end

function process_book(state, pid)
    state = root_state(state)
    lock(state.lock) do
        get!(state.process_jobs,String(pid)) do
            path = joinpath(state.state_dir,"chats",pid,"process_jobs.json")
            raw = load_json_tolerant(path,"managed processes")
            jobs = raw === nothing ? Dict{String,Any}() : Dict{String,Any}(raw["jobs"])
            for d in values(jobs); d["connected"] = false; end
            book = ProcessBook(ReentrantLock(),jobs,Dict{String,Any}(),
                raw === nothing ? string(uuid4()) : String(raw["epoch"]),
                raw === nothing ? String[] : String.(raw["retired"]),path,0.0)
            # The epoch must be durable before it reaches any MCP process:
            # a server crash before the first job update must not forget it.
            raw === nothing && save_process_book!(book)
            book
        end
    end
end

function save_process_book!(book)
    atomic_write_json(book.path,Dict("epoch"=>book.epoch,"retired"=>book.retired,"jobs"=>book.jobs))
    book.last_saved = time()
    return nothing
end

managed_process_epoch(state,pid) = lock(() -> process_book(state,pid).epoch, process_book(state,pid).lock)

mutable struct ManagedProcessTask <: SupervisedTask
    chat::ChatModel
    worker::String
    snapshot::Dict{String,Any}
    task_bar::Union{Nothing,TaskBar}
end

managed_task_id(worker,id) = "managed:" * worker * ":" * id
msg_id(t::ManagedProcessTask) = managed_task_id(t.worker,t.snapshot["id"])
in_taskbar(t::ManagedProcessTask) = t.task_bar !== nothing
isdone(t::ManagedProcessTask) = !(t.snapshot["status"] in BonitoWorker.PROCESS_ACTIVE)
finalize!(::ManagedProcessTask) = nothing
taskbar_slot_label(t::ManagedProcessTask, fallback) = t.snapshot["label"]
has_activity_feed(::ManagedProcessTask) = true
function taskbar_activity(t::ManagedProcessTask, now::Float64)
    w = get(t.chat.state.workers[],t.worker,nothing)
    connected = get(t.snapshot,"connected",false) && w !== nothing && isopen(w)
    return !connected ? "worker disconnected" : !isempty(get(t.snapshot,"control_error","")) ?
        t.snapshot["control_error"] : t.snapshot["status"]
end
taskbar_dyn_key(t::ManagedProcessTask) =
    string(t.snapshot["revision"], ':', t.snapshot["output_bytes"], ':', taskbar_activity(t,time()))
taskbar_item_for(t::ManagedProcessTask) = TaskbarItem(msg_id(t),:process,"⚙",t.snapshot["label"];
    started=t.snapshot["started"],stoppable=true,source=t)

function attach_process_tasks!(chat::ChatModel)
    chat = shared(chat)
    isopen(chat.taskbar) || return nothing
    book = process_book(chat.state,chat.project_id)
    lock(book.lock) do
        for (key,d) in book.jobs
            task = get(book.tasks,key,nothing)
            if !(d["status"] in BonitoWorker.PROCESS_ACTIVE)
                task === nothing || finished!(task)
                delete!(book.tasks,key)
                continue
            end
            if task === nothing || task.chat !== chat
                task = ManagedProcessTask(chat,String(d["worker"]),copy(d),nothing)
                book.tasks[key] = task
            else
                task.snapshot = copy(d)
            end
            if d["status"] in BonitoWorker.PROCESS_ACTIVE
                push!(chat.taskbar,task)
            elseif in_taskbar(task)
                finished!(task)
            end
        end
    end
    return nothing
end

function detach_process_tasks!(chat)
    state = root_state(chat.state)
    book = lock(() -> get(state.process_jobs,chat.project_id,nothing),state.lock)
    book === nothing && return nothing
    lock(book.lock) do
        filter!(kv -> kv.second.chat !== chat,book.tasks)
    end
    return nothing
end

function managed_process_update!(state,worker,d)
    pid = String(d["project_id"])
    p = get(state.projects[],pid,nothing)
    p === nothing && return nothing
    p.worker_id == worker || return nothing
    book = process_book(state,pid)
    retired, prompt_changed = lock(book.lock) do
        key = managed_task_id(worker,String(d["id"]))
        previous = get(book.jobs,key,nothing)
        previous !== nothing && (d["revision"],d["output_bytes"]) <
            (previous["revision"],previous["output_bytes"]) && return (false, false)
        record = merge(Dict{String,Any}(d),Dict("worker"=>String(worker),"connected"=>true))
        record["output"] = last(String(get(record,"output","")),2048)
        record["notify_pending"] = get(previous === nothing ? Dict() : previous,"notify_pending",false) ||
            (previous !== nothing && previous["status"] in BonitoWorker.PROCESS_ACTIVE &&
             !(record["status"] in BonitoWorker.PROCESS_ACTIVE))
        book.jobs[key] = record
        epoch = String(get(d,"epoch",""))
        epoch == book.epoch || epoch in book.retired || push!(book.retired,epoch)
        while length(book.jobs) > 256
            ended = sort!([k for (k,j) in book.jobs if !(j["status"] in BonitoWorker.PROCESS_ACTIVE)];
                by=k -> book.jobs[k]["started"])
            isempty(ended) && break
            delete!(book.jobs,first(ended))
            delete!(book.tasks,first(ended))
        end
        changed_state = previous === nothing || previous["status"] != record["status"]
        (changed_state || time()-book.last_saved > 5) && save_process_book!(book)
        asked(r) = r === nothing ? nothing : get(r,"prompt",nothing)
        (get(d,"epoch","") in book.retired && d["status"] in BonitoWorker.PROCESS_ACTIVE && d["status"] != "killing",
         asked(previous) != asked(record) || (changed_state && asked(record) !== nothing))
    end
    chat = lock(() -> get(root_state(state).chat_models,pid,nothing),state.lock)
    chat === nothing || attach_process_tasks!(chat)
    chat === nothing || refresh_job_cards!(chat, String(d["id"]))
    chat !== nothing && prompt_changed && chat_emit(chat, prompts_event(chat))
    if chat !== nothing
        key = managed_task_id(worker,String(d["id"]))
        lock(() -> get(book.jobs[key],"notify_pending",false), book.lock) &&
            note_background!(chat, JobEndingNote(root_state(state), pid, key))
    end
    if retired
        Base.errormonitor(@async close_process_epoch!(state,pid,worker,String(d["epoch"])))
    end
    return nothing
end

# A job's ending, for the agent's next note, unless the agent learns it first from
# a call of its own (`saw_ending!`): a wait that the ending released, a status.
# Said anyway, the note only repeated what the agent knew, and started a turn to
# do it, long after the wait (2026-11-12).
struct JobEndingNote
    state::ServerState
    project_id::String
    key::String
end

function note_line(n::JobEndingNote)
    book = process_book(n.state, n.project_id)
    return lock(book.lock) do
        record = get(book.jobs, n.key, nothing)
        (record === nothing || !get(record, "notify_pending", false)) && return nothing
        record["notify_pending"] = false
        save_process_book!(book)
        "Managed process $(record["id"]) ($(record["label"])) $(record["status"]), " *
            "exit=$(record["exitcode"]). Use bt_process status/output to inspect its result."
    end
end

# The agent got back how jobs ended, in the result of a call of its own.
function saw_ending!(book::ProcessBook, worker::AbstractString, result::AbstractDict)
    jobs = haskey(result, "jobs") ? result["jobs"] : (result,)
    lock(book.lock) do
        seen = false
        for j in jobs
            j["status"] in BonitoWorker.PROCESS_ACTIVE && continue
            record = get(book.jobs, managed_task_id(worker, String(j["id"])), nothing)
            (record === nothing || !get(record, "notify_pending", false)) && continue
            record["notify_pending"] = false
            seen = true
        end
        seen && save_process_book!(book)
    end
    return nothing
end

# What an agent asks for, from its MCP process. Answering a password prompt is not
# among it: only the user does that, in the chat (`answer_prompt!`).
function process_request(state,pid,args)
    action = String(get(args,"action",""))
    action == "answer" && error("only the user answers a password prompt, in the chat")
    state = root_state(state)
    p = get(state.projects[],String(pid),nothing)
    p === nothing && error("this chat no longer exists")
    w = get(state.workers[],p.worker_id,nothing)
    w !== nothing && can(w,"managed_process") || error("update this worker to use managed processes")
    if action == "observe"
        # Worker snapshots already stream on the control channel. A voluntary
        # wait observes them without blocking on a fresh RPC to a sleeping or
        # disconnected worker, so incoming input can release the wait promptly.
        book = process_book(state,pid)
        snapshot = lock(book.lock) do
            d = get(book.jobs,managed_task_id(p.worker_id,String(get(args,"id",""))),nothing)
            d === nothing && error("no managed process with that id in this chat")
            merge(copy(d),Dict("connected"=>isopen(w)))
        end
        saw_ending!(book,p.worker_id,snapshot)
        return public_process_result(w,snapshot)
    end
    request = Dict{String,Any}(String(k)=>v for (k,v) in args if k in
        ("action","id","argv","cwd","label","env","offset","max_bytes","epoch","destination","options","ssh"))
    if action in ("start","sudo","ssh")
        book = process_book(state,pid)
        lock(book.lock) do
            get(request,"epoch","") == book.epoch || error("agent session ended; use the current session to start work")
        end
        request["cwd"] = get(request,"cwd",p.worker_path)
    end
    if action in ("sudo","ssh")
        can(w,"password_prompts") || error("update this worker to run sudo and ssh with a password from the chat")
        delete!(request,"env")
    end
    request["project_id"] = String(pid) # bound by the authenticated channel, never caller-supplied
    response = worker_rpc(state,p.worker_id,"managed_process",request;timeout=20.0)
    result = response["result"]
    if result isa AbstractDict && haskey(result,"id") && get(request,"action","") != "output"
        managed_process_update!(state,p.worker_id,result)
    end
    result isa AbstractDict && (haskey(result,"id") || haskey(result,"jobs")) &&
        saw_ending!(process_book(state,pid),p.worker_id,result)
    return public_process_result(w,result)
end

function public_process_result(worker,result)
    if haskey(result,"jobs")
        return Dict("jobs"=>[public_process_result(worker,d) for d in result["jobs"]])
    end
    visible = Dict{String,Any}(String(k)=>v for (k,v) in result if !(k in
        ("epoch","revision","os_started","recorded_at","project_id")))
    visible["worker"] = worker.name
    visible["worker_id"] = worker.worker_id
    return visible
end

dev_op(state::ServerState, ::Val{:managed_process}, args::AbstractDict, caller::String) =
    process_request(state,caller,args)

function close_process_epoch!(state,pid,worker,epoch)
    w = get(state.workers[],worker,nothing)
    (w === nothing || !isopen(w) || !can(w,"managed_process")) && return nothing
    try
        worker_rpc(state,worker,"managed_process",
            Dict("action"=>"close_chat","project_id"=>pid,"epoch"=>epoch);timeout=20.0)
    catch e
        e isa InterruptException && rethrow()
        # The retired epoch is durable. A worker reconnect's snapshots retry
        # cleanup; neither a failed RPC nor an offline worker means "exited".
        @error "managed process cleanup pending" project_id=pid worker exception=(e,catch_backtrace())
    end
    return nothing
end

function close_managed_processes!(state,pid)
    state = root_state(state)
    book = process_book(state,pid)
    targets = lock(book.lock) do
        epochs = Set([book.epoch; [String(d["epoch"]) for d in values(book.jobs)
            if d["status"] in BonitoWorker.PROCESS_ACTIVE]])
        for epoch in epochs
            epoch in book.retired || push!(book.retired,epoch)
        end
        book.epoch = string(uuid4())
        save_process_book!(book)
        workers = Set(String(d["worker"]) for d in values(book.jobs))
        p = get(state.projects[],pid,nothing)
        p === nothing || push!(workers,p.worker_id)
        [(worker,epoch) for worker in workers for epoch in epochs]
    end
    foreach(target -> Base.errormonitor(@async close_process_epoch!(state,pid,target...)),targets)
    return nothing
end

function managed_process_control!(model,id)
    action,worker,job = if startswith(id,"managed-control:")
        d = JSON.parse(id[length("managed-control:")+1:end])
        (String(d["action"]),String(d["worker"]),String(d["id"]))
    elseif startswith(id,"managed:")
        _,worker,job = split(id,':';limit=3)
        ("interrupt",String(worker),String(job))
    else
        return false
    end
    action in ("interrupt","terminate","kill") || error("unknown managed process control")
    Base.errormonitor(@async try
        p = model.state.projects[][model.project_id]
        p.worker_id == worker || error("job is on another worker")
        process_request(model.state,model.project_id,Dict("action"=>action,"id"=>job))
    catch e
        e isa InterruptException && rethrow()
        book = process_book(model.state,model.project_id)
        lock(book.lock) do
            d = get(book.jobs,managed_task_id(worker,job),nothing)
            d === nothing || (d["control_error"] = sprint(showerror,e))
        end
        attach_process_tasks!(model)
        @error "managed process control failed" action job exception=(e,catch_backtrace())
    end)
    return true
end

function taskbar_extra_controls(session,bar,t::ManagedProcessTask)
    controls = map(("terminate"=>"Terminate", "kill"=>"Force kill")) do (action,label)
        payload = "managed-control:" * JSON.json(Dict("action"=>action,"worker"=>t.worker,"id"=>t.snapshot["id"]))
        DOM.button(label;class="bw-menu-item" * (action=="kill" ? " bw-menu-danger" : ""),
            onclick=js"event => { event.preventDefault(); event.stopPropagation(); $(bar.stop_request).notify($payload); }")
    end
    return (Menu(controls;title="Process controls"),)
end

const PROCESS_TASK_STYLES = Styles(
    CSS(".bt-taskbar-slot.bt-process-task", "display"=>"block", "width"=>"100%", "max-width"=>"100%", "min-width"=>"0", "box-sizing"=>"border-box", "border-radius"=>"var(--bw-radius)"),
    CSS(".bt-process-task summary", "display"=>"flex", "min-width"=>"0", "align-items"=>"center", "gap"=>"var(--bw-space-2)", "cursor"=>"pointer"),
    CSS(".bt-process-output", "max-height"=>"180px", "overflow"=>"auto", "white-space"=>"pre-wrap", "overflow-wrap"=>"anywhere", "font-size"=>"var(--bw-font-size-xs)", "margin"=>"var(--bw-space-2) 0 0"),
    CSS(".bt-process-meta", "font-size"=>"var(--bw-font-size-xs)", "white-space"=>"pre-wrap", "overflow-wrap"=>"anywhere", "color"=>"var(--bw-text-muted)"))

function taskbar_slot(session,bar,item,head,t::ManagedProcessTask)
    d = t.snapshot
    w = get(t.chat.state.workers[],t.worker,nothing)
    worker = w === nothing ? t.worker : w.name
    meta = "$worker · pid $(d["pid"]) · $(d["cwd"])\n" * join(repr.(d["argv"])," ")
    node = DOM.details(DOM.summary(head), DOM.div(meta;class="bt-process-meta"),
        DOM.pre(get(d,"output","");class="bt-process-output"),PROCESS_TASK_STYLES;
        class="bt-taskbar-slot bt-process-task",dataTaskId=item.id,dataMsgIndex="-1",
        dataProcessId=d["id"],dataProcessStatus=d["status"],title=meta)
    Bonito.onload(session,node,js"""node => {
        const bar = node.closest('.bt-taskbar');
        if (!bar) return;
        const open = bar.__btProcessOpen || (bar.__btProcessOpen = new Set());
        node.open = open.has(node.dataset.taskId);
        node.addEventListener('toggle', () => {
            if (node.open) open.add(node.dataset.taskId); else open.delete(node.dataset.taskId);
        });
    }""")
    return node
end

# ── Password prompts ─────────────────────────────────────────────────────────
# A sudo or ssh job that waits for a password has the question in its record
# (BonitoWorker password_prompts.jl). The chat shows one card per open question,
# built from the job book: every change sends the whole list, and so does a tab's
# init, so a reload or a reconnect shows exactly the open questions.

prompt_key(worker,id,seq) = string(managed_task_id(worker,id), '#', seq)

function prompt_card(state,record)
    p = record["prompt"]
    w = get(state.workers[],record["worker"],nothing)
    # The command as the worker runs it: for ssh with every option the agent passed.
    return Dict{String,Any}("key"=>prompt_key(record["worker"],record["id"],p["seq"]),
        "kind"=>p["kind"], "text"=>p["text"], "job"=>command_line(record["argv"]),
        "worker"=>w === nothing ? record["worker"] : w.name, "cwd"=>record["cwd"],
        "host"=>String(get(record,"host","")))   # sudo through a bt_ssh connection
end

# A chat's open questions: its jobs' passwords, and the app loads waiting for a
# person (plugins.jl). Each kind answers on its own path.
prompt_cards(chat::ChatModel) = prompt_cards(chat.state,chat.project_id)
prompt_cards(state,pid::AbstractString) = vcat(process_prompt_cards(state,pid), app_load_cards(state,pid))

# Only a book already in memory: a job with an open question is in one, because the
# worker reports its jobs on every connect. A chat that never ran one gets no file.
function process_prompt_cards(state,pid::AbstractString)
    state = root_state(state)
    book = lock(() -> get(state.process_jobs,pid,nothing),state.lock)
    book === nothing && return Dict{String,Any}[]
    records = lock(book.lock) do
        [copy(d) for d in values(book.jobs)
         if get(d,"prompt",nothing) !== nothing && d["status"] in BonitoWorker.PROCESS_ACTIVE]
    end
    sort!(records; by = d -> d["started"])
    return [prompt_card(state,d) for d in records]
end

prompts_event(chat::ChatModel) = Dict{String,Any}("type"=>"prompts", "prompts"=>prompt_cards(chat))

"Send a chat's open questions to its tabs, when the chat is open on the server."
function show_prompts!(state, pid::AbstractString)
    root = root_state(state)
    chat = lock(() -> get(root.chat_models, pid, nothing), root.lock)
    chat === nothing || chat_emit(chat, prompts_event(chat))
    return nothing
end

"""
    answer_prompt!(view, key, secret)

Answer the open question `key` names with `secret`, or refuse it (`nothing`). The
answer goes to the worker, which writes it into sudo or ssh. Nothing keeps it.
A failure goes back to the tab that answered, on its card.
"""
function answer_prompt!(view::ChatModel, key::AbstractString, secret::Union{String,Nothing})
    m = match(r"^managed:(.+):([A-Za-z0-9_-]+)#(\d+)$", key)
    m === nothing && return nothing
    worker, id, seq = String(m.captures[1]), String(m.captures[2]), parse(Int, m.captures[3])
    state = root_state(view.state)
    Base.errormonitor(@async try
        p = state.projects[][view.project_id]
        p.worker_id == worker || error("that job runs on another worker")
        request = Dict{String,Any}("action"=>"answer", "project_id"=>String(view.project_id),
            "id"=>id, "seq"=>seq)
        secret === nothing ? (request["deny"] = true) : (request["secret"] = secret)
        response = worker_rpc(state,worker,"managed_process",request;timeout=20.0)
        managed_process_update!(state,worker,response["result"])
    catch e
        e isa InterruptException && rethrow()
        reply!(view, Dict{String,Any}("type"=>"prompt_error", "key"=>String(key), "error"=>sprint(showerror,e)))
    end)
    return nothing
end

function handle_command!(model::ChatModel, ::Any, cmd::PromptAnswerCommand)
    startswith(cmd.key, "app_load:") || return answer_prompt!(model, cmd.key, cmd.secret)
    # An app load waiting for a person (plugins.jl). `viewer` is the state of the
    # tab that clicked, so it knows whose click this is.
    try
        answer_app_load!(model.viewer, model.project_id, cmd.key, cmd.secret !== nothing)
    catch e
        e isa ErrorException || rethrow()
        reply!(model, Dict{String,Any}("type" => "prompt_error", "key" => cmd.key, "error" => e.msg))
    end
    return nothing
end

# ── The `bt_process` card ────────────────────────────────────────────────────
# The card says what a call did in its title and summary; opening it shows the
# job's details and output. The title comes from the call's arguments and the
# summary from its result, so they stay right whatever the agent labels the tool.

ProcessJob(d::AbstractDict) = ProcessJob(String(d["id"]), String(d["label"]), String(d["status"]),
    String[String(a) for a in d["argv"]], String(d["cwd"]), String(d["worker"]), Int(d["pid"]),
    d["exitcode"], d["signal"], Float64(d["started"]), d["finished"], String(d["error"]),
    String(get(d, "control_error", "")), String(d["output"]), Int(d["output_bytes"]),
    String(get(d, "wait_reason", "")))

# Exact decode of a result. The text can legitimately be something else: an error
# message, or JSON an agent cut short because it was too long. Those are not jobs,
# so they return nothing and the card shows the text as it is.
function process_reply(content)
    text = reply_text(content)
    JSON.isvalidjson(text) || return nothing
    d = JSON.parse(text)
    d isa AbstractDict || return nothing
    if haskey(d, "jobs")
        jobs = ProcessJob[ProcessJob(j) for j in d["jobs"]]
        return ProcessJobList(sort!(jobs; by = j -> j.started, rev = true))
    end
    fields = ("id", "label", "status", "argv", "cwd", "worker", "pid", "exitcode", "signal",
              "started", "finished", "error", "output", "output_bytes")
    return all(k -> haskey(d, k), fields) ? ProcessJob(d) : nothing
end

reply_failed(job::ProcessJob) = job.status in ("failed", "lost")
reply_failed(::ProcessJobList) = false

command_line(argv) = join(Base.shell_escape.(argv), ' ')

function process_duration(seconds::Real)
    seconds < 60 && return string(round(seconds; digits = 1), " s")
    minutes = floor(Int, seconds / 60)
    rest = round(Int, seconds - 60 * minutes)
    minutes < 60 && return rest == 0 ? string(minutes, " min") : string(minutes, " min ", rest, " s")
    return string(minutes ÷ 60, " h ", minutes % 60, " min")
end

# "succeeded", "failed · exit 3", "killed · signal 9". A clean exit needs no number.
function job_state(job::ProcessJob)
    parts = [job.status]
    something(job.exitcode, 0) == 0 || push!(parts, "exit $(job.exitcode)")
    something(job.signal, 0) == 0 || push!(parts, "signal $(job.signal)")
    return join(parts, " · ")
end

reply_summary(list::ProcessJobList) = string(length(list.jobs), length(list.jobs) == 1 ? " command" : " commands",
    " · ", count(j -> j.status in BonitoWorker.PROCESS_ACTIVE, list.jobs), " running")
function reply_summary(job::ProcessJob)
    parts = [job_state(job)]
    job.wait_reason == "timeout" && push!(parts, "wait timed out")
    job.wait_reason == "ready" && push!(parts, "connected")
    job.wait_reason == "message" && push!(parts, "woken by a message")
    job.finished === nothing || push!(parts, process_duration(job.finished - job.started))
    return join(parts, " · ")
end

function process_summary(m::ProcessToolMsg, content)
    m.reply === nothing || return reply_summary(m.reply)
    if isempty(content)
        return m.seconds === nothing ? "" : "up to " * process_duration(m.seconds)
    end
    tool_status(m) == "failed" && return String(first(split(reply_text(content), '\n')))
    return content_summary_default(content)
end

# A call that names only an id has no result to show until it returns, and a wait
# can block for minutes. The chat's book already knows the job: its label for the
# title, and the job itself for the body while the call runs.
function book_record(m::ProcessToolMsg)
    chat = tool_chat(m)
    (chat === nothing || isempty(m.job_id)) && return nothing
    state = root_state(chat.state)
    project = get(state.projects[], chat.project_id, nothing)
    book = lock(() -> get(state.process_jobs, chat.project_id, nothing), state.lock)
    (project === nothing || book === nothing) && return nothing
    key = managed_task_id(project.worker_id, m.job_id)
    return lock(book.lock) do
        record = get(book.jobs, key, nothing)
        record === nothing ? nothing : copy(record)
    end
end

known_job_label(m::ProcessToolMsg) = (r = book_record(m); r === nothing ? "" : String(r["label"]))

# The job as the book has it now, named by its worker's name as a result names it.
function book_job(m::ProcessToolMsg)
    record = book_record(m)
    record === nothing && return nothing
    w = get(root_state(tool_chat(m).state).workers[], String(record["worker"]), nothing)
    w === nothing || (record["worker"] = w.name)
    return ProcessJob(record)
end

renders_from_input(m::ProcessToolMsg) = book_record(m) !== nothing
# The body is the job until the result arrives, then the result: redraw it then.
tool_body_snapshot(::ProcessToolMsg, content) = isempty(content)

# Each update of a job redraws the open cards of the calls still running on it.
function refresh_job_cards!(chat::ChatModel, job_id::AbstractString)
    s = shared(chat)
    ids = lock(s.lock) do
        [tool_id(m) for m in s.msgs_store if m isa ProcessToolMsg && m.job_id == job_id &&
             !(tool_status(m) in ("completed", "failed"))]
    end
    for id in ids
        chat_emit(chat, Dict{String,Any}("type" => "tool_update", "id" => id, "refresh_body" => true))
    end
    return nothing
end

# A job's name for a person: its label; else its command (without a label the
# worker labels a job with its id, which says less).
function job_name(label::AbstractString, id::AbstractString, argv)
    !isempty(label) && label != id && return String(label)
    return isempty(argv) ? String(id) : command_line(argv)
end
job_name(job::ProcessJob) = job_name(job.label, job.id, job.argv)
job_name(m::ProcessToolMsg) =
    job_name(isempty(m.label) ? known_job_label(m) : m.label, m.job_id, m.argv)

function process_title(m::ProcessToolMsg; max_length::Int = 120)
    m.action == "list" && return "List background commands"
    verbs = (start = "Start", wait = "Wait for", status = "Check", output = "Read output of",
             interrupt = "Interrupt", terminate = "Terminate", kill = "Force kill",
             sudo = "Run as root:", ssh = "Open")
    title = one_line_title(string(get(verbs, Symbol(m.action), m.action), " ", job_name(m)))
    # A command can be a whole script. The body shows all of it.
    return length(title) <= max_length ? title : first(title, max_length - 1) * "…"
end

# The result fills in what the call did not name, and a job that failed fails the
# card: the call worked, but the green pill is read as "the command worked".
function adopt_reply!(m::ProcessToolMsg, content)
    m.reply = process_reply(content)
    if m.reply isa ProcessJob
        m.label = m.reply.label
        m.argv = m.reply.argv
        m.job_id = m.reply.id
    end
    m.reply !== nothing && reply_failed(m.reply) && (m.message.status = "failed")
    return nothing
end

snap_title(b::ProcessToolMsg, ::AbstractString) = isempty(b.action) ? tool_title(b) : process_title(b)
snap_summary(b::ProcessToolMsg, snap) = process_summary(b, snap.content)

function update_from_snap!(b::ProcessToolMsg, snap)
    apply_input!(b, snap.raw_input)
    tool_status(b) in ("completed", "failed") && adopt_reply!(b, snap.content)
    return nothing
end

# Rebuilt from chat.md, the card has its persisted title and summary; a chat written
# before this card has only "bt_process" and a byte count there. Both are redone
# from the call and the result stored beside the chat.
function restore_call!(m::ProcessToolMsg, chat_dir::AbstractString)
    (isempty(chat_dir) || m.reply !== nothing || !(tool_status(m) in ("completed", "failed"))) &&
        return nothing
    raw = stored_raw_input(chat_dir, tool_id(m))
    raw === nothing || apply_input!(m, raw)
    content = tool_content_for_render(m, chat_dir)
    isempty(content) && return nothing
    adopt_reply!(m, content)
    isempty(m.action) || (m.message.title = process_title(m))
    m.message.summary = process_summary(m, content)
    return nothing
end

const PROCESS_CARD_STYLES = Styles(
    CSS(".bt-process-card", "display"=>"flex", "flex-direction"=>"column", "min-width"=>"0",
        "gap"=>"var(--bw-space-2)", "padding-top"=>"var(--bw-space-2)"),
    CSS(".bt-process-facts", "display"=>"grid", "grid-template-columns"=>"max-content minmax(0, 1fr)",
        "gap"=>"var(--bw-space-1) var(--bw-space-3)", "margin"=>"0", "font-size"=>"var(--bw-font-size-sm)"),
    CSS(".bt-process-job-name", "font-size"=>"var(--bw-font-size-sm)", "overflow-wrap"=>"anywhere"),
    CSS(".bt-process-fact", "display"=>"contents"),
    CSS(".bt-process-facts dt", "color"=>"var(--bw-text-muted)"),
    CSS(".bt-process-facts dd", "margin"=>"0", "min-width"=>"0", "overflow-wrap"=>"anywhere"),
    CSS(".bt-process-facts code", "font-family"=>"ui-monospace, monospace", "white-space"=>"pre-wrap"))

function process_facts(job::ProcessJob)
    facts = Pair{String,Any}["Status" => job_state(job)]
    isempty(job.wait_reason) || push!(facts, "Wait ended" => job.wait_reason)
    isempty(job.error) || push!(facts, "Error" => job.error)
    isempty(job.control_error) || push!(facts, "Stop failed" => job.control_error)
    push!(facts, "Command" => DOM.code(command_line(job.argv)), "Folder" => DOM.code(job.cwd),
        "Worker" => job.worker, "Job id" => DOM.code(job.id), "Process id" => string(job.pid),
        "Started" => Dates.format(Dates.unix2datetime(job.started), "yyyy-mm-dd HH:MM:SS") * " UTC")
    job.finished === nothing || push!(facts, "Ran for" => process_duration(job.finished - job.started))
    return facts
end

function Bonito.jsrender(session::Session, job::ProcessJob)
    facts = DOM.dl(Any[DOM.div(DOM.dt(name), DOM.dd(value); class = "bt-process-fact")
                       for (name, value) in process_facts(job)]; class = "bt-process-facts")
    parts = Any[PROCESS_CARD_STYLES, facts]
    if !isempty(job.output)
        kept = sizeof(job.output)
        push!(parts, tool_subsection("Output", console_block(job.output);
            preview = kept < job.output_bytes ? "last $(kept) of $(job.output_bytes) bytes" : "",
            summary_lines = 10, pin_end = true, console = true))
    end
    return Bonito.jsrender(session, DOM.div(parts; class = "bt-process-card"))
end

function Bonito.jsrender(session::Session, list::ProcessJobList)
    isempty(list.jobs) && return Bonito.jsrender(session,
        DOM.div("No background commands in this chat."; class = "bt-tool-empty"))
    # A node, because a section's text label is set in capitals: a command's case matters.
    rows = Any[tool_subsection(DOM.span(job_name(job); class = "bt-process-job-name"), job;
                           preview = job_state(job), state = :collapsed,
                           summary_lines = 16, full_lines = 40) for job in list.jobs]
    return Bonito.jsrender(session, DOM.div(PROCESS_CARD_STYLES, rows; class = "bt-process-card"))
end

# Anything that is not a job goes out as it came: never through markdown.
function render_tool_content(state::ServerState, m::ProcessToolMsg, content, project_id::AbstractString)
    # No result yet: the job as it is now (`renders_from_input`).
    isempty(content) && return something(book_job(m), DOM.div("(loading…)"; class = "bt-tool-empty bt-tool-loading"))
    reply = process_reply(content)
    reply === nothing || return reply
    text = reply_text(content)
    isempty(text) && return render_tool_parts(state, m, content, project_id)
    return CodeView(text; language = "plaintext")
end
