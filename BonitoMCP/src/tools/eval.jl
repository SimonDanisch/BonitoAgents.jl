# MCP tool registrations.
#
# Soft-timeout streaming model:
#   bt_julia_eval starts execution and returns within `timeout` seconds (or
#   when execution finishes, whichever is first). If still running, the
#   response carries the partial stdout captured so far + an explicit
#   `status: "running"` and `elapsed_s`. The agent then chooses:
#     - bt_julia_continue        wait another `timeout` seconds
#     - bt_julia_interrupt       SIGINT, capture output + InterruptException
#     - bt_julia_restart         SIGKILL the whole session (loses state)
#
# Default `timeout` is 30s. There is NO hard kill at timeout — that's the
# whole point. Lower `timeout` = tighter feedback on long jobs at the cost
# of more round-trips; higher = less polling overhead.

# ── Status helpers ──────────────────────────────────────────────────────────
# Wire contract v3 — content blocks are:
#   [output_text?, descriptor?]
# where output_text is ONE terminal-faithful text (stdout/stderr as captured,
# then the result repr or red ERROR text, REPL-style; agent-facing — the chat
# shows the LIVE stream while running and only falls back to this block for
# history) and descriptor is `{"remote_ref": "...", "errored": bool}` whenever
# a ref was parked (values AND errors — a CapturedException is a value). No
# code echo (agent has its tool input, chat has the typed `code` field), no
# in-band labels, nothing to sniff. A checkpoint (still running) has no
# descriptor; its footer rides inside the output text. `_meta.run` names the
# run (runs.jl) a response is about.
function running_response(env_path::Union{String,Nothing},
                          partial::AbstractString, elapsed::Real;
                          run::Union{String,Nothing} = nothing)
    footer = string(
        "\n--- still running", run === nothing ? "" : " as $run",
        " (", round(elapsed; digits = 2), "s",
        env_path === nothing ? "" : ", env=$env_path", ")",
        " — next: ", run === nothing ? "" : "bt_julia_wait(runs = [\"$run\"]) / ",
        "bt_julia_continue / bt_julia_interrupt / bt_julia_restart")
    output = (isempty(partial) ? "(no output captured yet)" : partial) * footer
    meta = Dict{String,Any}("status" => "running", "elapsed_s" => elapsed)
    run === nothing || (meta["run"] = run)
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => output)],
        "isError" => false,
        "_meta"   => meta,
    )
end

# `html` is the result DESCRIPTOR json (nothing outside a chat bridge, or for
# a `nothing` result / checkpoint). Appended as the FINAL content block; the
# chat identifies it by exact decode of its own format. `is_error` is the MCP
# isError = INFRASTRUCTURE failures only — user errors ship a descriptor with
# `errored: true` instead (claude fuses isError content into one rawOutput
# string, which must never happen to a plain user error).
function completed_response(blocks, html, is_error::Bool, elapsed::Real;
                            run::Union{String,Nothing} = nothing)
    content = copy(blocks)
    html === nothing ||
        push!(content, Dict{String,Any}("type" => "text", "text" => html))
    meta = Dict{String,Any}("status" => "completed", "elapsed_s" => elapsed)
    run === nothing || (meta["run"] = run)
    return Dict{String,Any}(
        "content" => content,
        "isError" => is_error,
        "_meta"   => meta,
    )
end

# ── Running on another worker ───────────────────────────────────────────────
# `worker = "<name>"` on any eval-family tool sends the call through the
# BonitoAgents server to an EVAL HOST on that worker (eval_host.jl) — the same
# BonitoMCP, serving this chat from the other machine. The server owns the rules:
# the chat's "remote julia" switch (off by default), which worker names exist,
# spawning the host on first use. This side only forwards the call and hands
# the host's tool result back verbatim, so the agent sees exactly what a local
# eval would have shown.

tool_error(msg::AbstractString) =
    Dict{String,Any}("content" => [Dict("type" => "text", "text" => "error: " * msg)],
                     "isError" => true)

# The `worker` argument, or nothing when the call is for this worker.
function remote_worker(args::AbstractDict)
    w = get(args, "worker", nothing)
    w isa AbstractString || return nothing
    s = strip(w)
    return isempty(s) ? nothing : String(s)
end

