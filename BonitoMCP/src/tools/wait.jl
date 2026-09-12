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
