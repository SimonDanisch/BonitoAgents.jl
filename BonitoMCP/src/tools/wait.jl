# bt_wait — the one way to make a turn actually stop and wait.
#
# The gap this fills, reported from a real session: an agent driving a 2–40
# minute job (Blender, Godot) has no way to WAIT for it.
#
#   * a foreground `sleep` is blocked by the harness,
#   * `Bash(run_in_background: true)` returns IMMEDIATELY — it starts work, it
#     does not wait for it, so the turn ends,
#   * the agent is re-invoked within seconds, sees the job still running, and
#     starts another sleeper to poll with.
#
# That loop produced 60–130 orphaned bash+sleep pairs in one session, each
# firing its own completion notification on expiry. The house rules told the
# agent how to START long work and never how to wait for it, so "poll from a
# fresh turn" was the only thing left.
#
# A TOOL CALL is the mechanism that pauses a turn: the agent blocks on the
# result. That is already why `bt_julia_eval` works for long Julia work. This is
# the same shape with nothing in it — no subprocess, no task-bar entry of its
# own, and no completion notification, because a tool result IS the completion.
#
# `seconds` is REQUIRED, including with `until`. An unbounded wait is a latch,
# and a latch on an event that may never come is the failure mode this codebase
# keeps deleting (see `REPORT_WAIT_SECONDS` in BonitoAgents). The bound is what
# makes this safe to hand an agent.

"How often `until` is re-checked when the caller doesn't say."
const WAIT_POLL_SECONDS = 5.0
# A ceiling on one call, so a fat-fingered `seconds` can't wedge a chat for a
# day. Long jobs are served by calling again — the agent gets a plain "not yet"
# and decides, which is one round trip per hour, not one per 8 seconds.
const WAIT_MAX_SECONDS = 3600.0

wait_result(text::AbstractString; is_error::Bool = false) = Dict{String,Any}(
    "content" => [Dict("type" => "text", "text" => String(text))],
    "isError" => is_error,
)

# Run `until` once. TRUE only on a clean exit(0) — the shell's own convention,
# so `test -f done.flag` / `pgrep -q blender || true` read the way they do in a
# terminal. A command that cannot even be launched is a caller error and is
# reported as one rather than being silently treated as "not yet", which would
# turn a typo into a full-length wait.
function wait_condition_met(cmd::AbstractString)
    try
        return success(pipeline(`bash -lc $cmd`; stdout = devnull, stderr = devnull))
    catch e
        e isa InterruptException && rethrow()
        throw(ArgumentError("could not run `until`: $(sprint(showerror, e))"))
    end
end

const WAIT_DESCRIPTION = """
Pause the current turn for a bounded time. This is the ONLY way to wait: it
blocks until it returns, so no further tool calls and no new turn happen in the
meantime.

Use it when you have started long work (a render, a build, a game export) and
need to be idle until it is done. Do NOT start a background `sleep` to poll
from the next turn — turns fire far faster than wall-clock, so that spawns one
orphaned sleeper per cycle, each firing its own notification.

  * `seconds` — how long to block. REQUIRED, capped at 3600. For work longer
    than that, call again; you are not penalised for waiting in one long call.
  * `until` — optional shell condition, re-checked every `poll` seconds. Returns
    as soon as it exits 0, so a job that finishes early does not cost the rest
    of the time. `seconds` still bounds it: hitting the bound is a normal
    result ("condition not met"), not an error.
  * `poll` — how often to re-check `until`. Default 5s.
  * `reason` — a short note on what is being waited for; it rides in the result
    so the transcript says why the gap is there.

Produces no background task, no task-bar entry and no notification — the result
you get back IS the completion.
"""

function wait_handler(args::AbstractDict)
    secs = get(args, "seconds", nothing)
    secs === nothing && return wait_result(
        "error: `seconds` is required — an unbounded wait is a latch, not a wait.";
        is_error = true)
    secs = Float64(secs)
    (isfinite(secs) && secs > 0) || return wait_result(
        "error: `seconds` must be a positive number, got $(secs)"; is_error = true)
    if secs > WAIT_MAX_SECONDS
        return wait_result(
            "error: `seconds` is capped at $(Int(WAIT_MAX_SECONDS)) (got $(secs)). " *
            "Call again to keep waiting."; is_error = true)
    end
    poll   = Float64(get(args, "poll", WAIT_POLL_SECONDS))
    poll > 0 || return wait_result("error: `poll` must be positive"; is_error = true)
    cond   = get(args, "until", nothing)
    reason = strip(String(get(args, "reason", "")))
    tail   = isempty(reason) ? "" : " ($reason)"

    t0 = time()
    if cond === nothing
        sleep(secs)
        return wait_result("waited $(round(time() - t0; digits = 1))s$tail")
    end

    cmd = String(cond)
    # Check FIRST: work that is already finished must not cost a poll interval.
    try
        if wait_condition_met(cmd)
            return wait_result("condition already true after " *
                               "$(round(time() - t0; digits = 1))s$tail: `$cmd`")
        end
        deadline = t0 + secs
        while time() < deadline
            sleep(min(poll, deadline - time()))
            if wait_condition_met(cmd)
                return wait_result("condition met after " *
                                   "$(round(time() - t0; digits = 1))s$tail: `$cmd`")
            end
        end
    catch e
        e isa InterruptException && rethrow()
        return wait_result("error: $(sprint(showerror, e))"; is_error = true)
    end
    # NOT an error: the caller asked for a bounded wait and got the bound. Say
    # plainly that the work is still running, so the obvious next step is to
    # wait again rather than to assume something broke.
    return wait_result("waited the full $(round(time() - t0; digits = 1))s$tail; " *
                       "condition still false: `$cmd`. The work is still running — " *
                       "call bt_wait again to keep waiting.")
