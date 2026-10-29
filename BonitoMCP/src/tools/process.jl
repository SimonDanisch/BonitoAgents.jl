function process_handler(args::AbstractDict)
    action = String(get(args,"action","list"))
    request = Dict{String,Any}(String(k)=>v for (k,v) in args if !startswith(String(k),"_"))
    request["epoch"] = get(ENV,"BONITOAGENTS_PROCESS_EPOCH","")
    if action == "start"
        request["env"] = merge(Dict("PATH"=>get(ENV,"PATH","")),
            BonitoProgress.progress_context(), get(args,"env",Dict{String,String}()),
            Dict("BONITOAGENTS_PROCESS_ID"=>String(get(args,"id",""))))
    end
    action == "wait" || return dev_call("managed_process"; (Symbol(k)=>v for (k,v) in request)...)
    secs = get(args,"seconds",nothing)
    secs isa Real && isfinite(secs) && 0 < secs <= 3600 ||
        return tool_error("wait requires seconds between 0 and 3600")
    wake = Channel{Nothing}(0)
    lock(() -> push!(SERVER.waits.active,wake),SERVER.waits.lock)
    note_wait_request!(args,wake)
    try
        if call_server("wait_input";tool_id=String(get(args,"_tool_use_id",""))) === true
            close(wake)
        end
        deadline = time()+secs
        request["action"] = "observe"
        while true
            status = call_server("managed_process"; (Symbol(k)=>v for (k,v) in request)...)
            if !(status["status"] in ("starting","running","interrupting","terminating","killing"))
                return dev_result(merge(status,Dict("wait_reason"=>"exited")))
            end
            !isopen(wake) && return dev_result(merge(status,Dict("wait_reason"=>"message")))
            time() >= deadline && return dev_result(merge(status,Dict("wait_reason"=>"timeout")))
            wait_sleep(wake,min(1.0,max(0.0,deadline-time())))
        end
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror,e))
    finally
        lock(() -> delete!(SERVER.waits.active,wake),SERVER.waits.lock)
        isopen(wake) && close(wake)
    end
end

register!("bt_process", """
Launch and control worker-owned background commands, with output and taskbar
integration, independently of the agent provider. Use this for renderers,
builds, Python, Node, encoders and other long commands, instead of &, nohup,
detached shell spawning or provider-specific background tools.

action=start requires a stable id for this attempt and argv (an argument array,
not shell syntax); cwd defaults to the chat's worker directory. Example:
{action:"start", id:"encode-1", argv:["ffmpeg","-i","input.mov","out.mp4"],
 label:"Encode video"}. Shell syntax requires explicitly invoking a shell.
An id is idempotent: repeating start returns its original job; use a NEW id
for a retry. env overrides are optional and are not returned in job records.

list shows this chat's jobs. status reports actual lifecycle, pid, exit code and
a bounded output tail. output supports a byte offset cursor and max_bytes
(up to 65536); next_offset is the next cursor, output_truncated flags dropped
old output. Logs retain a bounded rolling window. wait requires id and seconds
(at most 3600); it returns on exit, timeout or incoming user/agent messages,
without stopping the job. Read incoming messages before continuing.

interrupt sends SIGINT to the process group; terminate sends SIGTERM; kill is
forced termination. These requests keep the taskbar entry until exit is
confirmed. If graceful interruption fails, inspect status and explicitly use
terminate/kill. On Windows interrupt is unavailable; use terminate or kill.
Agent turns and MCP reconnects do not end jobs. Closing or restarting the chat
requests cleanup; a worker restart stops leftover jobs and reports them lost.
For ordinary Julia work use bt_julia_eval(background=true) and its run controls.
bt_progress reports measured work and does not itself supervise processes.
""",Dict{String,Any}("type"=>"object","properties"=>Dict{String,Any}(
    "action"=>Dict("type"=>"string","enum"=>["start","list","status","output","wait","interrupt","terminate","kill"]),
    "id"=>Dict("type"=>"string","description"=>"Stable unique id per job attempt, using letters, digits, - or _. Required except list."),
    "argv"=>Dict("type"=>"array","items"=>Dict("type"=>"string")),
    "cwd"=>Dict("type"=>"string"),"label"=>Dict("type"=>"string"),
    "env"=>Dict("type"=>"object","additionalProperties"=>Dict("type"=>"string")),
    "seconds"=>Dict("type"=>"number","exclusiveMinimum"=>0,"maximum"=>3600),
    "offset"=>Dict("type"=>"integer","minimum"=>0),
    "max_bytes"=>Dict("type"=>"integer","minimum"=>1,"maximum"=>65536)),"required"=>["action"]),
    process_handler;available=()->!isempty(get(ENV,"BONITOAGENTS_PROCESS_EPOCH","")))