# The `run` argument (`"r4"`), or nothing.
function run_arg(args::AbstractDict)
    r = get(args, "run", nothing)
    r isa AbstractString || return nothing
    s = strip(r)
    return isempty(s) ? nothing : String(s)
end

# The env a call names, or nothing for the temp session.
function env_arg(args::AbstractDict)
    e = get(args, "env_path", nothing)
    return e isa AbstractString && !isempty(e) ? String(e) : nothing
end

# The id Claude Code gave this tool call (server.jl copies it into the
# arguments), "" from any other client.
tool_use_id(args::AbstractDict) = String(get(args, "_tool_use_id", ""))

# How long to wait for the server's reply: the eval's own soft checkpoint plus
# room for the host to be spawned on first use (a julia start + `using BonitoMCP`
# + the eval worker's own start). A checkpoint-free eval (`timeout = 0`, or a
# `Pkg.*` call) may legitimately run for a long time.
const REMOTE_SPAWN_GRACE_S = 180.0
const REMOTE_UNBOUNDED_S   = 6 * 3600.0
remote_wait(timeout::Union{Real,Nothing}) =
    timeout === nothing ? REMOTE_UNBOUNDED_S : Float64(timeout) + REMOTE_SPAWN_GRACE_S

# Forward one tool call to `worker`'s eval host. `track` names a FOREGROUND run
# the call waits on, so a cancel arriving meanwhile can stop it
# (`interrupt_remote_inflight!`); background runs are never tracked.
function remote_tool_call(op::AbstractString, worker::AbstractString, args::AbstractDict;
                          wait::Real, track::Union{String,Nothing} = nothing)
    fwd = Dict{String,Any}(String(k) => v for (k, v) in args if String(k) != "worker")
    key = (String(worker), something(track, ""))
    track === nothing || @lock SERVER.inflight_lock push!(SERVER.remote_inflight, key)
    reply = try
        call_server("remote_eval"; timeout = wait, worker = worker, op = op, args = fwd)
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror, e))
    finally
        track === nothing || @lock SERVER.inflight_lock delete!(SERVER.remote_inflight, key)
    end
    reply isa AbstractDict ||
        return tool_error("unexpected reply from the server for a remote '$(op)': $(repr(reply))")
    return Dict{String,Any}(String(k) => v for (k, v) in reply)
end

# A cancel (`notifications/cancelled`) reaches the foreground runs this chat has
# going on other workers through the server. Best-effort and asynchronous: the
# cancel path must not wait on a round trip per remote run.
function interrupt_remote_inflight!()
    targets = @lock SERVER.inflight_lock collect(SERVER.remote_inflight)
    for (worker, run) in targets
        isempty(run) && continue
        Base.errormonitor(@async try
            call_server("remote_eval"; timeout = 30.0, worker = worker, op = "interrupt",
                        args = Dict{String,Any}("run" => run))
        catch e
            e isa InterruptException && rethrow()
            log_info("cancel: remote interrupt of $(run) on '$(worker)' failed: $(sprint(showerror, e))")
        end)
    end
    return length(targets)
end

# The run `id` lives on another worker: where, or nothing.
remote_run(id::AbstractString) = @lock SERVER.runs.lock get(SERVER.runs.remote, String(id), nothing)

# The run this chat has on `worker` in `env_path` (for calls that name the env
# instead of the run), or nothing.
function remote_run_in(worker::AbstractString, env_path::Union{String,Nothing})
    @lock SERVER.runs.lock begin
        best = nothing
        for (id, r) in SERVER.runs.remote
            r.worker == worker && r.env_path == env_path || continue
            (best === nothing || parse(Int, id[2:end]) > parse(Int, best[2:end])) && (best = id)
        end
        return best
    end
end

# Start an eval on another worker as a run with an id from HERE, so the ids of
# one chat never collide across its workers. A host that refuses (a busy env,
# a switched-off chat) leaves no run behind.
function remote_eval_start(worker::String, args::AbstractDict, code::AbstractString,
                           user_to, background::Bool)
    reg = SERVER.runs
    id = new_run_id!(reg)
    env_path = env_arg(args)
    @lock reg.lock (reg.remote[id] = RemoteRun(worker, env_path, background))
    fwd = Dict{String,Any}(String(k) => v for (k, v) in args)
    fwd["run_id"] = id
    r = remote_tool_call("eval", worker, fwd;
        wait = background ? REMOTE_SPAWN_GRACE_S : remote_wait(effective_timeout(code, user_to)),
        track = background ? nothing : id)
    meta = get(r, "_meta", nothing)
    started = meta isa AbstractDict && get(meta, "run", nothing) == id
    started || @lock reg.lock delete!(reg.remote, id)
    return r
