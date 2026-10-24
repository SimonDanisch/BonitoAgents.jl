# ── Killing what a chat ran, from the server's record ────────────────────────
# The server records every process a chat runs on this machine: the MCP server
# its agent started, the eval host it had us spawn, and the Julia eval workers of
# both (BonitoAgents processes.jl, reported by BonitoMCP processes.jl). The eval
# workers are the reason: Malt starts each in a process group of its own, so the
# group kill that ends an agent or an eval host (`kill_proc!`) never reaches them.
# On a restart of the chat the server sends the record here, and this kills it:
#
#     {type:"kill_processes", request_id, processes:[{pid, pgid, recorded_at}]}
#  -> {type:"kill_processes_response", request_id, results:[{pid, outcome}]}
#
# `outcome` is "killed", or "gone" for a process that ended already, or whose pid
# another process has taken since, or "refused" for this worker and the processes
# it runs under (`runs_this_worker`).

"""
    process_started(pid) -> Union{Float64,Nothing}

When the OS started process `pid`, as Unix time, or `nothing` when there is no
such process (or the OS will not say).
"""
function process_started(pid::Integer)
    pid > 0 || return nothing
    if Sys.islinux()
        stat = try
            read("/proc/$pid/stat", String)
        catch e
            (e isa SystemError || e isa Base.IOError) || rethrow()
            return nothing
        end
        # The command name, field 2, may hold spaces and parentheses: count from
        # its closing one. `starttime` is field 22, in clock ticks after boot.
        fields = split(stat[findlast(')', stat) + 2:end])
        return linux_boot_time() + parse(Int, fields[20]) / linux_clock_ticks()
    elseif Sys.iswindows()
        cmd = `powershell -NoProfile -Command "\$p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if (\$p) { [DateTimeOffset]::new(\$p.StartTime).ToUnixTimeMilliseconds() }"`
        ms = tryparse(Int, command_output(cmd))
        return ms === nothing ? nothing : ms / 1000
    else
        # macOS and the BSDs: the elapsed time since it started, [[dd-]hh:]mm:ss.
        out = command_output(`ps -o etime= -p $pid`)
        isempty(out) && return nothing
        return time() - etime_seconds(out)
    end
end

# What `cmd` prints, stripped, whatever its exit status: `ps` exits non-zero for
# a pid that is gone, which here just means "no answer". Its stderr is dropped.
# `ignorestatus` takes the command itself, not the pipeline around it.
command_output(cmd::Cmd) = strip(read(pipeline(ignorestatus(cmd); stderr = devnull), String))

linux_boot_time() = parse(Int, last(split(only(filter(startswith("btime "), readlines("/proc/stat"))))))
linux_clock_ticks() = Int(ccall(:sysconf, Clong, (Cint,), 2))   # _SC_CLK_TCK

function etime_seconds(s::AbstractString)
    days, rest = occursin('-', s) ? (parse(Int, first(split(s, '-'))), last(split(s, '-'))) : (0, s)
    parts = parse.(Int, split(rest, ':'))
    secs = foldl((acc, p) -> 60acc + p, parts; init = 0)
    return 86400days + secs
end

"""
    recorded_alive(pid, recorded_at) -> Bool

Whether the process recorded as alive at `recorded_at` still runs as `pid`. A
process that took the pid after it ended started after `recorded_at`, so it
fails this; two seconds cover the OS's start-time rounding.
"""
function recorded_alive(pid::Integer, recorded_at::Real)
    started = process_started(pid)
    return started !== nothing && started <= recorded_at + 2.0
end

"""
    kill_recorded!(pid, pgid)

Kill a recorded process with everything under it: its descendants (snapshot
first: a child outlives its dead parent) and, when it leads one, its process
group, which holds what its code started. Never this worker or its group.
"""
function kill_recorded!(pid::Integer, pgid::Integer)
    pid == getpid() && error("refusing to kill this worker (pid $pid) from a chat's record")
    if Sys.iswindows()
        run(pipeline(ignorestatus(`taskkill /F /T /PID $pid`); stdout = devnull, stderr = devnull))
        return nothing
    end
    tree = filter(!=(getpid()), process_tree([Int(pid)]))
    ours = Int(ccall(:getpgid, Cint, (Cint,), 0))
    group = Int(ccall(:getpgid, Cint, (Cint,), pid))
    # Only a group the process LEADS: anything else is someone's shared one.
    (group == pid && group != ours) && ccall(:kill, Cint, (Cint, Cint), -group, 9)
    (pgid > 0 && pgid == pid && pgid != ours && pgid != group) && ccall(:kill, Cint, (Cint, Cint), -pgid, 9)
    for p in tree
        ccall(:kill, Cint, (Cint, Cint), p, 9)
    end
    return nothing
end

"""
    parent_pid(pid) -> Int

The parent of process `pid`, or 0 when there is no such process.
"""
function parent_pid(pid::Integer)
    if Sys.islinux()
        stat = try
            read("/proc/$pid/stat", String)
        catch e
            (e isa SystemError || e isa Base.IOError) || rethrow()
            return 0
        end
        # After the command name (see `process_started`): state, then ppid.
        return parse(Int, split(stat[findlast(')', stat) + 2:end])[2])
    end
    out = command_output(`ps -o ppid= -p $pid`)
    return something(tryparse(Int, out), 0)
end

"""
    runs_this_worker(pid) -> Bool

Whether `pid` is this worker or a process it runs under: killing one ends the
worker too. A record names one when an MCP runs INSIDE a process the worker
descends from and reports that process as its own. TestKit's in-process MCP
does: the test process started this worker, and closing a chat from the record
took the test process down with everything it ran.
"""
function runs_this_worker(pid::Integer)
    pid == getpid() && return true
    Sys.iswindows() && return false
    p = Int(ccall(:getppid, Cint, ()))
    seen = Set{Int}()
    while p > 1 && !(p in seen)
        p == pid && return true
        push!(seen, p)
        p = parent_pid(p)
    end
    return false
end

function kill_processes(processes::AbstractVector)
    return map(processes) do p
        pid  = Int(p["pid"])
        pgid = Int(get(p, "pgid", 0))
        outcome = if runs_this_worker(pid)
            "refused"
        elseif recorded_alive(pid, Float64(p["recorded_at"]))
            kill_recorded!(pid, pgid)
            "killed"
        elseif orphaned_group(pid, pgid)
            # The process died and left what its code started in its group: the
            # pid is still that group's (POSIX reuses neither while it lives).
            ccall(:kill, Cint, (Cint, Cint), -pgid, 9)
            "killed"
        else
            "gone"
        end
        Dict{String,Any}("pid" => pid, "outcome" => outcome)
    end
end

# The group a recorded process led outlives it, with no process at its pid.
function orphaned_group(pid::Integer, pgid::Integer)
    (Sys.isunix() && pgid > 0 && pgid == pid) || return false
    pgid == Int(ccall(:getpgid, Cint, (Cint,), 0)) && return false
    process_started(pid) === nothing || return false
    return ccall(:kill, Cint, (Cint, Cint), -pgid, 0) == 0
end

function handle_kill_processes(ws, cmd::AbstractDict)
    reply = Dict{String,Any}("type" => "kill_processes_response",
                             "request_id" => String(get(cmd, "request_id", "")))
    reply_with(ws, reply) do
        results = kill_processes(get(cmd, "processes", Any[]))
        killed = count(r -> r["outcome"] == "killed", results)
        killed > 0 && @info "BonitoWorker: killed a chat's recorded processes" killed
        Dict{String,Any}("results" => results)
    end
end
