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
    retired = lock(book.lock) do
        key = managed_task_id(worker,String(d["id"]))
        previous = get(book.jobs,key,nothing)
        previous !== nothing && (d["revision"],d["output_bytes"]) <
            (previous["revision"],previous["output_bytes"]) && return false
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
        get(d,"epoch","") in book.retired && d["status"] in BonitoWorker.PROCESS_ACTIVE && d["status"] != "killing"
    end
    chat = lock(() -> get(root_state(state).chat_models,pid,nothing),state.lock)
    chat === nothing || attach_process_tasks!(chat)
    if chat !== nothing
        notification = lock(book.lock) do
            record = book.jobs[managed_task_id(worker,String(d["id"]))]
            get(record,"notify_pending",false) || return nothing
            record["notify_pending"] = false
            save_process_book!(book)
            "Managed process $(record["id"]) ($(record["label"])) $(record["status"]), " *
                "exit=$(record["exitcode"]). Use bt_process status/output to inspect its result."
        end
        notification === nothing || note_background!(chat,notification)
    end
    if retired
        Base.errormonitor(@async close_process_epoch!(state,pid,worker,String(d["epoch"])))
    end
    return nothing
end

function process_request(state,pid,args)
    state = root_state(state)
    p = get(state.projects[],String(pid),nothing)
    p === nothing && error("this chat no longer exists")
    w = get(state.workers[],p.worker_id,nothing)
    w !== nothing && can(w,"managed_process") || error("update this worker to use managed processes")
    if get(args,"action","") == "observe"
        # Worker snapshots already stream on the control channel. A voluntary
        # wait observes them without blocking on a fresh RPC to a sleeping or
        # disconnected worker, so incoming input can release the wait promptly.
        book = process_book(state,pid)
        snapshot = lock(book.lock) do
            d = get(book.jobs,managed_task_id(p.worker_id,String(get(args,"id",""))),nothing)
            d === nothing && error("no managed process with that id in this chat")
            merge(copy(d),Dict("connected"=>isopen(w)))
        end
        return public_process_result(w,snapshot)
    end
    request = Dict{String,Any}(String(k)=>v for (k,v) in args if k in
        ("action","id","argv","cwd","label","env","offset","max_bytes","epoch"))
    if get(request,"action","") == "start"
        book = process_book(state,pid)
        lock(book.lock) do
            get(request,"epoch","") == book.epoch || error("agent session ended; use the current session to start work")
        end
        request["cwd"] = get(request,"cwd",p.worker_path)
    end
    request["project_id"] = String(pid) # bound by the authenticated channel, never caller-supplied
    response = worker_rpc(state,p.worker_id,"managed_process",request;timeout=20.0)
    result = response["result"]
    if result isa AbstractDict && haskey(result,"id") && get(request,"action","") != "output"
        managed_process_update!(state,p.worker_id,result)
    end
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
        DOM.button(label;class="bt-menu-item" * (action=="kill" ? " bt-menu-danger" : ""),
            onclick=js"event => { event.preventDefault(); event.stopPropagation(); $(bar.stop_request).notify($payload); }")
    end
    return (action_menu(controls...;title="Process controls"),)
end

const PROCESS_TASK_STYLES = Styles(
    CSS(".bt-taskbar-slot.bt-process-task", "display"=>"block", "width"=>"100%", "max-width"=>"100%", "min-width"=>"0", "box-sizing"=>"border-box", "border-radius"=>"var(--bt-radius)"),
    CSS(".bt-process-task summary", "display"=>"flex", "min-width"=>"0", "align-items"=>"center", "gap"=>"var(--bt-space-2)", "cursor"=>"pointer"),
    CSS(".bt-process-output", "max-height"=>"180px", "overflow"=>"auto", "white-space"=>"pre-wrap", "overflow-wrap"=>"anywhere", "font-size"=>"11px", "margin"=>"var(--bt-space-2) 0 0"),
    CSS(".bt-process-meta", "font-size"=>"11px", "white-space"=>"pre-wrap", "overflow-wrap"=>"anywhere", "color"=>"var(--bt-text-muted)"))

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