end

# Forward a call about a remote run (`continue` / `interrupt`) to its host.
remote_run_call(op, id, r::RemoteRun, args; wait) =
    remote_tool_call(op, r.worker, Dict{String,Any}(String(k) => v for (k, v) in args if String(k) != "worker");
                     wait, track = (op == "continue" && !r.background) ? id : nothing)

max_bytes_arg(args) = Int(get(args, "max_response_bytes", 10_000))
full_output_arg(args) = get(args, "full_output", false) === true

# A finished run as the eval tool returns it: the collected result, plus the
# Bonito upgrade card when a DISPLAY value came back as text because this env's
# Bonito is too old for the live bridge (`s.bonito_mismatch`). Plain-text evals
# never carry `wants_display`, so a `println` on a mismatched env won't nag.
function eval_response(run::EvalRun; max_bytes::Int, full_output::Bool, descriptor::Bool = true)
    r = collected_response(run; max_bytes, full_output, descriptor)
    s = run.session
    if run.result.wants_display && !isempty(s.bonito_mismatch)
        pushfirst!(r["content"], bonito_upgrade_block(s.bonito_mismatch, s.env_path))
    end
    return r
end

# Wait for a run up to `timeout`; its result when it finished, else a checkpoint.
function await_run_response(run::EvalRun, timeout; max_bytes::Int, full_output::Bool,
                            descriptor::Bool = true)
    wait_run(run, timeout) || return running_response(run; max_bytes, full_output)
    return eval_response(run; max_bytes, full_output, descriptor)
end

# ── Handlers ────────────────────────────────────────────────────────────────
function julia_eval_handler(args::AbstractDict)
    code        = String(get(args, "code", ""))
    env_path    = env_arg(args)
    julia_cmd   = get(args, "julia_cmd", nothing)
    user_to     = get(args, "timeout", nothing)
    full_output = full_output_arg(args)
    max_bytes   = max_bytes_arg(args)
    background  = get(args, "background", false) === true

    isempty(strip(code)) && return tool_error("empty code")

    worker = remote_worker(args)
    worker === nothing || return remote_eval_start(worker, args, code, user_to, background)

    s = try
        get_or_create!(manager(), env_path; julia_cmd)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text",
                                "text" => "error starting session: $(sprint(showerror, e))")],
            "isError" => true,
        )
    end

    # A busy env refuses at once. Checked BEFORE the bridge below: that takes
    # the session lock, which the running run's collector holds slice after
    # slice, so the call used to wait out the whole run instead of saying why.
    reg = SERVER.runs
    busy = running_run(reg, s)
    busy === nothing || return tool_error(sprint(showerror, RunBusy(busy)))

    # Bring up the proxy bridge so `format_value` can render the result to an
    # HTML fragment on the worker (loads RemoteProxy worker-side + dials back to
    # the BonitoAgents server). Best-effort: standalone MCP (no server) or a
    # pre-v5 Bonito env just leaves the bridge down → the eval still returns its
    # text/file result, only without the live render.
    try
        ensure_eval_dialed!(s)
    catch e
        @debug "bt_julia_eval: eval bridge unavailable; result will render text-only" exception = e
    end

    given = get(args, "run_id", nothing)      # set when this process hosts another worker's chat
    id = given isa AbstractString && !isempty(given) ? String(given) : new_run_id!(reg)
    run = try
        start_run!(reg, s, code; id, env_path, background, tool_use_id = tool_use_id(args),
                   max_bytes, full_output)
    catch e
        e isa RunBusy && return tool_error(sprint(showerror, e))
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end
    background && return started_response(run)
    return await_run_response(run, effective_timeout(code, user_to); max_bytes, full_output)
end

