# Also bootstrapped into eval workers and usable by detached Julia programs.
# Only stdlibs: reporting must not change the computation's package environment.
module BonitoProgress
using Sockets, UUIDs, Logging
export progress, update!, finish!, fail!, cancel!, progress_logger, progress_context, flush_progress

const ACTIVE = ("running", "paused")
const STATES = (ACTIVE..., "completed", "failed", "cancelled", "closed")

mutable struct Job
    lock::ReentrantLock
    snapshot::Dict{String,Any}
    endpoint::String
    token::String
    wake::Channel{Nothing}
    task::Union{Task,Nothing}
    socket::Union{Sockets.TCPSocket,Nothing}
    acknowledged::Int
    last_error::String
    closed::Bool
    sink::Union{Nothing,Function}
end

"""
    progress_context() -> Dict

The local worker endpoint and progress-only grant. Pass this context to a
separate Julia process as environment variables to report to the same chat.
It grants progress reporting only, never agent control or code execution.
"""
progress_context() = Dict("BONITOAGENTS_PROGRESS_ADDR" => get(ENV,"BONITOAGENTS_PROGRESS_ADDR",""),
    "BONITOAGENTS_PROGRESS_TOKEN" => get(ENV,"BONITOAGENTS_PROGRESS_TOKEN",""),
    "BONITOAGENTS_PROGRESS_CLIENT" => get(ENV,"BONITOAGENTS_PROGRESS_CLIENT",
        nameof(parentmodule(@__MODULE__)) === :BonitoMCP ?
        joinpath(pkgdir(parentmodule(@__MODULE__)),"src","BonitoProgress.jl") : @__FILE__))

function checked_text(value, field; limit=256)
    text = string(value)
    ncodeunits(text) <= limit || throw(ArgumentError("$field exceeds $limit bytes"))
    field in ("id","generation") && isempty(text) && throw(ArgumentError("$field cannot be empty"))
    return text
end

# Small JSON writer for this fixed protocol, so the eval helper needs no JSON
# dependency in the user's project. The receiver uses its normal JSON parser.
function json(io, x::AbstractString)
    print(io, '"')
    for c in x
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif Int(c) < 32
            print(io, "\\u", string(Int(c); base=16, pad=4))
        else
            print(io, c)
        end
    end
    print(io, '"')
end
json(io, ::Nothing) = print(io,"null")
json(io, x::Bool) = print(io,x ? "true" : "false")
json(io, x::Real) = (isfinite(x) || throw(ArgumentError("progress must be finite")); print(io,x))
function json(io, x::AbstractDict)
    print(io,'{')
    for (i,(k,v)) in enumerate(x)
        i > 1 && print(io,',')
        json(io,string(k)); print(io,':'); json(io,v)
    end
    print(io,'}')
end
encode(x) = sprint(json,x)

function send_frame(io, s::AbstractString)
    write(io, UInt8(1), htol(UInt32(ncodeunits(s))))
    write(io,s); flush(io)
end
function receive_frame(io)
    read(io,UInt8) == 1 || error("progress relay returned a binary frame")
    n = Int(ltoh(read(io,UInt32)))
    n <= 65536 || error("progress relay reply too large")
    data = read(io,n)
    length(data) == n || throw(EOFError())
    return String(data)
end

"""
    progress(label; total=nothing, completed=0, id=uuid4(), parent="", primary=true)

Create a job belonging to this chat. Network updates are sent in the background and
coalesced to at most five per second. Unknown totals use an indeterminate bar.
`id` identifies the logical job; creating it again starts a new generation.

A job is callable as `(completed, total)`, so a render farm can use
`renderfarm!(...; progress=job)`. Finish explicitly after validating its result.
The do-block form finishes on return and reports exceptions as failures:
`progress("Render frames"; total=100) do job; renderfarm!(...; progress=job); end`.

Hosts running in the server process may pass `sink = snapshot -> ...` to
consume updates directly. This uses the same job validation and terminal-state
rules as network reporting; no worker connection is opened for a local sink.
Local sink callbacks run synchronously; adapters for frequent events should
coalesce them before publishing updates.
"""
function progress(label::AbstractString; total=nothing, completed=0, id=string(uuid4()),
                  parent="", primary=true, unit="", detail="", context=progress_context(), sink=nothing)
    snapshot = Dict{String,Any}("id"=>checked_text(id,"id"), "generation"=>string(uuid4()), "seq"=>0,
        "label"=>checked_text(label,"label"), "completed"=>0.0, "total"=>nothing, "status"=>"running",
        "parent"=>checked_text(parent,"parent"), "primary"=>Bool(primary),
        "unit"=>checked_text(unit,"unit"), "detail"=>checked_text(detail,"detail";limit=4096))
    job = Job(ReentrantLock(), snapshot, String(context["BONITOAGENTS_PROGRESS_ADDR"]),
        String(context["BONITOAGENTS_PROGRESS_TOKEN"]), Channel{Nothing}(1), nothing, nothing, 0, "", false, sink)
    update!(job,completed; total)
    return job
