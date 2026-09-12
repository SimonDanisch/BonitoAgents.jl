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
# descriptor; its footer rides inside the output text.
function running_response(env_path::Union{String,Nothing},
                          partial::AbstractString, elapsed::Real)
    footer = string(
        "\n--- still running (", round(elapsed; digits = 2), "s",
        env_path === nothing ? "" : ", env=$env_path", ")",
        " — next: bt_julia_continue / bt_julia_interrupt / bt_julia_restart")
    output = (isempty(partial) ? "(no output captured yet)" : partial) * footer
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => output)],
        "isError" => false,
        "_meta"   => Dict("status" => "running", "elapsed_s" => elapsed),
    )
end

# `html` is the result DESCRIPTOR json (nothing outside a chat bridge, or for
# a `nothing` result / checkpoint). Appended as the FINAL content block; the
# chat identifies it by exact decode of its own format. `is_error` is the MCP
# isError = INFRASTRUCTURE failures only — user errors ship a descriptor with
# `errored: true` instead (claude fuses isError content into one rawOutput
# string, which must never happen to a plain user error).
function completed_response(blocks, html, is_error::Bool, elapsed::Real)
    content = copy(blocks)
    html === nothing ||
        push!(content, Dict{String,Any}("type" => "text", "text" => html))
    return Dict{String,Any}(
        "content" => content,
        "isError" => is_error,
        "_meta"   => Dict("status" => "completed", "elapsed_s" => elapsed),
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

# How long to wait for the server's reply: the eval's own soft checkpoint plus
# room for the host to be spawned on first use (a julia start + `using BonitoMCP`
# + the eval worker's own start). A checkpoint-free eval (`timeout = 0`, or a
# `Pkg.*` call) may legitimately run for a long time.
const REMOTE_SPAWN_GRACE_S = 180.0
const REMOTE_UNBOUNDED_S   = 6 * 3600.0
remote_wait(timeout::Union{Real,Nothing}) =
    timeout === nothing ? REMOTE_UNBOUNDED_S : Float64(timeout) + REMOTE_SPAWN_GRACE_S

function remote_tool_call(op::AbstractString, worker::AbstractString, args::AbstractDict;
                          wait::Real)
    fwd = Dict{String,Any}(String(k) => v for (k, v) in args if String(k) != "worker")
    env_path = get(fwd, "env_path", nothing)
    env_key  = env_path isa AbstractString && !isempty(env_path) ? String(env_path) : nothing
    tracked  = op in ("eval", "continue")
    tracked && @lock SERVER.inflight_lock push!(SERVER.remote_inflight, (worker, env_key))
    reply = try
        call_server("remote_eval"; timeout = wait, worker = worker, op = op, args = fwd)
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror, e))
    finally
        tracked && @lock SERVER.inflight_lock delete!(SERVER.remote_inflight, (worker, env_key))
    end
    reply isa AbstractDict ||
        return tool_error("unexpected reply from the server for a remote '$(op)': $(repr(reply))")
    return Dict{String,Any}(String(k) => v for (k, v) in reply)
end

# A cancel (`notifications/cancelled`) reaches evals running on other workers
# through the server. Best-effort and asynchronous: the cancel path must not
# wait on a round trip per remote eval.
function interrupt_remote_inflight!()
    targets = @lock SERVER.inflight_lock collect(SERVER.remote_inflight)
    for (worker, env_path) in targets
        Base.errormonitor(@async try
            call_server("remote_eval"; timeout = 30.0, worker = worker, op = "interrupt",
                        args = Dict{String,Any}("env_path" => env_path))
        catch e
            e isa InterruptException && rethrow()
            log_info("cancel: remote interrupt on '$(worker)' failed: $(sprint(showerror, e))")
        end)
    end
    return length(targets)
end

# ── Handlers ────────────────────────────────────────────────────────────────
function julia_eval_handler(args::AbstractDict)
    code        = String(get(args, "code", ""))
    env_path    = get(args, "env_path", nothing)
    julia_cmd   = get(args, "julia_cmd", nothing)
    user_to     = get(args, "timeout", nothing)
    full_output = Bool(get(args, "full_output", false))
    max_bytes   = Int(get(args, "max_response_bytes", 10_000))

    isempty(strip(code)) && return tool_error("empty code")

    worker = remote_worker(args)
    worker === nothing ||
        return remote_tool_call("eval", worker, args;
                                wait = remote_wait(effective_timeout(code, user_to)))

    s = try
        get_or_create!(manager(), env_path; julia_cmd)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text",
                                "text" => "error starting session: $(sprint(showerror, e))")],
            "isError" => true,
        )
    end

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

    timeout = effective_timeout(code, user_to)

    res = try
        execute(s, code; timeout, max_bytes, full_output)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end

    res.status === :completed || return running_response(env_path, res.partial, res.elapsed_s)

    # A DISPLAY value (App / plot / image) came back as text because this env's
    # Bonito is too old for the live bridge (`s.bonito_mismatch` set by the gate).
    # Prepend the upgrade marker so the chat shows the one-click [Update env] card
    # instead of a bare "App". Plain-text evals never carry `wants_display`, so a
    # `println` on a mismatched env won't nag.
    blocks = res.blocks
    if res.wants_display && !isempty(s.bonito_mismatch)
        blocks = copy(blocks)
        pushfirst!(blocks, bonito_upgrade_block(s.bonito_mismatch, s.env_path))
    end
    return completed_response(blocks, res.html, res.is_error, res.elapsed_s)
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

