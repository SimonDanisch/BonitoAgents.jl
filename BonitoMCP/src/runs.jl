# ── Runs: every eval, tracked from start to finish ───────────────────────────
# A RUN is one `bt_julia_eval` execution, with a short id (`r4`) the agent and
# the chat both use to talk about it. It exists so an eval can outlive the tool
# call that started it:
#
#   * `bt_julia_eval(background = true)` returns at once; the run goes on, and
#     `bt_julia_wait(runs = [...])` blocks on one or several of them;
#   * a foreground eval that passes its soft checkpoint is the same run, which
#     `bt_julia_continue(run = …)` / `bt_julia_wait` pick up again.
#
# ONE task reads a run's output: its collector (`collect_run!`), which polls the
# session in short slices, appends everything to the run and stores the result
# when the eval ends. Tool calls never drain the session themselves; they read
# the run. That is what lets a background run keep its whole output while nobody
# is asking, and several tool calls look at one run without stealing each
# other's lines.
#
# Output lives in three places, each for one reader:
#   `unseen` — what the AGENT has not been shown yet (tail-capped), handed out
#              by the next response for this run;
#   `tail`   — the recent output as a whole, for the chat's final card;
#   the log file — everything, up to `RUN_LOG_MAX_BYTES`, on this worker, so a
#              long test log keeps its beginning. Responses name it when they
#              had to cut.
#
# Which runs can overlap: one per SESSION (env on a worker). A second eval in a
# busy env is refused with the running run's id, never queued: two runs in one
# process would share its state, and a queue would hide that the first is
# still going.
#
# The server hears about every run (`run_update` frames, see `announce`): the
# chat keeps the run's card live until it ends, lists it in the task bar and
# tells the agent when a run it has not collected finishes.

const RUN_POLL_S        = 0.5                 # collector slice: how often output reaches the run
const RUN_LOG_MAX_BYTES = 64 * 1024 * 1024    # per-run log file bound
const RUN_TAIL_BYTES    = 64 * 1024           # the chat card's final output
const RUNS_KEPT         = 64                  # collected runs remembered for lookups

mutable struct EvalRun
    const id::String
    const session::JuliaSession
    const env_path::Union{String,Nothing}     # as the agent gave it; nothing = temp session
    const background::Bool
    const tool_use_id::String                 # the agent's id for the starting call ("" if unknown)
    const started::Float64
    const log_path::String
    const lock::ReentrantLock                 # guards the mutable fields below
    const done::Base.Event                    # notified once the run has finished
    log::Union{IOStream,Nothing}
    log_bytes::Int                            # written to the log (bounded)
    total_bytes::Int                          # all output, of which `tail` keeps the end
    unseen::Vector{UInt8}
    tail::Vector{UInt8}
    status::Symbol                            # :running | :passed | :failed | :interrupted
    interrupt_requested::Bool
    result::Any                               # the session's completed tuple, once done
    finished::Float64
    summary::String                           # a failure's first line; "" otherwise
    collected::Bool                           # the agent has been handed the result
end

# A run this chat started on ANOTHER worker: it lives in that worker's eval host
# (the host has the `EvalRun`); this process only needs to know where to ask.
struct RemoteRun
    worker::String
    env_path::Union{String,Nothing}
    background::Bool
end

mutable struct RunRegistry
    runs::Dict{String,EvalRun}                # executed in this process
    remote::Dict{String,RemoteRun}            # started from here on other workers
    next::Int
    logs_dir::String                          # "" until the first run; removed at exit
    const lock::ReentrantLock
end
RunRegistry() = RunRegistry(Dict{String,EvalRun}(), Dict{String,RemoteRun}(), 0, "", ReentrantLock())

"A run that does not exist (here, or at all)."
struct UnknownRun <: Exception
    id::String
end
Base.showerror(io::IO, e::UnknownRun) =
    print(io, "no run '$(e.id)' — bt_julia_list_sessions lists the runs of this chat")

"A second eval in an env whose run is still going."
struct RunBusy <: Exception
    run::EvalRun
end
function Base.showerror(io::IO, e::RunBusy)
    r = e.run
    print(io, "run $(r.id) is still running in this env ($(env_label(r.env_path)), ",
          "for $(elapsed_label(time() - r.started))). Wait for it with ",
          "bt_julia_wait(runs = [\"$(r.id)\"]) or stop it with ",
          "bt_julia_interrupt(run = \"$(r.id)\") first.")
end

env_label(env_path::Union{String,Nothing}) = env_path === nothing ? "<temp>" : env_path

