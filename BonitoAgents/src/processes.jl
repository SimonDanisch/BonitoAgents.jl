# ── Every process a chat runs, and the end of all of them ────────────────────
# The record: each chat's processes, on every worker. Its MCP server, the eval
# hosts it has on other workers, and the Julia eval workers of both report
# themselves (BonitoMCP processes.jl, a `process_update` frame over their
# channel), again on every reconnect. It is persisted (processes.json), so it
# outlives a chat model that was closed and the server.
#
# The eval workers are why it exists. Malt starts each in a process group of its
# own, so ending the agent (the worker kills its group) or an eval host never
# reached them, nor what their code started: a test suite or a GPU wait went on
# for good after its chat was restarted.
#
# A restart of the chat, and closing it, end everything in it
# (`end_chat_processes!`); a worker that comes back as a new run has what its
# previous runs left killed (`kill_leftovers!`). The worker kills a recorded pid
# only while the process there is still the recorded one (BonitoWorker
# processes.jl): a pid taken by a later process is left alone.

processes_file(s::ServerState) = joinpath(s.state_dir, "processes.json")

process_dict(p::ChatProcess) = Dict{String,Any}(
    "worker_id" => p.worker_id, "pid" => p.pid, "pgid" => p.pgid, "kind" => p.kind,
    "label" => p.label, "recorded_at" => p.recorded_at, "instance" => p.instance)

ChatProcess(d::AbstractDict) =
    ChatProcess(String(d["worker_id"]), Int(d["pid"]), Int(get(d, "pgid", 0)),
                String(get(d, "kind", "")), String(get(d, "label", "")),
                Float64(d["recorded_at"]), String(get(d, "instance", "")))

function save_processes!(state::ServerState)
    rec = state.processes
    lock(rec.lock) do
        data = Dict{String,Any}(project_id => Any[process_dict(p) for p in values(procs)]
                                for (project_id, procs) in rec.chats if !isempty(procs))
        atomic_write_json(processes_file(state), data)
    end
    return nothing
end

function load_processes!(state::ServerState)
    raw = load_json_tolerant(processes_file(state), "processes.json")
    raw isa AbstractDict || return nothing
    rec = state.processes
    lock(rec.lock) do
        for (project_id, list) in raw, d in list
            p = try
                ChatProcess(d)
            catch e
                (e isa KeyError || e isa MethodError || e isa ArgumentError || e isa InexactError) || rethrow()
                @warn "processes.json: skipping a malformed entry" project_id entry = d exception = e
                continue
            end
            get!(() -> Dict{Tuple{String,Int},ChatProcess}(), rec.chats, String(project_id))[(p.worker_id, p.pid)] = p
        end
    end
    return nothing
end

# The run of `worker_id` the server talks to now ("" before its hello).
worker_instance(state::ServerState, worker_id::AbstractString) =
    lock(() -> get(state.crash_watch.instances, String(worker_id), ""), state.lock)

chat_worker_id(state::ServerState, project_id::AbstractString) =
    (p = get(state.projects[], String(project_id), nothing); p === nothing ? "" : p.worker_id)

"""
    record_process!(state, project_id, host_worker, frame)

A process of the chat started (or reported itself again) or stopped. From the
chat's own MCP (`host_worker == ""`: it runs on the chat's worker) or an eval host.
"""
function record_process!(state::ServerState, project_id::AbstractString,
                         host_worker::AbstractString, d::AbstractDict)
    state = root_state(state)
    worker_id = isempty(host_worker) ? chat_worker_id(state, project_id) : String(host_worker)
    pid = Int(get(d, "pid", 0))
    (isempty(worker_id) || pid <= 0) && return nothing
    alive = get(d, "alive", true) === true
    p = alive ? ChatProcess(worker_id, pid, Int(get(d, "pgid", 0)), String(get(d, "kind", "")),
                            String(get(d, "label", "")), Float64(get(d, "recorded_at", time())),
                            worker_instance(state, worker_id)) : nothing
    rec = state.processes
    changed = lock(rec.lock) do
        procs = get!(() -> Dict{Tuple{String,Int},ChatProcess}(), rec.chats, String(project_id))
        alive ? (procs[(worker_id, pid)] = p; true) : pop!(procs, (worker_id, pid), nothing) !== nothing
    end
    changed && save_processes!(state)
    return nothing
end

"The processes the server has on record for `project_id`."
chat_processes(state::ServerState, project_id::AbstractString) =
    (rec = root_state(state).processes;
     lock(() -> collect(values(get(rec.chats, String(project_id), Dict{Tuple{String,Int},ChatProcess}()))), rec.lock))

function forget_processes!(state::ServerState, project_id::AbstractString, procs)
    rec = root_state(state).processes
    lock(rec.lock) do
        mine = get(rec.chats, String(project_id), nothing)
        mine === nothing && return nothing
        foreach(p -> delete!(mine, (p.worker_id, p.pid)), procs)
        isempty(mine) && delete!(rec.chats, String(project_id))
    end
    save_processes!(state)
    return nothing