function julia_continue_handler(args::AbstractDict)
    env_path  = get(args, "env_path", nothing)
    user_to   = get(args, "timeout",  nothing)

    worker = remote_worker(args)
    worker === nothing ||
        return remote_tool_call("continue", worker, args;
            wait = remote_wait(user_to === nothing ? DEFAULT_TIMEOUT : (user_to > 0 ? user_to : nothing)))

    # Pure lookup — never get_or_create! (which would kill+replace the session
    # holding the in-flight eval; M5). `julia_cmd` is intentionally ignored here.
    s = try
        lookup_session(manager(), env_path)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end

    # Use the in-flight code's Pkg-aware behaviour
    timeout = user_to === nothing ? DEFAULT_TIMEOUT :
              user_to > 0 ? user_to : nothing

    res = try
        continue_eval!(s; timeout)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end
    return res.status === :completed ?
        completed_response(res.blocks, res.html, res.is_error, res.elapsed_s) :
        running_response(env_path, res.partial, res.elapsed_s)
end

function julia_interrupt_handler(args::AbstractDict)
    env_path  = get(args, "env_path", nothing)

    worker = remote_worker(args)
    worker === nothing ||
        return remote_tool_call("interrupt", worker, args; wait = 90.0)

    # Pure lookup — never get_or_create! (M5). Interrupting requires the EXISTING
    # session that owns the in-flight eval, not a freshly created replacement.
    s = try
        lookup_session(manager(), env_path)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end

    res = try
        interrupt!(s)
    catch e
        return Dict{String,Any}(
            "content" => [Dict("type" => "text", "text" => sprint(showerror, e))],
            "isError" => true,
        )
    end
    return res.status === :completed ?
        completed_response(res.blocks, res.html, res.is_error, res.elapsed_s) :
        running_response(env_path, res.partial, res.elapsed_s)
end

function julia_restart_handler(args::AbstractDict)
    env_path = get(args, "env_path", nothing)
    worker = remote_worker(args)
    worker === nothing ||
        return remote_tool_call("restart", worker, args; wait = 120.0)
    restart!(manager(), env_path)
    label = env_path === nothing ? "<temp>" : env_path
    return Dict{String,Any}(
        "content" => [Dict("type" => "text",
                            "text" => "Session for $label cleared. Next call rebuilds it.")],
        "isError" => false,
    )
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
        push!(lines, "  - $(get(w, "name", "?")) ($(get(w, "hostname", "?")), projects under $(get(w, "projects_root", "?")))" *
                     (isempty(tag) ? "" : "  [" * join(tag, ", ") * "]"))
        for s in get(w, "sessions", Any[])
            s isa AbstractDict || continue
            push!(lines, "      session $(get(s, "env_path", "<temp>"))" *
                         (get(s, "in_flight", false) === true ? "  [EVAL IN FLIGHT]" : ""))
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
calls. Revise.jl is auto-loaded so source edits to packages are picked up
without restart. If the env path ends in `/test`, TestEnv is auto-activated
so the parent project's test deps are visible.

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

Streaming model — IMPORTANT:
  - `timeout` is a **soft** checkpoint, not a hard kill. The call returns
    within `timeout` seconds with either:
      • status="completed" — full result blocks; OR
      • status="running"   — the eval is still in flight; the response
        contains the stdout captured so far so you can decide what to do.
  - When you see status="running", choose one:
      • bt_julia_continue (wait another `timeout` seconds)
      • bt_julia_interrupt (SIGINT — captures output + InterruptException;
        session state preserved)
      • bt_julia_restart (SIGKILL — loses all session state)
  - Lower `timeout` = more frequent feedback on long jobs but more round
    trips. Higher = less overhead but coarser progress signal.
  - Default 30s; auto-disabled (no checkpointing) when the code uses
    `Pkg.*` since installs are routinely multi-minute. Pass `timeout=0`
    to disable the checkpoint entirely.

Output:
  - Captured stdout/stderr followed by the return value's repr (or the error),
    exactly as a REPL would show it — one terminal-faithful text block. The
    code is NOT echoed back (you already have it as the tool input).
  - `nothing` returns are suppressed (don't waste tokens on it; if you
    need a value, return it explicitly as the last expression).
  - Output is auto-truncated at `max_response_bytes` (default 10000).
    Large arrays / dicts are summarised.
  - 2-D color arrays render as PNG when PNGFiles is loaded in the env.
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
        ),
        "required" => ["code"],
    ),
    julia_eval_handler,
)

const WORKER_ARG = Dict("type"=>"string", "description"=>"Address the session on this other worker (display name) instead of the chat's own")

register!(
    "bt_julia_continue",
    """
    Continue waiting for an in-flight bt_julia_eval call. Returns the same
    shape as bt_julia_eval — completed or still-running. Pass `timeout` to
    set how long this checkpoint waits before returning again.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "env_path" => Dict("type"=>"string", "description"=>"Session to continue; omit for temp"),
            "timeout"  => Dict("type"=>"number", "description"=>"Checkpoint timeout in seconds. Default 30; pass 0 to disable."),
            "worker"   => WORKER_ARG,
        ),
    ),
    julia_continue_handler,
)

register!(
    "bt_julia_interrupt",
    """
    SIGINT the in-flight bt_julia_eval. The user code raises InterruptException;
    the session subprocess and all state survive. Returns the captured stdout
    so far + the interrupt error block. Use this when you want to stop a
    runaway computation but keep the loaded packages/variables.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "env_path" => Dict("type"=>"string", "description"=>"Session to interrupt; omit for temp"),
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