# "8s" / "3m41s" / "1h02m"
function elapsed_label(sec::Real)
    s = round(Int, sec)
    s < 60 && return "$(s)s"
    s < 3600 && return "$(s ÷ 60)m$(lpad(s % 60, 2, '0'))s"
    return "$(s ÷ 3600)h$(lpad((s % 3600) ÷ 60, 2, '0'))m"
end

function new_run_id!(reg::RunRegistry)
    @lock reg.lock begin
        reg.next += 1
        return "r$(reg.next)"
    end
end

is_running(r::EvalRun) = @lock r.lock r.status === :running

"The run executing in `s` right now, or `nothing`."
function running_run(reg::RunRegistry, s::JuliaSession)
    @lock reg.lock begin
        for r in values(reg.runs)
            r.session === s && is_running(r) && return r
        end
        return nothing
    end
end

"The newest run of `s` the agent has not collected yet (running or finished), or `nothing`."
function open_run(reg::RunRegistry, s::JuliaSession)
    @lock reg.lock begin
        best = nothing
        for r in values(reg.runs)
            r.session === s || continue
            (is_running(r) || !(@lock r.lock r.collected)) || continue
            (best === nothing || r.started > best.started) && (best = r)
        end
        return best
    end
end

function lookup_run(reg::RunRegistry, id::AbstractString)
    @lock reg.lock begin
        r = get(reg.runs, String(id), nothing)
        r === nothing && throw(UnknownRun(String(id)))
        return r
    end
end

# Forget the oldest collected runs past `RUNS_KEPT`. Running and uncollected
# runs always stay: someone is still going to ask about them.
function prune_runs!(reg::RunRegistry)
    @lock reg.lock begin
        done = [r for r in values(reg.runs) if !is_running(r) && (@lock r.lock r.collected)]
        length(done) <= RUNS_KEPT && return nothing
        sort!(done; by = r -> r.started)
        for r in done[1:(end - RUNS_KEPT)]
            delete!(reg.runs, r.id)
        end
    end
    return nothing
end

# The run logs of this process, in tempdir, removed when it exits. Created (and
# the removal armed) at the first run: the registry itself is built while the
# package precompiles, where an `atexit` would never reach the real process.
function run_logs_dir(reg::RunRegistry)
    @lock reg.lock begin
        if isempty(reg.logs_dir)
            reg.logs_dir = mkpath(joinpath(tempdir(), "bonitoagents-runs-$(getpid())"))
            dir = reg.logs_dir
            atexit(() -> rm(dir; recursive = true, force = true))
        end
        return reg.logs_dir
    end
end

"""
    start_run!(reg, s, code; id, env_path, background, tool_use_id, max_bytes, full_output) -> EvalRun

Start `code` in session `s` as run `id` and return at once; the run's collector
takes it from there. Throws `RunBusy` when `s` already has a run going.
"""
function start_run!(reg::RunRegistry, s::JuliaSession, code::AbstractString;
                    id::AbstractString, env_path::Union{String,Nothing},
                    background::Bool, tool_use_id::AbstractString = "",
                    max_bytes::Int = 10_000, full_output::Bool = false)
    busy = running_run(reg, s)
    busy === nothing || throw(RunBusy(busy))
    prune_runs!(reg)
    started = time()
    # Zero checkpoint: `execute` starts the eval and comes straight back.
    res = execute(s, code; timeout = 0.0, max_bytes, full_output)
    log_path = joinpath(run_logs_dir(reg), "$(id).log")
    run = EvalRun(String(id), s, env_path, background, String(tool_use_id), started,
                  log_path, ReentrantLock(), Base.Event(), open(log_path, "w"), 0, 0,
                  UInt8[], UInt8[], :running, false, nothing, 0.0, "", false)
    @lock reg.lock (reg.runs[run.id] = run)
    announce(run)
    if res.status === :completed        # rejected before it ran (a parse error)
        finish!(run, res)
    else
        append_output!(run, res.partial)
        Base.errormonitor(Threads.@spawn collect_run!(run))
    end
    return run
end

# The run's only reader. Polls the session in short slices so output reaches
# the run (and the agent, and the chat) while it runs, and stores the result
# when the eval ends. A session that dies under it (restart, a cancel that had to
# kill the worker) ends the run as failed rather than leaving it running forever.
function collect_run!(run::EvalRun)
    s = run.session
    while true
        res = try
            continue_eval!(s; timeout = RUN_POLL_S)
        catch e
            e isa InterruptException && rethrow()
            echo = "\e[91mERROR: the Julia session ended while this ran " *
                   "($(sprint(showerror, e)))\e[39m"
            finish!(run, completed_result(echo; is_error = true,
                                          elapsed_s = round(time() - run.started; digits = 2)))
            return nothing
        end
        if res.status === :completed
            finish!(run, res)
            return nothing
        end
        append_output!(run, res.partial)
    end
