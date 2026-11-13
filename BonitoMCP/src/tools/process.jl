const ACTIVE_JOB = ("starting","running","interrupting","terminating","killing")

job_ended(d) = d["status"] in ACTIVE_JOB ? nothing : "exited"

# Observe job `request["id"]` until `done` names a reason, `seconds` pass or a
# message for the agent arrives. The job goes on in any case.
function wait_for_job(request::AbstractDict, args::AbstractDict, secs::Real; done = job_ended)
    wake = Channel{Nothing}(0)
    lock(() -> push!(SERVER.waits.active,wake),SERVER.waits.lock)
    note_wait_request!(args,wake)
    try
        if call_server("wait_input";tool_id=String(get(args,"_tool_use_id",""))) === true
            close(wake)
        end
        deadline = time()+secs
        observe = merge(request,Dict{String,Any}("action"=>"observe"))
        while true
            status = call_server("managed_process"; (Symbol(k)=>v for (k,v) in observe)...)
            reason = done(status)
            reason === nothing || return dev_result(merge(status,Dict("wait_reason"=>reason)))
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

valid_seconds(secs) = secs isa Real && isfinite(secs) && 0 < secs <= 3600

job_request(args::AbstractDict) = merge(
    Dict{String,Any}(String(k)=>v for (k,v) in args if !startswith(String(k),"_")),
    Dict{String,Any}("epoch"=>get(ENV,"BONITOAGENTS_PROCESS_EPOCH","")))

names_worker(args::AbstractDict) = !isempty(strip(String(get(args,"worker",""))))

function process_handler(args::AbstractDict)
    action = String(get(args,"action","list"))
    request = job_request(args)
    if action == "start"
        # This process's PATH and progress address are this machine's. Another
        # worker is another machine: its job gets that worker's own environment.
        here = names_worker(args) ? Dict{String,String}() :
            merge(Dict("PATH"=>get(ENV,"PATH","")), BonitoProgress.progress_context())
        request["env"] = merge(here, get(args,"env",Dict{String,String}()),
            Dict("BONITOAGENTS_PROCESS_ID"=>String(get(args,"id",""))))
    end
    action == "wait" || return dev_call("managed_process"; (Symbol(k)=>v for (k,v) in request)...)
    secs = get(args,"seconds",nothing)
    valid_seconds(secs) || return tool_error("wait requires seconds between 0 and 3600")
    return wait_for_job(request,args,secs)
end

# Start a sudo or ssh job, then wait for it as `bt_process` wait would.
function prompting_job_handler(args::AbstractDict, action::AbstractString; done = job_ended)
    secs = get(args,"seconds",300)
    valid_seconds(secs) || return tool_error("seconds must be between 0 and 3600")
    request = job_request(args)
    delete!(request,"seconds")
    request["action"] = action
    try
        call_server("managed_process"; (Symbol(k)=>v for (k,v) in request)...)
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror,e))
    end
    return wait_for_job(request,args,secs; done)
end

sudo_handler(args::AbstractDict) = prompting_job_handler(args,"sudo")
ssh_ready(d) = get(d,"ready",false) === true ? "ready" : job_ended(d)
ssh_handler(args::AbstractDict) = prompting_job_handler(args,"ssh"; done = ssh_ready)

const WORKER_ARG = Dict("type"=>"string","description"=>
    "Another worker of the fleet to run on (its name or id), instead of this chat's. Needs the chat's Remote julia switch.")

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

worker runs the command on another worker of the fleet (its name or id, as for
bt_julia_eval), by default in that worker's home folder. It needs this chat's
Remote julia switch. Later calls on the job need only its id; list shows the
jobs on every worker.
""",Dict{String,Any}("type"=>"object","properties"=>Dict{String,Any}(
    "action"=>Dict("type"=>"string","enum"=>["start","list","status","output","wait","interrupt","terminate","kill"]),
    "id"=>Dict("type"=>"string","description"=>"Stable unique id per job attempt, using letters, digits, - or _. Required except list."),
    "argv"=>Dict("type"=>"array","items"=>Dict("type"=>"string")),
    "cwd"=>Dict("type"=>"string"),"label"=>Dict("type"=>"string"),
    "env"=>Dict("type"=>"object","additionalProperties"=>Dict("type"=>"string")),
    "seconds"=>Dict("type"=>"number","exclusiveMinimum"=>0,"maximum"=>3600),
    "offset"=>Dict("type"=>"integer","minimum"=>0),
    "max_bytes"=>Dict("type"=>"integer","minimum"=>1,"maximum"=>65536),
    "worker"=>WORKER_ARG),"required"=>["action"]),
    process_handler;available=()->!isempty(get(ENV,"BONITOAGENTS_PROCESS_EPOCH","")))

register!("bt_sudo", """
Run a command as root with sudo, when sudo needs the user's password. The chat
shows the user the command and asks for the password; it goes from the chat to
sudo and never to you. Use this for every sudo, here or on a server: running
sudo yourself has no way to ask. Never ask the user for a password in a message.