# The upgrade-card marker the chat decodes (`bonito_upgrade_descriptor` in
# BonitoAgents remote_app.jl): a value wanted a live display but the project env's
# Bonito is too old. Carries current/needed versions + the `Pkg.add` the [Update
# env] button runs. Bonito's live-render fixes aren't released, so the add pins
# the git branch (works without a release).
const BONITO_UPGRADE_URL = "https://github.com/SimonDanisch/Bonito.jl"
const BONITO_UPGRADE_REV = "sd/media-proxy"
function bonito_upgrade_block(current::AbstractString, env_path)
    add = "Pkg.add(url=\"$(BONITO_UPGRADE_URL)\", rev=\"$(BONITO_UPGRADE_REV)\")"
    e(x) = json_escape_string(string(x))
    j = string("{\"bonito_upgrade\":{",
               "\"current\":\"", e(current), "\",",
               "\"need\":\"",    e(MIN_BRIDGE_BONITO), "\",",
               "\"env\":\"",     e(env_path === nothing ? "" : env_path), "\",",
               "\"add\":\"",     e(add), "\"}}")
    return Dict{String,Any}("type" => "text", "text" => j)
end

# The run a continue/interrupt without `run` means: the open run of the named
# env's session here. Throws when there is none.
function env_run(env_path::Union{String,Nothing})
    s = lookup_session(manager(), env_path)
    r = open_run(SERVER.runs, s)
    r === nothing && error("No eval in flight on this session ($(env_label(env_path))).")
    return r
end

function julia_continue_handler(args::AbstractDict)
    user_to     = get(args, "timeout", nothing)
    timeout     = user_to === nothing ? DEFAULT_TIMEOUT : (user_to > 0 ? user_to : nothing)
    max_bytes   = max_bytes_arg(args)
    full_output = full_output_arg(args)
    id = run_arg(args)
    if id !== nothing
        r = remote_run(id)
        r === nothing || return remote_run_call("continue", id, r, args; wait = remote_wait(timeout))
    else
        worker = remote_worker(args)
        if worker !== nothing
            rid = remote_run_in(worker, env_arg(args))
            fg = rid === nothing ? nothing : (remote_run(rid).background ? nothing : rid)
            return remote_tool_call("continue", worker, args; wait = remote_wait(timeout), track = fg)
        end
    end
    # Pure lookups — never get_or_create! (which would kill+replace the session
    # holding the in-flight eval; M5).
    run = try
        id === nothing ? env_run(env_arg(args)) : lookup_run(SERVER.runs, id)
    catch e
        e isa InterruptException && rethrow()
        return Dict{String,Any}("content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
                                "isError" => true)
    end
    # `descriptor = false` comes from `bt_julia_wait` collecting a remote run.
    return await_run_response(run, timeout; max_bytes, full_output,
                              descriptor = get(args, "descriptor", true) !== false)
end

function julia_interrupt_handler(args::AbstractDict)
    max_bytes   = max_bytes_arg(args)
    full_output = full_output_arg(args)
    id = run_arg(args)
    if id !== nothing
        r = remote_run(id)
        r === nothing || return remote_run_call("interrupt", id, r, args; wait = 90.0)
    else
        worker = remote_worker(args)
        worker === nothing || return remote_tool_call("interrupt", worker, args; wait = 90.0)
    end
    # Pure lookups — never get_or_create! (M5). Interrupting requires the EXISTING
    # session that owns the in-flight eval, not a freshly created replacement.
    run = try
        id === nothing ? env_run(env_arg(args)) : lookup_run(SERVER.runs, id)
    catch e
        e isa InterruptException && rethrow()
        return Dict{String,Any}("content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
                                "isError" => true)
    end
    # Generous: the user's code might be in a try/catch that swallows the
    # InterruptException for a while, but should yield within 30s.
    interrupt_run!(run)
    return await_run_response(run, 30.0; max_bytes, full_output)
end

function julia_restart_handler(args::AbstractDict)
    env_path = env_arg(args)
    worker = remote_worker(args)
    worker === nothing ||
        return remote_tool_call("restart", worker, args; wait = 120.0)
    # A run going in this session ends with it; it was stopped, not broken.
    s = @lock manager().lock get(manager().sessions, _key(env_path), nothing)
    r = s === nothing ? nothing : running_run(SERVER.runs, s)
    r === nothing || @lock r.lock (r.interrupt_requested = true)
    restart!(manager(), env_path)
    label = env_path === nothing ? "<temp>" : env_path
    return Dict{String,Any}(
        "content" => [Dict("type" => "text",
                            "text" => "Session for $label cleared. Next call rebuilds it." *
                                      (r === nothing ? "" : " Run $(r.id) was stopped with it."))],
        "isError" => false,
    )