end

register!(
    "bt_wait", WAIT_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "seconds" => Dict("type" => "number",
                "description" => "How long to block, in seconds. Required; capped at 3600."),
            "until" => Dict("type" => "string",
                "description" => "Optional shell condition; returns early as soon as it exits 0."),
            "poll" => Dict("type" => "number", "default" => WAIT_POLL_SECONDS,
                "description" => "How often to re-check `until`, in seconds. Default 5."),
            "reason" => Dict("type" => "string",
                "description" => "Short note on what is being waited for; echoed in the result."),
        ),
        "required" => ["seconds"],
    ),
    wait_handler,
)

# ── bt_julia_wait — block on runs ────────────────────────────────────────────
# The run-aware sibling of `bt_wait`: one blocking call for one or several
# Julia runs (runs.jl), here and on other workers, returning when any or all of
# them have finished. What it replaces is the agent calling `bt_julia_continue`
# on each worker in turn, one blocking call at a time, while the others' results
# sat uncollected.
#
# Local runs are checked in memory; runs on other workers are asked about
# through the server (the host's `runs` op), less often. A worker that cannot be
# reached ends that run's wait as `lost` rather than holding the call to its
# bound: the answer "I can't see it" is one the agent can act on.

const RUN_WAIT_LOCAL_POLL_S  = 0.2
const RUN_WAIT_REMOTE_POLL_S = 2.0

const JULIA_WAIT_DESCRIPTION = """
Block until Julia runs finish — the way to wait for `bt_julia_eval(background = true)`
runs, and for foreground evals that passed their checkpoint. One call covers runs
on this worker and on other workers.

  * `runs` — the run ids (`["r4", "r5"]`) from bt_julia_eval's results. Omit to
    wait on every run of this chat that is still running or whose result you
    have not collected yet.
  * `until` — "all" (default): return once every listed run has finished;
    "any": return as soon as one has.
  * `seconds` — REQUIRED bound, capped at 3600. Hitting it is a normal result
    (the still-running runs are listed); call again to keep waiting.
  * `max_response_bytes` — per finished run, how much of its output to return
    (the tail; the whole log's path is named when cut). Default 4000.

Returns one status line per run, then the result (output + value) of every run
that finished, which counts as collected.
"""

# Status of every run in `ids` as Dicts (`run_status`'s shape), local ones from
# memory and remote ones from their hosts.
function poll_runs(ids::Vector{String})
    reg = SERVER.runs
    out = Dict{String,Dict{String,Any}}()
    byworker = Dict{String,Vector{String}}()
    for id in ids
        r = @lock reg.lock get(reg.runs, id, nothing)
        if r !== nothing
            out[id] = run_status(r)
        else
            rr = remote_run(id)
            push!(get!(byworker, rr.worker, String[]), id)
        end
    end
    for (worker, wids) in byworker
        reply = try
            call_server("remote_eval"; timeout = 30.0, worker = worker, op = "runs",
                        args = Dict{String,Any}("runs" => wids))
        catch e
            e isa InterruptException && rethrow()
            e
        end
        for id in wids
            st = nothing
            if reply isa AbstractDict
                for d in get(reply, "runs", Any[])
                    get(d, "run", "") == id && (st = Dict{String,Any}(String(k) => v for (k, v) in d))
                end
            end
            if st === nothing
                why = reply isa Exception ? sprint(showerror, reply) : "its eval host no longer knows it"
                st = Dict{String,Any}("run" => id, "status" => "lost", "collected" => false,
                                      "line" => "$(id)  lost — $(why)")
            end
            st["worker"] = worker
            st["line"] = replace(String(st["line"]), r"^\S+" => "$(id)  on $(worker)")
            out[id] = st
        end
    end
    return out
end

finished_status(st::AbstractDict) = get(st, "status", "running") != "running"

# The runs a wait without `runs` means: everything still open in this chat.
function open_run_ids()
    reg = SERVER.runs
    locals = @lock reg.lock [r.id for r in values(reg.runs)
                             if is_running(r) || !(@lock r.lock r.collected)]
    remotes = @lock reg.lock collect(keys(reg.remote))
    isempty(remotes) && return locals
    st = poll_runs(remotes)
    append!(locals, [id for id in remotes
                     if get(st[id], "status", "") == "running" || get(st[id], "collected", true) === false])
    return locals
end

run_number(id::AbstractString) = something(tryparse(Int, id[2:end]), typemax(Int))

