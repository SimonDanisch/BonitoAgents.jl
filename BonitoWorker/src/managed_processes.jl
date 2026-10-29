# The worker owns these jobs, not an ACP adapter or an MCP subprocess.
const PROCESS_ACTIVE = ("starting", "running", "interrupting", "terminating", "killing")
const PROCESS_LOG_BYTES = 8 * 1024 * 1024

mutable struct ManagedProcess
    record::Dict{String,Any}
    proc::Union{Base.Process,Nothing}
    pump::Union{Task,Nothing}
    pipe::Union{Pipe,Nothing}
    job_handle::Ptr{Cvoid}
end

mutable struct ProcessSupervisor
    lock::ReentrantLock
    jobs::Dict{String,ManagedProcess}
    closed_epochs::Set{String}
    directory::String
    closed::Bool
    monitor::Union{Task,Nothing}
    publish::Function
end

process_key(project, id) = string(project, '\0', id)
process_text(bytes) = join(isvalid(c) ? c : '�' for c in String(copy(bytes)))

function ProcessSupervisor(directory::AbstractString)
    mkpath(directory)
    return ProcessSupervisor(ReentrantLock(), Dict{String,ManagedProcess}(), Set{String}(),
        String(directory), false, nothing, _ -> nothing)
end

function save_process_jobs!(s::ProcessSupervisor)
    # Call under the supervisor lock; replacing the file is serialized.
    file = joinpath(s.directory, "jobs.json")
    tmp = file * ".tmp"
    write(tmp, JSON.json(Dict("jobs"=>[j.record for j in values(s.jobs)], "closed_epochs"=>collect(s.closed_epochs))))
    mv(tmp, file; force=true)
    return nothing
end

function process_snapshot(s::ProcessSupervisor, j::ManagedProcess; max_bytes=2048, offset=nothing)
    d = copy(j.record)
    file = d["log"]
    bytes = isfile(file) ? filesize(file) : 0
    retained = max(0, Int(d["output_bytes"]) - bytes)
    start = offset === nothing ? max(0, bytes - max_bytes) : clamp(Int(offset) - retained, 0, bytes)
    count = min(max_bytes, bytes - start)
    data = isfile(file) ? open(file, "r") do io
        seek(io, start)
        read(io, count)
    end : UInt8[]
    d["output"] = process_text(data)
    d["output_offset"] = retained + start
    d["next_offset"] = retained + start + count
    d["output_truncated"] = retained > 0 || (offset !== nothing && offset < retained)
    delete!(d, "log")
    return d
end

function publish_process!(s::ProcessSupervisor, j::ManagedProcess)
    snapshot = lock(() -> process_snapshot(s, j), s.lock)
    s.publish(snapshot)
    return snapshot
end

function process_log_pump(s::ProcessSupervisor, j::ManagedProcess)
    try
        open(j.record["log"], "w+") do io
            while !eof(j.pipe)
                data = readavailable(j.pipe)
                isempty(data) && continue
                lock(s.lock) do
                    received = length(data)
                    if received > PROCESS_LOG_BYTES
                        data = data[end-PROCESS_LOG_BYTES+1:end]
                    end
                    if position(io) + length(data) > PROCESS_LOG_BYTES
                        kept = min(position(io), PROCESS_LOG_BYTES ÷ 2, PROCESS_LOG_BYTES-length(data))
                        seek(io, position(io) - kept)
                        tail = read(io)
                        seekstart(io); truncate(io, 0); write(io, tail)
                    end
                    write(io, data); flush(io)
                    j.record["output_bytes"] += received
                end
            end
        end
    catch e
        (e isa Base.IOError || e isa SystemError) || rethrow()
        lock(s.lock) do
            j.record["error"] = "Output capture failed: " * sprint(showerror, e)
        end
        @error "managed process output capture failed" id=j.record["id"] exception=(e, catch_backtrace())
    finally
        close(j.pipe)
    end
    return nothing
end

