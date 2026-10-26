function progress_handler(args::AbstractDict)
    isempty(get(ENV,"BONITOAGENTS_PROGRESS_ADDR","")) && return tool_error("No worker progress relay is connected")
    action = String(get(args,"action","update"))
    action in ("context","start","update","finish","fail","cancel") || return tool_error("Unknown progress action: $action")
    if action == "context"
        context = BonitoProgress.progress_context()
        isempty(context["BONITOAGENTS_PROGRESS_ADDR"]) && return tool_error("No worker progress relay is connected")
        return dev_result(Dict("env"=>context, "julia_client"=>joinpath(pkgdir(@__MODULE__),"src","BonitoProgress.jl")))
    end
    id = String(get(args,"id",""))
    isempty(id) && return tool_error("A stable job id is required")
    try
        job = lock(SERVER.progress_lock) do
            job = get(SERVER.progress_jobs,id,nothing)
            job === nothing && action != "start" && throw(ArgumentError("No job handle for '$id'; use action=start to begin a job"))
            if action == "start"
                if length(SERVER.progress_jobs) >= 64
                    for (key,old) in collect(SERVER.progress_jobs)
                        old.snapshot["status"] in BonitoProgress.ACTIVE && continue
                        close(old); delete!(SERVER.progress_jobs,key)
                    end
                end
                length(SERVER.progress_jobs) < 64 || error("Too many active progress jobs")
                old = get(SERVER.progress_jobs,id,nothing)
                job = BonitoProgress.progress(String(get(args,"label",id)); id,
                    total=get(args,"total",nothing), completed=get(args,"completed",0),
                    parent=String(get(args,"parent","")), unit=String(get(args,"unit","")),
                    primary=get(args,"primary",true), detail=String(get(args,"detail","")))
                old === nothing || close(old)
                SERVER.progress_jobs[id] = job
            end
            job
        end
        if action == "finish"
            BonitoProgress.finish!(job; detail=get(args,"detail",nothing))
        elseif action == "fail"
            BonitoProgress.fail!(job,String(get(args,"detail","Job failed")))
        elseif action == "cancel"
            BonitoProgress.cancel!(job; detail=String(get(args,"detail","Cancelled")))
        elseif action == "update"
            BonitoProgress.update!(job,get(args,"completed",job.snapshot["completed"]);
                total=get(args,"total",job.snapshot["total"]), label=get(args,"label",nothing),
                detail=get(args,"detail",nothing), status=String(get(args,"status","running")))
        elseif action != "start"
            throw(ArgumentError("Unknown progress action: $action"))
        end
        return dev_result(Dict("id"=>id,"status"=>job.snapshot["status"],"update_queued"=>true))
    catch e
        (e isa ArgumentError || e isa ErrorException) || rethrow()
        return tool_error(sprint(showerror,e))
    end
end
register!("bt_progress", """
Report measurable job progress in this chat and its sidebar icon, without sending
conversation messages. Use a stable id per job. action=start begins a new job;
update publishes actual completed/total work; finish/fail/cancel ends it.
Unknown totals show indeterminate progress. Progress is independent of agent busy
state. Never estimate percentages from tokens or merely starting a tool.
For running Julia code, use BonitoProgress.progress/update!/finish!/fail! instead
of repeated tool calls; ProgressLogging events in bt_julia_eval are forwarded
automatically. action=context returns the stdlib-only Julia client path and a
progress-only local worker context for detached programs. Other languages can
call this MCP tool with the same fields. Call bt_help for the workflow and a
Julia integration example. In bt_julia_eval, BonitoProgress is already available;
no using/import or new project dependency is needed.
""", Dict{String,Any}("type"=>"object", "properties"=>Dict{String,Any}(
    "action"=>Dict("type"=>"string","enum"=>["start","update","finish","fail","cancel","context"]),
    "id"=>Dict("type"=>"string"), "label"=>Dict("type"=>"string"),
    "completed"=>Dict("type"=>"number","minimum"=>0),
    "total"=>Dict("type"=>["number","null"]), "status"=>Dict("type"=>"string","enum"=>["running","paused"]),
    "detail"=>Dict("type"=>"string"), "unit"=>Dict("type"=>"string"),
    "parent"=>Dict("type"=>"string"), "primary"=>Dict("type"=>"boolean"))),progress_handler;
    available=()->!isempty(get(ENV,"BONITOAGENTS_PROGRESS_ADDR","")))