end

# The runs this process knows, for listings: running and uncollected ones in
# full, the collected ones as a count.
function runs_text(reg::RunRegistry = SERVER.runs)
    runs = @lock reg.lock sort!(collect(values(reg.runs)); by = r -> r.started)
    open_runs = [r for r in runs if is_running(r) || !(@lock r.lock r.collected)]
    remote = @lock reg.lock sort!(collect(reg.remote); by = p -> parse(Int, p.first[2:end]))
    lines = String[]
    isempty(open_runs) || push!(lines, "runs:")
    append!(lines, "  " * run_line(r) for r in open_runs)
    ndone = length(runs) - length(open_runs)
    ndone > 0 && push!(lines, "  ($(ndone) earlier run$(ndone == 1 ? "" : "s") collected)")
    if !isempty(remote)
        push!(lines, "runs started from here on other workers (bt_julia_wait / bt_julia_continue(run = …) reach them):")
        append!(lines, "  $(id)  on $(r.worker)  env=$(env_label(r.env_path))$(r.background ? ", background" : "")"
                       for (id, r) in remote)
    end
    return join(lines, "\n")
end

function julia_list_sessions_handler(args::AbstractDict)
    worker = remote_worker(args)
    worker === nothing ||
        return remote_tool_call("sessions", worker, args; wait = 60.0)
    sessions = list_sessions(manager())
    text = if isempty(sessions)
        "no active sessions"
    else
        lines = String["active sessions:"]
        for s in sessions
            extras = String[]
            s.julia_cmd === nothing || push!(extras, "julia_cmd=$(s.julia_cmd)")
            s.temp                  && push!(extras, "temp")
            s.alive                 || push!(extras, "DEAD")
            s.in_flight             && push!(extras, "EVAL IN FLIGHT")
            tail = isempty(extras) ? "" : "  [" * join(extras, ", ") * "]"
            label = s.env_path === nothing ? "<temp>" : s.env_path
            push!(lines, "  - $label$tail")
        end
        join(lines, "\n")
    end
    rt = runs_text()
    isempty(rt) || (text *= "\n\n" * rt)
    # Under BonitoAgents, also say which OTHER workers this chat could run on
    # (and what already runs there). Best-effort: standalone BonitoMCP has no
    # server to ask, and an eval host that doesn't answer must not fail the
    # listing of the local sessions.
    if SERVER.control.task !== nothing && isempty(host_worker_id())
        text *= "\n\n" * remote_workers_text()
    end
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => false,
    )
end

# An eval host's answer to `runs`: the status of the named runs (all of them
# when none are named), as data — `bt_julia_wait` on the chat's own worker polls
# its remote runs with it.
function julia_runs_handler(args::AbstractDict)
    reg = SERVER.runs
    ids = get(args, "runs", nothing)
    wanted = ids isa AbstractVector && !isempty(ids) ? String.(ids) :
             @lock reg.lock collect(keys(reg.runs))
    found = Any[]; unknown = String[]
    for id in wanted
        r = @lock reg.lock get(reg.runs, id, nothing)
        r === nothing ? push!(unknown, id) : push!(found, run_status(r))
    end
    return Dict{String,Any}("runs" => found, "unknown" => unknown)
end