# A finished run's result for the wait's response: its content blocks, with the
# output text headed by the run id. Collects it (here, or through its host).
function collect_for_wait(id::String, st::AbstractDict, max_bytes::Int)
    get(st, "status", "") == "lost" && return Any[]
    reg = SERVER.runs
    r = @lock reg.lock get(reg.runs, id, nothing)
    res = if r !== nothing
        collected_response(r; max_bytes, descriptor = false)
    else
        remote_run_call("continue", id, remote_run(id),
                        Dict{String,Any}("run" => id, "timeout" => 5, "descriptor" => false,
                                         "max_response_bytes" => max_bytes); wait = 60.0)
    end
    blocks = Any[]
    head = "── $(id) ($(get(st, "status", "?"))) ──"
    texts = [b for b in get(res, "content", Any[]) if get(b, "type", "") == "text"]
    others = [b for b in get(res, "content", Any[]) if get(b, "type", "") != "text"]
    body = join((String(get(b, "text", "")) for b in texts), "\n")
    push!(blocks, Dict{String,Any}("type" => "text",
                                   "text" => isempty(body) ? "$(head)\n(no output)" : "$(head)\n$(body)"))
    append!(blocks, others)
    return blocks
end

function julia_wait_handler(args::AbstractDict)
    secs = get(args, "seconds", nothing)
    secs === nothing && return wait_result(
        "error: `seconds` is required — an unbounded wait is a latch, not a wait."; is_error = true)
    secs = Float64(secs)
    (isfinite(secs) && secs > 0) ||
        return wait_result("error: `seconds` must be a positive number, got $(secs)"; is_error = true)
    secs > WAIT_MAX_SECONDS && return wait_result(
        "error: `seconds` is capped at $(Int(WAIT_MAX_SECONDS)) (got $(secs)). Call again to keep waiting.";
        is_error = true)
    until = String(get(args, "until", "all"))
    until in ("all", "any") ||
        return wait_result("error: `until` is \"all\" or \"any\" (got $(repr(until)))"; is_error = true)
    max_bytes = Int(get(args, "max_response_bytes", 4_000))

    t0 = time()
    ids = let raw = get(args, "runs", nothing)
        raw isa AbstractVector && !isempty(raw) ? unique(String.(strip.(String.(raw)))) : open_run_ids()
    end
    isempty(ids) && return wait_result("no runs to wait for: nothing of this chat is running or uncollected.")
    reg = SERVER.runs
    unknown = [id for id in ids if (@lock reg.lock !haskey(reg.runs, id)) && remote_run(id) === nothing]
    isempty(unknown) || return wait_result(
        "error: no run named $(join(unknown, ", ")) in this chat. " *
        "bt_julia_list_sessions lists the runs."; is_error = true)
    sort!(ids; by = run_number)

    remote = any(id -> remote_run(id) !== nothing, ids)
    deadline = t0 + secs
    st = poll_runs(ids)
    done(st) = until == "any" ? any(finished_status, values(st)) : all(finished_status, values(st))
    while !done(st) && time() < deadline
        sleep(min(remote ? RUN_WAIT_REMOTE_POLL_S : RUN_WAIT_LOCAL_POLL_S, max(deadline - time(), 0.0)))
        st = poll_runs(ids)
    end

    waited = round(time() - t0; digits = 1)
    results = Any[]
    for id in ids
        finished_status(st[id]) || continue
        append!(results, collect_for_wait(id, st[id], max_bytes))
    end
    # The status lines AFTER collecting, so they don't call the runs this very
    # response hands over "not collected".
    any(id -> finished_status(st[id]), ids) && (st = poll_runs(ids))
    nfin = count(id -> finished_status(st[id]), ids)
    running = [id for id in ids if !finished_status(st[id])]
    head = "waited $(waited)s (until $(until)): $(nfin) of $(length(ids)) " *
           "run$(length(ids) == 1 ? "" : "s") finished" *
           (isempty(running) ? "." : "; still running: $(join(running, ", ")) — call bt_julia_wait again to keep waiting.")
    lines = [head; ["  " * String(st[id]["line"]) for id in ids]]
    content = Any[Dict{String,Any}("type" => "text", "text" => join(lines, "\n")); results]
    return Dict{String,Any}(
        "content" => content,
        "isError" => false,
        "_meta"   => Dict{String,Any}("runs" => Dict(id => String(get(st[id], "status", "?")) for id in ids)),
    )
end

register!(
    "bt_julia_wait", JULIA_WAIT_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "runs" => Dict("type" => "array", "items" => Dict("type" => "string"),
                "description" => "Run ids to wait for (e.g. [\"r4\", \"r5\"]); omit for every open run of this chat."),
            "until" => Dict("type" => "string", "enum" => ["all", "any"], "default" => "all",
                "description" => "\"all\": return when every run has finished; \"any\": when the first one has."),
            "seconds" => Dict("type" => "number",
                "description" => "How long to block at most, in seconds. Required; capped at 3600."),
            "max_response_bytes" => Dict("type" => "integer", "default" => 4000,
                "description" => "Per finished run: how much of its output to return (the tail)."),
        ),
        "required" => ["seconds"],
    ),
    julia_wait_handler,
)