"""
    start_process!(supervisor, project, argv; id, cwd, label, env=Dict())

Start a supervised, noninteractive command. `argv` is an argument vector, not
shell syntax. Reusing `id` in this chat returns the existing job, so a retried
launch cannot duplicate work. Example: `start_process!(s, "chat", ["make"];
id="build-1", cwd=pwd(), label="Build")`.
"""
function start_process!(s::ProcessSupervisor, project::AbstractString, argv::AbstractVector;
                        id::AbstractString, cwd::AbstractString, label::AbstractString,
                        env::AbstractDict=Dict{String,String}(), epoch::AbstractString="")
    occursin(r"^[A-Za-z0-9_-]{1,80}$", id) || throw(ArgumentError("id must use 1–80 letters, digits, underscores or hyphens"))
    !isempty(argv) && all(a -> a isa AbstractString && !occursin('\0', a), argv) ||
        throw(ArgumentError("argv must be a nonempty array of strings"))
    isabspath(cwd) && isdir(cwd) || throw(ArgumentError("cwd must be an existing absolute worker directory"))
    ncodeunits(label) <= 256 || throw(ArgumentError("label is too long"))
    all(kv -> first(kv) isa AbstractString && last(kv) isa AbstractString, env) ||
        throw(ArgumentError("env values must be strings"))
    job = lock(s.lock) do
        s.closed && error("process supervisor is closed")
        epoch in s.closed_epochs && error("this agent session ended; start work from the current session")
        key = process_key(project, id)
        prior = get(s.jobs, key, nothing)
        if prior !== nothing
            prior.record["argv"] == argv && prior.record["cwd"] == cwd ||
                throw(ArgumentError("this id already belongs to another command; choose a new id"))
            return prior
        end
        if length(s.jobs) >= 256
            old = sort!([j for j in values(s.jobs) if !(j.record["status"] in PROCESS_ACTIVE)];
                by=j -> j.record["started"])
            isempty(old) && error("managed process history is full")
            victim = first(old)
            rm(victim.record["log"];force=true)
            delete!(s.jobs,process_key(victim.record["project_id"],victim.record["id"]))
        end
        count(j -> j.record["status"] in PROCESS_ACTIVE, values(s.jobs)) < 64 ||
            error("worker already has 64 active managed processes")
        token = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
        record = Dict{String,Any}("project_id"=>String(project), "id"=>String(id),
            "argv"=>String.(argv), "cwd"=>String(cwd), "label"=>String(label),
            "status"=>"starting", "pid"=>0, "pgid"=>0, "started"=>time(),
            "finished"=>nothing, "exitcode"=>nothing, "signal"=>nothing,
            "output_bytes"=>0, "log"=>joinpath(s.directory, token * ".log"),
            "error"=>"", "last_action"=>"", "revision"=>1)
        record["epoch"] = String(epoch)
        j = ManagedProcess(record, nothing, nothing, nothing, C_NULL)
        s.jobs[key] = j
        save_process_jobs!(s)
        gate = Pipe()
        try
            pipe = Pipe()
            j.pipe = pipe
            cmd = addenv(detach(Cmd(process_launch_command(String.(argv)); dir=String(cwd))),
                (String(k)=>String(v) for (k,v) in env)...)
            Sys.iswindows() && (cmd = addenv(cmd,"BONITOAGENTS_JOB_ARGV"=>JSON.json(argv)))
            j.proc = run(pipeline(cmd; stdin=gate, stdout=pipe, stderr=pipe); wait=false)
            close(pipe.in)
            close(gate.out)
            record["pid"] = Int(getpid(j.proc))
            j.job_handle = process_job_handle(record["pid"])
            record["pgid"] = Sys.isunix() ? Int(ccall(:getpgid, Cint, (Cint,), record["pid"])) : 0
            record["recorded_at"] = time()
            record["os_started"] = process_started(record["pid"])
            record["status"] = "running"
            j.pump = Base.errormonitor(@async process_log_pump(s, j))
            # Persist ownership before the command is allowed to execute. If
            # the worker dies earlier, EOF makes the launcher exit without
            # starting user work. This also prevents fast exits racing getpid.
            save_process_jobs!(s)
            write(gate,"go\n"); flush(gate)
        catch e
            if j.proc !== nothing && process_running(j.proc)
                kill_proc!(j.proc)
            end
            close_process_handle!(j)
            j.pipe === nothing || close(j.pipe)
            record["status"] = "failed"
            record["finished"] = time()
            record["error"] = sprint(showerror, e)
            save_process_jobs!(s)
            (e isa Base.IOError || e isa SystemError || e isa ArgumentError || e isa ErrorException) || rethrow()
        finally
            close(gate)
        end
        save_process_jobs!(s)
        j
    end
    return publish_process!(s, job)
end