function remote_workers_text()
    reply = try
        call_server("remote_workers"; timeout = 30.0)
    catch e
        e isa InterruptException && rethrow()
        return "other workers: (could not ask the server: $(sprint(showerror, e)))"
    end
    reply isa AbstractDict || return "other workers: (unexpected reply)"
    enabled = get(reply, "enabled", false) === true
    workers = get(reply, "workers", Any[])
    lines = String[enabled ?
        "other workers (pass `worker = \"<name>\"` to run there; remote julia is ON for this chat):" :
        "other workers (remote julia is OFF for this chat — the user can switch it on in the chat header, next to the permissions pill):"]
    isempty(workers) && push!(lines, "  (none online)")
    for w in workers
        w isa AbstractDict || continue
        tag = String[]
        get(w, "host_live", false) === true && push!(tag, "eval host running")
        haskey(w, "error") && push!(tag, "its host did not answer: " * String(w["error"]))
        push!(lines, "  - $(get(w, "name", "?")) ($(get(w, "hostname", "?")), projects under $(get(w, "projects_root", "?")))" *
                     (isempty(tag) ? "" : "  [" * join(tag, ", ") * "]"))
        for s in get(w, "sessions", Any[])
            s isa AbstractDict || continue
            push!(lines, "      session $(get(s, "env_path", "<temp>"))" *
                         (get(s, "in_flight", false) === true ? "  [EVAL IN FLIGHT]" : ""))
        end
        for r in get(w, "runs", Any[])
            r isa AbstractDict || continue
            push!(lines, "      " * String(get(r, "line", get(r, "run", "?"))))
        end
    end
    return join(lines, "\n")
end

# ── bt_sync_folder ──────────────────────────────────────────────────────────
# Copy a folder from this worker to another one, through the server (the two
# workers never talk directly). What makes "run it on the MacBook" practical:
# the code, its Project.toml/Manifest.toml, and the data have to be there first.
function sync_folder_handler(args::AbstractDict)
    src    = String(strip(String(get(args, "src", ""))))
    worker = remote_worker(args)
    dst    = get(args, "dst", nothing)
    isempty(src) && return tool_error("`src` (a folder on this worker) is required")
    worker === nothing && return tool_error("`worker` (the worker to copy to) is required")
    dst_s = dst isa AbstractString && !isempty(strip(dst)) ? String(strip(dst)) : src
    reply = try
        call_server("sync_folder"; timeout = 6 * 3600.0, worker = worker, src = src, dst = dst_s)
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror, e))
    end
    reply isa AbstractDict || return tool_error("unexpected reply from the server: $(repr(reply))")
    return Dict{String,Any}(
        "content" => [Dict("type" => "text",
            "text" => "synced $(get(reply, "files", "?")) files ($(get(reply, "bytes", "?")) bytes) " *
                      "from $(src) on this worker to $(dst_s) on $(get(reply, "worker", worker))" *
                      (get(reply, "deleted", 0) == 0 ? "" : "; removed $(reply["deleted"]) stale files there"))],
        "isError" => false,
    )
end