end

# Keep only the last `n` bytes of `v`.
keep_tail!(v::Vector{UInt8}, n::Int) = length(v) <= n ? v : deleteat!(v, 1:(length(v) - n))

function append_output!(run::EvalRun, text::AbstractString)
    isempty(text) && return nothing
    bytes = codeunits(text)
    @lock run.lock begin
        run.total_bytes += length(bytes)
        keep_tail!(append!(run.unseen, bytes), STDOUT_CAP_BYTES)
        keep_tail!(append!(run.tail, bytes), RUN_TAIL_BYTES)
        if run.log !== nothing && run.log_bytes < RUN_LOG_MAX_BYTES
            run.log_bytes += write(run.log, text)
            run.log_bytes >= RUN_LOG_MAX_BYTES &&
                write(run.log, "\n[log cut at $(RUN_LOG_MAX_BYTES) bytes]\n")
            flush(run.log)
        end
    end
    return nothing
end

# A byte tail cut mid-character starts with continuation bytes; skip them.
function utf8_string(bytes::AbstractVector{UInt8})
    s = String(copy(bytes))
    i = 1
    while i <= ncodeunits(s) && !isvalid(s, i)
        i += 1
    end
    return i == 1 ? s : String(SubString(s, i))
end

strip_ansi(s::AbstractString) = replace(s, r"\e\[[0-9;?]*[A-Za-z]" => "")

# The line a finished run is summed up by: a failure's first line, without the
# REPL's "ERROR: " (the status already says it failed) and without the
# "LoadError: " every error gets from the eval running the code as a file.
function failure_line(echo)
    echo === nothing && return ""
    for l in eachline(IOBuffer(strip_ansi(String(echo))))
        s = strip(l)
        isempty(s) || return String(replace(s, r"^ERROR:\s*(LoadError:\s*)?" => ""))
    end
    return ""
end

function finish!(run::EvalRun, res)
    append_output!(run, res.partial)
    failed = res.is_error || res.errored
    @lock run.lock begin
        run.result   = res
        run.finished = time()
        run.status   = !failed ? :passed : run.interrupt_requested ? :interrupted : :failed
        # A stop's first line is "InterruptException:", which says nothing the
        # status does not.
        run.summary  = run.status === :failed ? failure_line(res.echo) : ""
        if run.log !== nothing
            res.echo === nothing || write(run.log, "\n", strip_ansi(String(res.echo)), "\n")
            close(run.log)
            run.log = nothing
        end
    end
    notify(run.done)
    announce(run)
    return run
end

"Block until `run` finishes or `timeout` seconds pass (`nothing` = no bound). True when finished."
function wait_run(run::EvalRun, timeout::Union{Real,Nothing})
    timeout === nothing && (wait(run.done); return true)
    return timedwait(() -> !is_running(run), Float64(timeout); pollint = 0.05) === :ok
end

"""
    run_output!(run; max_bytes, full_output) -> String

Hand out what the agent has not seen of `run`'s output, and mark it seen. Cut to
the last `max_bytes` (unless `full_output`), saying where the rest is.
"""
function run_output!(run::EvalRun; max_bytes::Int, full_output::Bool)
    bytes = @lock run.lock (b = copy(run.unseen); empty!(run.unseen); b)
    limit = full_output ? STDOUT_CAP_BYTES : max_bytes
    length(bytes) <= limit && return utf8_string(bytes)
    dropped = length(bytes) - limit
    return "[output truncated: the first $(dropped) bytes are not shown — the whole " *
           "log is at $(run.log_path)]\n" * utf8_string(@view bytes[(dropped + 1):end])
end

"""
    collected_response(run; max_bytes, full_output, descriptor = true)

The tool result for a finished run, marking it collected. `descriptor = false`
leaves out the live-result descriptor (for `bt_julia_wait`, whose results the
agent reads; the run's own card in the chat shows the live result).
"""
function collected_response(run::EvalRun; max_bytes::Int = 10_000, full_output::Bool = false,
                            descriptor::Bool = true)
    res = run.result
    output = run_output!(run; max_bytes, full_output)
    res.echo === nothing || (output = isempty(output) ? res.echo : output * "\n" * res.echo)
    blocks = Dict{String,Any}[]
    isempty(output) || push!(blocks, Dict{String,Any}("type" => "text", "text" => output))
    append!(blocks, res.value_blocks)
    newly = @lock run.lock begin
        was = run.collected
        run.collected = true
        !was
    end
    newly && send_ctrl_frame(Dict("type" => "run_update", "run" => run.id, "collected" => true))
    return completed_response(blocks, descriptor ? res.html : nothing, res.is_error,
                              res.elapsed_s; run = run.id)