function process_launch_command(argv)
    if Sys.iswindows()
        script = "if ([Console]::In.ReadLine() -ne 'go') { exit 125 }; " *
            "\$v = @(ConvertFrom-Json \$env:BONITOAGENTS_JOB_ARGV); Remove-Item Env:BONITOAGENTS_JOB_ARGV; " *
            "\$program = \$v[0]; \$a = @(); if (\$v.Count -gt 1) { \$a = \$v[1..(\$v.Count-1)] }; " *
            "& \$program @a; \$ok = \$?; if (\$null -ne \$LASTEXITCODE) { exit \$LASTEXITCODE }; if (-not \$ok) { exit 1 }"
        return Cmd(["powershell","-NoProfile","-NonInteractive","-Command",script])
    end
    return Cmd(["/bin/sh","-c","IFS= read -r gate || exit 125; [ \"\$gate\" = go ] || exit 125; exec \"\$@\"",
        "bonito-managed-process",argv...])
end

function process_groups_alive()
    # Scan /proc once per supervisor tick, not once per job. Zombies have
    # already exited and must not keep an orphaned process group "running".
    groups = Set{Int}()
    Sys.islinux() || return groups
    for name in readdir("/proc")
        tryparse(Int, name) === nothing && continue
        stat = try
            read("/proc/$name/stat", String)
        catch e
            (e isa SystemError || e isa Base.IOError) || rethrow()
            continue
        end
        fields = split(stat[findlast(')', stat)+2:end])
        fields[1] in ("Z", "X") || push!(groups, parse(Int, fields[3]))
    end
    return groups
end

function managed_group_alive(j::ManagedProcess, groups)
    Sys.iswindows() && j.job_handle != C_NULL && return windows_job_alive(j.job_handle)
    Sys.isunix() || return j.proc !== nothing && process_running(j.proc)
    pgid = j.record["pgid"]
    managed_pid_reused(j) && return false
    pgid > 0 || return j.proc !== nothing && process_running(j.proc)
    return Sys.islinux() ? pgid in groups : ccall(:kill, Cint, (Cint,Cint), -pgid, 0) == 0
end

function managed_pid_reused(j)
    pid = j.record["pid"]
    pid > 0 || return false
    began = process_started(pid)
    began === nothing && return false
    original = get(j.record,"os_started",nothing)
    return Sys.islinux() && original !== nothing ? began != original :
        began > get(j.record,"recorded_at",j.record["started"]) + 2.0
end

function signal_process!(s::ProcessSupervisor, project, id, action::AbstractString)
    action in ("interrupt", "terminate", "kill") || throw(ArgumentError("unknown process signal"))
    job = lock(s.lock) do
        j = get(s.jobs, process_key(project,id), nothing)
        j === nothing && throw(ArgumentError("no managed process '$id' in this chat"))
        j.record["status"] in PROCESS_ACTIVE || return j
        pid, pgid = j.record["pid"], j.record["pgid"]
        pid > 0 || error("process is still starting")
        managed_pid_reused(j) && error("the recorded process id was reused; refusing to signal another process")
        if Sys.iswindows()
            action == "interrupt" && error("graceful interrupt is unavailable on this Windows worker; use terminate or kill")
            if action == "kill" && j.job_handle != C_NULL
                windows_kill_job(j.job_handle)
            else
                cmd = action == "kill" ? `taskkill /F /T /PID $pid` : `taskkill /T /PID $pid`
                success(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull)) ||
                    error("Windows could not $action process $pid; inspect its status before retrying")
            end
        else
            pgid == pid && pgid != Int(ccall(:getpgrp, Cint, ())) || error("process does not own an isolated group")
            sig = action == "interrupt" ? 2 : action == "terminate" ? 15 : 9
            result = ccall(:kill, Cint, (Cint,Cint), -pgid, sig)
            if result != 0
                err = Libc.errno()
                err == Libc.ESRCH || error("$action failed: $(Libc.strerror(err))")
            end
        end
        j.record["last_action"] = String(action)
        j.record["status"] = action == "interrupt" ? "interrupting" : action == "terminate" ? "terminating" : "killing"
        j.record["revision"] += 1
        save_process_jobs!(s)
        j
    end
    return publish_process!(s, job)
end