# ── Registration ────────────────────────────────────────────────────────────
const EVAL_DESCRIPTION = """
Evaluate Julia code in a persistent per-`env_path` session. ALWAYS prefer this
over `julia -e` via Bash for Julia work — Bash spawns a fresh process every
time so `using Foo`, loaded variables, and compiled methods don't carry over,
and you pay full startup cost on each call.

Each `env_path` runs in its own Julia subprocess (managed via Malt.jl);
state (top-level bindings, modules, function defs) carries over across
calls. Revise.jl is loaded IF the env can see it (the project, or the user's
global env) so source edits to packages are picked up without restart — it is
never installed for you. If your edits don't take effect, check
`isdefined(Main, :Revise)`, and if it is false ask the user to add Revise to
their global env rather than editing the project's. If the env path ends in
`/test`, TestEnv is auto-activated so the parent project's test deps are
visible.

Displaying apps & plots:
  - The return value (the last expression) is rendered in the chat. A Bonito
    `App`, a WGLMakie `Figure`/plot, an image, a DataFrame or HTML renders as a
    live result; widgets and plots stay connected to this session, so the user
    can drive them. To show a plot or a UI, return it.
      using WGLMakie
      App() do
          s = Bonito.Slider(1:10)
          xs = 0:0.05:2π
          fig = Figure(); lines!(Axis(fig[1,1]), xs, map(v -> sin.(v .* xs), s.value))
          DOM.div(s, fig)
      end
  - Use WGLMakie (renders in the browser over the bridge), not GLMakie/CairoMakie.
  - A rendered app/plot reports "⟨interactive plot displayed live in the chat⟩"
    in place of the value repr; that is the confirmation, no screenshot needed.
  - Don't call `display`, `Page`, or `Bonito.Server` — the session is already
    wired to the chat; return the value instead.

Runs and the streaming model — IMPORTANT:
  - Every eval is a RUN with a short id (`r4`), named in the result.
  - `timeout` is a **soft** checkpoint, not a hard kill. The call returns
    within `timeout` seconds with either:
      • status="completed" — full result blocks; OR
      • status="running"   — the run goes on; the response contains the
        output so far and the run id, so you can decide what to do.
  - When you see status="running", choose one:
      • bt_julia_wait(runs = ["r4"], seconds = …) (block until it finishes)
      • bt_julia_continue(run = "r4") (wait another `timeout` seconds)
      • bt_julia_interrupt(run = "r4") (captures output + InterruptException;
        session state preserved)
      • bt_julia_restart (SIGKILL — loses all session state)
  - Default 30s; auto-disabled (no checkpointing) when the code uses
    `Pkg.*` since installs are routinely multi-minute. Pass `timeout=0`
    to disable the checkpoint entirely.

Background runs (long work, several machines at once):
  - `background = true` returns at once with the run id; the run goes on.
    Start a test suite on each worker this way, then wait for all of them
    with ONE `bt_julia_wait(runs = [...], seconds = …)` call.
  - Under BonitoAgents the chat tells you when a background run you have not
    collected finishes, so there is no need to poll. A cancelled turn leaves
    background runs running; stop one with bt_julia_interrupt(run = …).
  - One run per env at a time: a second eval in an env whose run is still
    going is refused and names that run.

Output:
  - Captured stdout/stderr followed by the return value's repr (or the error),
    exactly as a REPL would show it — one terminal-faithful text block. The
    code is NOT echoed back (you already have it as the tool input).
  - `nothing` returns are suppressed (don't waste tokens on it; if you
    need a value, return it explicitly as the last expression).
  - Output is auto-truncated at `max_response_bytes` (default 10000).
    Large arrays / dicts are summarised.
  - A 2-D color array (any colorspace: RGB, Gray, RGBA, HSV, …) also comes back
    as a `shown: <path>.png` reference — open that file to look at the image.
    Nothing needs to be installed in the eval env for this.
  - Backtraces are trimmed to user-relevant frames.

Running on ANOTHER worker (machine):
  - Pass `worker = "<name>"` to run the code on that worker instead of this one.
    Sessions there are separate (own `env_path`s, own state); `bt_julia_continue`,
    `bt_julia_interrupt`, `bt_julia_restart` and `bt_julia_list_sessions` take
    the same `worker` argument to address them. `bt_julia_list_sessions` (no
    arguments) lists the workers you can use.
  - This is OFF by default: the user switches "remote julia" on per chat, in the
    chat header next to the permissions pill. While it is off, a call with
    `worker` errors and says so — ask the user rather than retrying.
  - The other machine has its own filesystem: copy code, its Project.toml /
    Manifest.toml and data there first with `bt_sync_folder`, and pass an
    `env_path` that exists THERE.
  - Julia VALUES move between this chat's session and one there from inside
    the code, with `remote_session` (defined in every session):
      r = remote_session("MacBook"; env_path = "/Users/me/proj")  # the session bt_julia_eval(worker = "MacBook", env_path = …) runs in
      r[:data] = data          # send: `data` is set there
      model = r[:model]        # fetch its `model`
      y = r(f, x; k = 1)       # run f(x; k = 1) there, the value comes back
    Any size. They travel with Serialization, so both sessions need the same
    Julia version (checked, with an error saying so) and the packages behind
    the value's types loaded. A function passed to `r(…)` uses the OTHER
    session's globals; pass local values as arguments. An anonymous function
    sent that way cannot take keyword arguments (pass keywords to a named one).
"""