end

"The tool result for a run still going: its new output and what to do next."
running_response(run::EvalRun; max_bytes::Int = 10_000, full_output::Bool = false) =
    running_response(run.env_path, run_output!(run; max_bytes, full_output),
                     time() - run.started; run = run.id)

"The tool result of `bt_julia_eval(background = true)`."
function started_response(run::EvalRun)
    told = relay_grant() === nothing ? "" :
        " The chat tells you when it finishes, so you don't need to poll."
    text = "run $(run.id) started in env $(env_label(run.env_path)).$(told) " *
           "Wait for it with bt_julia_wait(runs = [\"$(run.id)\"]); see its output so far " *
           "with bt_julia_continue(run = \"$(run.id)\", timeout = 1)."
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
        "_meta"   => Dict{String,Any}("status" => "running", "run" => run.id, "background" => true),
    )
end

# The last non-empty output line.
function last_output_line(r::EvalRun)
    text = strip_ansi(@lock r.lock utf8_string(r.tail))
    for l in Iterators.reverse(split(text, '\n'))
        s = strip(l)
        isempty(s) || return String(first(s, 120))
    end
    return ""
end

# One line about a run, for listings and `bt_julia_wait`.
function run_line(r::EvalRun)
    @lock r.lock begin
        env = env_label(r.env_path)
        bg = r.background ? ", background" : ""
        if r.status === :running
            last = last_output_line(r)
            return "$(r.id)  running for $(elapsed_label(time() - r.started))  env=$(env)$(bg)" *
                   (isempty(last) ? "" : "  last output: $(repr(last))")
        end
        return "$(r.id)  $(r.status) after $(elapsed_label(r.finished - r.started))  env=$(env)$(bg)" *
               (isempty(r.summary) ? "" : " — $(r.summary)") *
               (r.collected ? "" : "  [result not collected]")
    end
end

"What the server and other processes are told about a run (plain data)."
function run_status(r::EvalRun)
    @lock r.lock Dict{String,Any}(
        "run" => r.id, "status" => String(r.status), "env_path" => r.env_path,
        "background" => r.background, "started" => r.started,
        "elapsed" => (r.status === :running ? time() : r.finished) - r.started,
        "summary" => r.summary, "collected" => r.collected, "log" => r.log_path,
        "line" => run_line(r))
end

# Tell the server where a run is: at its start, and when it ends (with the
# content the chat's card shows). Best effort — no server, no frame.
function announce(run::EvalRun)
    d = run_status(run)
    d["type"] = "run_update"
    d["route"] = stream_route(run.session)
    d["tool_use_id"] = run.tool_use_id
    is_running(run) || (d["content"] = card_content(run))
    send_ctrl_frame(d)
    return nothing
end

# Every run the chat should still show: running, or finished and not collected.
function announce_open_runs(reg::RunRegistry = SERVER.runs)
    open_runs = @lock reg.lock [r for r in values(reg.runs)
                                if is_running(r) || !(@lock r.lock r.collected)]
    foreach(announce, open_runs)
    return length(open_runs)
end

# The finished run as the chat's card shows it: the recent output and the
# result, the same shape as a completed eval's content.
function card_content(run::EvalRun)
    res = run.result
    output, dropped = @lock run.lock (utf8_string(run.tail), run.total_bytes - length(run.tail))
    dropped > 0 && (output = "[output truncated: the first $(dropped) bytes are not shown — the " *
                             "whole log is at $(run.log_path)]\n" * output)
    res.echo === nothing || (output = isempty(output) ? res.echo : output * "\n" * res.echo)
    blocks = Any[]
    isempty(output) || push!(blocks, Dict{String,Any}("type" => "text", "text" => output))
    append!(blocks, res.value_blocks)
    res.html === nothing || push!(blocks, Dict{String,Any}("type" => "text", "text" => res.html))
    return blocks
end

"""
    interrupt_run!(run) -> Bool

Ask `run`'s eval to stop (the same lever as `bt_julia_interrupt`). False when it
had already finished.
"""
function interrupt_run!(run::EvalRun)
    is_running(run) || return false
    @lock run.lock (run.interrupt_requested = true)
    request_interrupt!(run.session)
    return true
end