function monitor_processes!(s::ProcessSupervisor)
    seen = Dict{String,Tuple{Int,Int}}()
    while !s.closed
        active = lock(() -> [j for j in values(s.jobs) if j.record["status"] in PROCESS_ACTIVE], s.lock)
        needs_groups = any(j -> j.proc === nothing || process_exited(j.proc), active)
        groups = needs_groups ? process_groups_alive() : Set{Int}()
        for j in active
            snapshot = lock(s.lock) do
                d = j.record
                if (j.proc === nothing || process_exited(j.proc)) && !managed_group_alive(j, groups) &&
                        (j.pump === nothing || istaskdone(j.pump))
                    d["exitcode"] = j.proc === nothing ? nothing : j.proc.exitcode
                    d["signal"] = j.proc === nothing ? nothing : j.proc.termsignal
                    d["finished"] = time()
                    d["status"] = j.proc === nothing ? "lost" : d["last_action"] == "kill" ? "killed" :
                        d["last_action"] in ("interrupt","terminate") ? "interrupted" :
                        success(j.proc) && isempty(d["error"]) ? "succeeded" : "failed"
                    d["revision"] += 1
                    close_process_handle!(j)
                    save_process_jobs!(s)
                end
                fingerprint = (Int(d["output_bytes"]), Int(d["revision"]))
                key = process_key(d["project_id"], d["id"])
                get(seen,key,nothing) == fingerprint && return nothing
                seen[key] = fingerprint
                process_snapshot(s,j)
            end
            snapshot === nothing || s.publish(snapshot)
        end
        sleep(0.5)
    end
    return nothing
end

function managed_process_request(s::ProcessSupervisor, project, args::AbstractDict)
    action = String(get(args,"action","list"))
    action == "start" && return start_process!(s, project, get(args,"argv",Any[]);
        id=String(get(args,"id","")), cwd=String(get(args,"cwd","")),
        label=String(get(args,"label",get(args,"id",""))), env=get(args,"env",Dict()), epoch=String(get(args,"epoch","")))
    id = String(get(args,"id",""))
    action in ("interrupt","terminate","kill") && return signal_process!(s,project,id,action)
    action in ("list","status","output") || throw(ArgumentError("unknown process action '$action'"))
    limit = get(args,"max_bytes",8192)
    limit isa Integer && 1 <= limit <= 65536 || throw(ArgumentError("max_bytes must be 1–65536"))
    offset = get(args,"offset",nothing)
    offset === nothing || (offset isa Integer && offset >= 0) || throw(ArgumentError("offset must be nonnegative"))
    return lock(s.lock) do
        if action == "list"
            return Dict("jobs"=>[process_snapshot(s,j;max_bytes=512) for j in values(s.jobs) if j.record["project_id"] == project])
        end
        j = get(s.jobs,process_key(project,id),nothing)
        j === nothing && throw(ArgumentError("no managed process '$id' in this chat"))
        process_snapshot(s,j;max_bytes=limit,offset=action == "output" ? offset : nothing)
    end
end

function close_process_jobs!(s::ProcessSupervisor, project=nothing; epoch=nothing)
    ids = lock(s.lock) do
        epoch === nothing || push!(s.closed_epochs,String(epoch))
        save_process_jobs!(s)
        [(j.record["project_id"],j.record["id"]) for j in values(s.jobs)
            if j.record["status"] in PROCESS_ACTIVE && (project === nothing || j.record["project_id"] == project) &&
                (epoch === nothing || get(j.record,"epoch","") == epoch)]
    end
    for (pid,id) in ids
        signal_process!(s,pid,id,"kill")
    end
    return nothing
end

function publish_worker_process!(w, snapshot)
    ctrl = lock(() -> w.control, w.lock)
    ctrl === nothing && return nothing
    try
        send_control(ctrl, Dict("type"=>"managed_process_update", "job"=>snapshot))
    catch e
        (e isa WebSockets.WebSocketError || e isa WorkerLink.LinkDead || e isa Base.IOError) || rethrow()
        # The worker remains authoritative while disconnected. connected!
        # re-announces every record, including exits missed by the server.
    end
    return nothing
end

function announce_process_jobs!(w)
    snapshots = lock(() -> [process_snapshot(w.jobs,j) for j in values(w.jobs.jobs)], w.jobs.lock)
    foreach(d -> publish_worker_process!(w,d), snapshots)
    return nothing
end