register!(
    "bt_julia_eval", EVAL_DESCRIPTION,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "code"               => Dict("type"=>"string", "description"=>"Julia code to evaluate"),
            "env_path"           => Dict("type"=>"string", "description"=>"Optional Julia project directory; omit for a temp env"),
            "timeout"            => Dict("type"=>"number", "description"=>"Soft checkpoint cadence in seconds. Default 30; auto-disabled for Pkg.*; pass 0 to disable."),
            "julia_cmd"          => Dict("type"=>"string", "description"=>"Custom Julia invocation, e.g. `julia +1.11` or `julia --check-bounds=yes`. Use rarely."),
            "full_output"        => Dict("type"=>"boolean", "default"=>false, "description"=>"Disable output truncation/summarisation"),
            "max_response_bytes" => Dict("type"=>"integer", "default"=>10_000, "description"=>"Per-block byte cap"),
            "worker"             => Dict("type"=>"string", "description"=>"Run on this OTHER worker (its display name) instead of the chat's own. Needs the chat's 'remote julia' switch; see bt_julia_list_sessions for the names."),
            "background"         => Dict("type"=>"boolean", "default"=>false, "description"=>"Return at once with the run id and let the run go on; collect it with bt_julia_wait."),
        ),
        "required" => ["code"],
    ),
    julia_eval_handler,
)

const WORKER_ARG = Dict("type"=>"string", "description"=>"Address the session on this other worker (display name) instead of the chat's own")

register!(
    "bt_julia_continue",
    """
    Continue waiting for a run (a bt_julia_eval still going): returns its new
    output and, once it finished, its result — the same shape as bt_julia_eval.
    Name it with `run` (e.g. "r4", from bt_julia_eval's result; reaches runs on
    other workers too), or with `env_path` (+ `worker`) for the run in that
    session. Pass `timeout` to set how long this checkpoint waits. To wait for
    several runs at once, use bt_julia_wait.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "run"      => Dict("type"=>"string", "description"=>"The run to continue, e.g. \"r4\""),
            "env_path" => Dict("type"=>"string", "description"=>"Session to continue when no `run` is given; omit for temp"),
            "timeout"  => Dict("type"=>"number", "description"=>"Checkpoint timeout in seconds. Default 30; pass 0 to disable."),
            "worker"   => WORKER_ARG,
        ),
    ),
    julia_continue_handler,
)

register!(
    "bt_julia_interrupt",
    """
    Stop a run (a bt_julia_eval still going). The user code raises
    InterruptException; the session subprocess and all state survive. Returns
    the output so far + the interrupt error block. Use this when you want to
    stop a runaway computation but keep the loaded packages/variables. Name it
    with `run` (e.g. "r4"), or with `env_path` (+ `worker`).
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "run"      => Dict("type"=>"string", "description"=>"The run to stop, e.g. \"r4\""),
            "env_path" => Dict("type"=>"string", "description"=>"Session to interrupt when no `run` is given; omit for temp"),
            "worker"   => WORKER_ARG,
        ),
    ),
    julia_interrupt_handler,
)

register!(
    "bt_julia_restart",
    """
    Restart a Julia session, clearing all state. SIGKILL — lose everything in
    the session. Slow (subprocess restart + reloading packages). Revise.jl is
    auto-loaded so source edits to packages are picked up without restart;
    only restart for state corruption or struct field changes Revise can't fix.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "env_path" => Dict("type"=>"string", "description"=>"Project to restart; omit for the temp session"),
            "worker"   => WORKER_ARG,
        ),
    ),
    julia_restart_handler,
)

register!(
    "bt_julia_list_sessions",
    "List currently active per-`env_path` Julia sessions (marks any with an in-flight eval), " *
    "the runs of this chat (running, and finished ones whose result you have not collected), " *
    "and the OTHER workers this chat could run Julia on with `worker = \"<name>\"`.",
    Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}(
        "worker" => Dict("type"=>"string", "description"=>"List the sessions on this other worker instead"))),
    julia_list_sessions_handler,
)

register!(
    "bt_sync_folder",
    """
    Copy a folder from this worker to ANOTHER worker (through the BonitoAgents
    server; the two machines never talk directly). Use it before running Julia
    on that worker with `bt_julia_eval(worker = …)`: a project (its code,
    Project.toml and Manifest.toml) and the data it needs have to be there.
    Re-running only transfers what changed; files that vanished at `src` are
    removed at `dst`. Needs the chat's 'remote julia' switch, like remote evals.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "src"    => Dict("type"=>"string", "description"=>"Folder on THIS worker (absolute path)"),
            "worker" => Dict("type"=>"string", "description"=>"The worker to copy to (display name)"),
            "dst"    => Dict("type"=>"string", "description"=>"Folder on that worker; default: the same path as `src`"),
        ),
        "required" => ["src", "worker"],
    ),
    sync_folder_handler,
)