argv is the command (an argument array, not shell syntax), without "sudo". id is
a stable id for this attempt, as for bt_process; cwd and label are optional.
Example: {id:"install-1", argv:["zypper","--non-interactive","install","ripgrep"],
label:"Install ripgrep"}.

ssh is the id of an open bt_ssh connection of this chat: the command then runs as
root on that host, in the remote user's home directory (cwd is ignored there).
Example: {id:"restart-1", ssh:"server-1", argv:["systemctl","restart","nginx"]}.

worker runs it as root on another worker of the fleet (its name or id), by
default in that worker's home folder; the chat asks for that machine's password.
It needs this chat's Remote julia switch.

The command runs as a bt_process job, in the taskbar, and reads no input. sudo
gets one password: a wrong one fails the job, so start a new id to try again, and
a refusal fails it too. Returns the job once it ends, or after seconds (default
300, at most 3600) or an incoming message; while it still waits for the
password, its record has a prompt. Use bt_process wait/status/output with the
same id after that.
""",Dict{String,Any}("type"=>"object","properties"=>Dict{String,Any}(
    "id"=>Dict("type"=>"string","description"=>"Stable unique id for this attempt: letters, digits, - or _."),
    "argv"=>Dict("type"=>"array","items"=>Dict("type"=>"string")),
    "cwd"=>Dict("type"=>"string"),"label"=>Dict("type"=>"string"),
    "ssh"=>Dict("type"=>"string","description"=>"Run on the host of this bt_ssh connection id instead of the worker."),
    "worker"=>WORKER_ARG,
    "seconds"=>Dict("type"=>"number","exclusiveMinimum"=>0,"maximum"=>3600)),"required"=>["id","argv"]),
    sudo_handler;available=()->!isempty(get(ENV,"BONITOAGENTS_PROCESS_EPOCH","")))

register!("bt_ssh", """
Open an ssh connection that needs a password, a key passphrase or a host key
confirmation. The chat shows the user each question ssh asks and sends the answer
to ssh; you never see it. Never ask the user to type a password into a message.

destination is what you'd give ssh (user@host, or a Host from ~/.ssh/config);
options are extra ssh options as "Key=Value", such as "Port=2222" or
"IdentityFile=~/.ssh/deploy". id is a stable id for this attempt, as for
bt_process.

Returns once the connection is ready, has failed, or after seconds (default 300,
at most 3600). Ready, the job's control_path is a socket through which ssh, scp
and rsync log in without asking: `ssh -S <control_path> <destination> <command>`,
`scp -o ControlPath=<control_path> ...`, `rsync -e "ssh -S <control_path>" ...`.
The connection stays open as a bt_process job, in the taskbar; end it with
bt_process terminate on the same id.

worker opens the connection from another worker of the fleet (its name or id).
Its control_path is then on that worker: use it from there, with bt_process or
bt_sudo on the same worker. It needs this chat's Remote julia switch.
""",Dict{String,Any}("type"=>"object","properties"=>Dict{String,Any}(
    "id"=>Dict("type"=>"string","description"=>"Stable unique id for this attempt: letters, digits, - or _."),
    "destination"=>Dict("type"=>"string"),
    "options"=>Dict("type"=>"array","items"=>Dict("type"=>"string")),
    "label"=>Dict("type"=>"string"),
    "worker"=>WORKER_ARG,
    "seconds"=>Dict("type"=>"number","exclusiveMinimum"=>0,"maximum"=>3600)),"required"=>["id","destination"]),
    ssh_handler;available=()->!isempty(get(ENV,"BONITOAGENTS_PROCESS_EPOCH","")))