end

function progress(f::Function, label::AbstractString; kwargs...)
    job = progress(label; kwargs...)
    try
        result = f(job)
        finish!(job)
        return result
    catch e
        if e isa InterruptException
            cancel!(job)
        else
            fail!(job,first(sprint(showerror,e),1024))
        end
        rethrow()
    end
end
(job::Job)(completed::Real,total::Real) = update!(job,completed;total=total==0 ? nothing : total)

"""
    update!(job, completed; total, label, detail, status="running")

Publish actual completed work. Counts may decrease when the job is resumed or
its scope changes; percentages are never inferred from agent activity.
"""
function update!(job::Job, completed::Real; total=get(job.snapshot,"total",nothing),
                 label=nothing, detail=nothing, status="running")
    status in STATES || throw(ArgumentError("unknown progress status: $status"))
    isfinite(completed) && completed >= 0 || throw(ArgumentError("completed must be finite and nonnegative"))
    total === nothing || (total isa Real && isfinite(total) && total > 0 && completed <= total) ||
        throw(ArgumentError("total must be positive and at least completed, or nothing"))
    label === nothing || checked_text(label,"label")
    detail === nothing || checked_text(detail,"detail";limit=4096)
    lock(job.lock) do
        job.closed && throw(ArgumentError("progress reporter is closed"))
        job.snapshot["status"] in ACTIVE || return job
        job.snapshot["seq"] += 1
        job.snapshot["completed"] = Float64(completed)
        job.snapshot["total"] = total === nothing ? nothing : Float64(total)
        job.snapshot["status"] = String(status)
        label === nothing || (job.snapshot["label"] = String(label))
        detail === nothing || (job.snapshot["detail"] = String(detail))
        if job.sink !== nothing
            # In-process hosts report through the same validation and lifecycle
            # without a network round trip or a second progress implementation.
            job.sink(copy(job.snapshot))
            job.acknowledged = job.snapshot["seq"]
        else
            isready(job.wake) || put!(job.wake,nothing)
            if job.task === nothing && !isempty(job.endpoint) && !isempty(job.token)
                job.task = Base.errormonitor(@async publish(job))
            end
        end
    end
    return job
end

"Mark a job completed. Unknown-size jobs finish without inventing a percentage."
finish!(job::Job; detail=nothing) = update!(job,
    something(job.snapshot["total"],job.snapshot["completed"]); detail, status="completed")
"Report a failed job while retaining its last completed count."
fail!(job::Job, detail) = update!(job,job.snapshot["completed"]; status="failed", detail=string(detail))
"Report a cancelled job while retaining its last completed count."
cancel!(job::Job; detail="Cancelled") = update!(job,job.snapshot["completed"]; status="cancelled", detail)

function Base.close(job::Job)
    lock(job.lock) do
        job.closed = true
        job.socket === nothing || close(job.socket)
        isready(job.wake) || put!(job.wake,nothing)
    end
    return nothing
end

function publish(job::Job)
    warned = false
    while true
        job.closed && return nothing
        sock = nothing
        try
            host,port = split(job.endpoint,':')
            sock = Sockets.connect(host,parse(Int,port))
            lock(() -> (job.socket=sock),job.lock)
            send_frame(sock,job.token)
            receive_frame(sock) == "ok" || error("worker refused the progress grant")
            while true
                job.closed && return nothing
                snapshot = lock(() -> copy(job.snapshot),job.lock)
                send_frame(sock,encode(snapshot))
                ack = receive_frame(sock)
                ack == "ok $(snapshot["seq"])" || error("progress update refused: $ack")
                lock(job.lock) do
                    job.acknowledged = snapshot["seq"]
                    job.last_error = ""
                end
                snapshot["status"] in ACTIVE || return nothing
                # A single wakeup and latest snapshot bound memory while offline.
                isready(job.wake) && take!(job.wake)
                latest = lock(() -> job.snapshot["seq"],job.lock)
                latest == snapshot["seq"] && take!(job.wake)
                terminal = lock(() -> !(job.snapshot["status"] in ACTIVE),job.lock)
                terminal || sleep(0.2)
            end
        catch e
            e isa InterruptException && rethrow()
            job.closed && return nothing
            (e isa Base.IOError || e isa EOFError || e isa ArgumentError || e isa ErrorException) || rethrow()
            lock(() -> (job.last_error=sprint(showerror,e)),job.lock)
            if !warned
                # Preserve computation even when telemetry cannot connect.
                @warn "Job progress disconnected; retaining the latest update for retry" job=job.snapshot["id"] error=job.last_error
                warned = true
            end
            timedwait(() -> job.closed,1.0;pollint=0.1)
        finally
            sock === nothing || close(sock)
            lock(() -> (job.socket=nothing),job.lock)
        end
    end