function handle_managed_process(w, ws, cmd)
    reply = Dict{String,Any}("type"=>"managed_process_response", "request_id"=>get(cmd,"request_id",""))
    reply_with(ws,reply) do
        project = String(cmd["project_id"])
        action = get(cmd,"action","")
        if action == "close_chat"
            close_process_jobs!(w.jobs,project; epoch=String(cmd["epoch"]))
            return Dict("requested"=>true)
        end
        return Dict("result"=>managed_process_request(w.jobs,project,cmd))
    end
end

function restore_process_jobs!(s::ProcessSupervisor)
    file = joinpath(s.directory,"jobs.json")
    isfile(file) || return nothing
    stored = JSON.parsefile(file)
    lock(s.lock) do
        union!(s.closed_epochs,String.(stored["closed_epochs"]))
        for raw in stored["jobs"]
            d = Dict{String,Any}(raw)
            j = ManagedProcess(d,nothing,nothing,nothing,C_NULL)
            s.jobs[process_key(d["project_id"],d["id"])] = j
            d["status"] in PROCESS_ACTIVE || continue
            # A crash may leave additional flushed log bytes after the last
            # metadata checkpoint. The job is lost; reset its output cursor
            # to the retained file rather than returning negative offsets.
            d["output_bytes"] = isfile(d["log"]) ? filesize(d["log"]) : 0
            d["output_cursor_reset"] = true
            pid = d["pid"]
            if pid > 0 && !managed_pid_reused(j)
                result = only(kill_processes([d]))
                result["outcome"] == "refused" && error("refused to reap old managed process $pid")
            end
            d["status"] = "killing"
            d["error"] = "Worker restarted; the previous job was stopped. Start a new job id to retry."
            d["revision"] += 1
        end
        save_process_jobs!(s)
    end
    return nothing
end

# Windows Job Objects keep descendant ownership after the original command
# exits, and the OS kills the job if its worker crashes and loses the handle.
@static if !Sys.iswindows()
    process_job_handle(pid) = C_NULL
    close_process_handle!(j) = nothing
end
@static if Sys.iswindows()
    function process_job_handle(pid)
        handle = ccall((:CreateJobObjectW,"kernel32"),Ptr{Cvoid},(Ptr{Cvoid},Ptr{UInt16}),C_NULL,C_NULL)
        handle == C_NULL && error("CreateJobObject failed")
        try
            limits = zeros(UInt8, Sys.WORD_SIZE == 64 ? 144 : 112)
            GC.@preserve limits unsafe_store!(Ptr{UInt32}(pointer(limits)+16),UInt32(0x2000))
            ccall((:SetInformationJobObject,"kernel32"),Int32,(Ptr{Cvoid},Int32,Ptr{UInt8},UInt32),
                handle,9,limits,length(limits)) != 0 || error("SetInformationJobObject failed")
            proc = ccall((:OpenProcess,"kernel32"),Ptr{Cvoid},(UInt32,Int32,UInt32),0x0101,0,pid)
            proc == C_NULL && error("OpenProcess failed for managed process $pid")
            try
                ccall((:AssignProcessToJobObject,"kernel32"),Int32,(Ptr{Cvoid},Ptr{Cvoid}),handle,proc) != 0 ||
                    error("AssignProcessToJobObject failed; no supervised command was accepted")
            finally
                ccall((:CloseHandle,"kernel32"),Int32,(Ptr{Cvoid},),proc)
            end
            return handle
        catch
            ccall((:CloseHandle,"kernel32"),Int32,(Ptr{Cvoid},),handle)
            rethrow()
        end
    end
    function windows_job_alive(handle)
        info = zeros(UInt8,48)
        ccall((:QueryInformationJobObject,"kernel32"),Int32,(Ptr{Cvoid},Int32,Ptr{UInt8},UInt32,Ptr{UInt32}),
            handle,1,info,length(info),C_NULL) != 0 || error("QueryInformationJobObject failed")
        return GC.@preserve info unsafe_load(Ptr{UInt32}(pointer(info)+40)) > 0
    end
    function windows_kill_job(handle)
        ccall((:TerminateJobObject,"kernel32"),Int32,(Ptr{Cvoid},UInt32),handle,1) != 0 || error("TerminateJobObject failed")
        return nothing
    end
    function close_process_handle!(j)
        if j.job_handle != C_NULL
            ccall((:CloseHandle,"kernel32"),Int32,(Ptr{Cvoid},),j.job_handle) != 0 || error("CloseHandle failed")
            j.job_handle = C_NULL
        end
        return nothing
    end
end