end

"""
    kill_processes_on_worker(state, worker_id, procs; timeout) -> Dict{Int,String}

Have `worker_id` kill `procs` (see `kill_processes` in BonitoWorker): each pid's
outcome, "killed" or "gone".
"""
function kill_processes_on_worker(state::ServerState, worker_id::AbstractString,
                                  procs::Vector{ChatProcess}; timeout::Real = 20.0)
    resp = worker_rpc(state, worker_id, "kill_processes", Dict{String,Any}(
        "processes" => Any[Dict{String,Any}("pid" => p.pid, "pgid" => p.pgid,
                                            "recorded_at" => p.recorded_at) for p in procs]); timeout)
    return Dict{Int,String}(Int(r["pid"]) => String(r["outcome"]) for r in resp["results"])
end

"""
    kill_recorded!(state, project_id, procs) -> Vector{ChatProcess}

Kill `procs`, each through its worker, all workers at once, and forget the ones
that are gone now. Returns those that were killed. A process on a worker that is
offline, or too old to kill from the record, stays on record for the next time.
"""
function kill_recorded!(state::ServerState, project_id::AbstractString, procs::Vector{ChatProcess})
    state = root_state(state)
    by_worker = Dict{String,Vector{ChatProcess}}()
    foreach(p -> push!(get!(() -> ChatProcess[], by_worker, p.worker_id), p), procs)
    outcomes = asyncmap(collect(by_worker)) do (worker_id, mine)
        w = get(state.workers[], worker_id, nothing)
        (w === nothing || !isopen(w)) && return (mine, Dict{Int,String}())
        if !can(w, "kill_processes")
            @warn "a worker too old to end a chat's processes: they run on until it is updated" worker = w.name project_id count = length(mine)
            return (mine, Dict{Int,String}())
        end
        result = try
            kill_processes_on_worker(state, worker_id, mine)
        catch e
            e isa InterruptException && rethrow()
            @warn "ending a chat's processes on a worker failed" worker = w.name project_id exception = e
            Dict{Int,String}()
        end
        return (mine, result)
    end
    done = ChatProcess[p for (mine, result) in outcomes for p in mine if haskey(result, p.pid)]
    killed = ChatProcess[p for (mine, result) in outcomes for p in mine if get(result, p.pid, "") == "killed"]
    isempty(done) || forget_processes!(state, project_id, done)
    isempty(killed) || @info "ended a chat's processes" project_id killed = [string(p.kind, " ", p.pid, " on ", p.worker_id) for p in killed]
    return killed
end

"""
    end_chat_processes!(state, project_id) -> Task

End every process the chat runs, on every worker: its eval hosts are told to stop
first (each ends its own eval workers), then whatever is still on record is
killed. The record is taken now and the killing goes on in the background, so a
restart does not wait for it: a process started from here on is not in it.
"""
function end_chat_processes!(state::ServerState, project_id::AbstractString)
    state = root_state(state)
    procs = chat_processes(state, project_id)
    return Base.errormonitor(@async begin
        close_eval_hosts!(state, project_id)
        kill_recorded!(state, project_id, procs)
    end)
end

"""
    kill_leftovers!(state, worker_id)

`worker_id` connected as a new run: kill what its earlier runs left running (an
eval worker survives the kill of the agent that started it). Processes recorded
since it registered are this run's, whatever run they were stamped with.
"""
function kill_leftovers!(state::ServerState, worker_id::AbstractString)
    state = root_state(state)
    since = time()
    instance = worker_instance(state, worker_id)
    rec = state.processes
    by_chat = lock(rec.lock) do
        [(project_id, ChatProcess[p for p in values(procs)
                                  if p.worker_id == worker_id && p.instance != instance && p.recorded_at < since])
         for (project_id, procs) in rec.chats]
    end
    for (project_id, procs) in by_chat
        isempty(procs) || kill_recorded!(state, project_id, procs)
    end
    return nothing
end

"""
    end_chat_session!(model, why)

Everything the chat's session ran ends with it: every process, on every worker
(`end_chat_processes!`), and every row of its task bar. Called by a restart
before the new session starts. A run's card says it was lost, and why; the new
session's agent is not told about it, it could not collect it.
"""
function end_chat_session!(model::ChatModel, why::AbstractString)
    chat = shared(model)
    end_chat_processes!(chat.state, chat.project_id)
    for r in all_runs(chat.runs)
        r.status == "running" || continue
        r.notified = true
        lose_run!(chat, r, why)
    end
    interrupt_background_tasks!(chat; reason = "chat_restarted")
    bar = chat_taskbar(chat)
    foreach(t -> finished!(t; reason = "chat_restarted"), lock(() -> copy(bar.items[]), bar.lock))
    return nothing
end