end

"Wait up to `timeout` seconds for the current progress snapshot's acknowledgement."
function flush_progress(job::Job; timeout=5.0)
    target = lock(() -> job.snapshot["seq"],job.lock)
    return timedwait(() -> lock(() -> job.acknowledged >= target,job.lock),timeout; pollint=0.01) === :ok
end

# Forward ordinary logs to the existing logger. ProgressLogging emits the open
# logging protocol too; typed records use its public asprogress consumer API.
mutable struct ProgressLogger <: AbstractLogger
    parent::AbstractLogger
    jobs::Dict{String,Job}
    lock::ReentrantLock
    context::Dict{String,String}
end
progress_logger(parent=current_logger(); context=progress_context()) =
    ProgressLogger(parent,Dict{String,Job}(),ReentrantLock(),Dict{String,String}(context))
Logging.min_enabled_level(l::ProgressLogger) = min(Logging.LogLevel(-1),Logging.min_enabled_level(l.parent))
Logging.shouldlog(::ProgressLogger,args...) = true
Logging.catch_exceptions(::ProgressLogger) = false

function Logging.handle_message(l::ProgressLogger,level,message,mod,group,id,file,line; kwargs...)
    provider = parentmodule(typeof(message))
    typed = nameof(provider) === :ProgressLogging && isdefined(provider,:asprogress) ?
        Base.invokelatest(getfield(provider,:asprogress),level,message,mod,group,id,file,line; kwargs...) : nothing
    raw = get(kwargs,:progress,missing)
    if typed === nothing && !(raw === nothing || raw isa Real || isequal(raw,"done"))
        if level >= Logging.min_enabled_level(l.parent) && Logging.shouldlog(l.parent,level,mod,group,id)
            Logging.handle_message(l.parent,level,message,mod,group,id,file,line; kwargs...)
        end
        return nothing
    end
    value = typed === nothing ? kwargs[:progress] : typed.fraction
    closed = typed === nothing ? value == "done" : typed.done
    fraction = value isa Real && isfinite(value) ? clamp(Float64(value),0,1) : nothing
    key = string(typed === nothing ? id : typed.id)
    label = typed === nothing ? string(message) : typed.name
    parent = typed === nothing ? string(get(kwargs,:parentid,"")) : string(typed.parentid)
    lock(l.lock) do
        job = get(l.jobs,key,nothing)
        if closed
            job === nothing && return nothing
            # @withprogress closes in finally, including on exceptions. A close
            # below 100% is not evidence that the computation succeeded.
            status = job.snapshot["total"] !== nothing && job.snapshot["completed"] >= job.snapshot["total"] ? "completed" : "closed"
            update!(job,job.snapshot["completed"]; status)
            return nothing
        end
        completed = get(kwargs,:completed,fraction === nothing ? 0.0 : fraction)
        total = get(kwargs,:total,fraction === nothing ? nothing : 1.0)
        if job !== nothing && !(job.snapshot["status"] in ACTIVE)
            close(job)
            job = nothing
        end
        if job === nothing
            if length(l.jobs) >= 64
                for (key,old) in collect(l.jobs)
                    old.snapshot["status"] in ACTIVE && continue
                    close(old); delete!(l.jobs,key)
                end
                if length(l.jobs) >= 64
                    @warn "Too many concurrent logged progress jobs; ignoring new job" job=key
                    return nothing
                end
            end
            job = progress(label; id=key, parent, primary=isempty(parent) || parent==string(UUID(0)),
                completed, total, unit=string(get(kwargs,:unit,"")), context=l.context)
            l.jobs[key] = job
        else
            update!(job,completed; total,label)
        end
        fraction !== nothing && fraction >= 1 && finish!(job)
    end
    return nothing
end
end
