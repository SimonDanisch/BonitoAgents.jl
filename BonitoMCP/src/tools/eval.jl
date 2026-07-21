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

# ── Handlers ────────────────────────────────────────────────────────────────
function julia_eval_handler(args::AbstractDict)
    code        = String(get(args, "code", ""))
    env_path    = get(args, "env_path", nothing)
    julia_cmd   = get(args, "julia_cmd", nothing)
    user_to     = get(args, "timeout", nothing)
    full_output = Bool(get(args, "full_output", false))
    max_bytes   = Int(get(args, "max_response_bytes", 10_000))

    isempty(strip(code)) && return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => "error: empty code")],
        "isError" => true,
    )

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

    return res.status === :completed ?
        completed_response(res.blocks, res.html, res.is_error, res.elapsed_s) :
        running_response(env_path, res.partial, res.elapsed_s)
end

function julia_continue_handler(args::AbstractDict)
    env_path  = get(args, "env_path", nothing)
    user_to   = get(args, "timeout",  nothing)

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
    restart!(manager(), env_path)
    label = env_path === nothing ? "<temp>" : env_path
    return Dict{String,Any}(
        "content" => [Dict("type" => "text",
                            "text" => "Session for $label cleared. Next call rebuilds it.")],
        "isError" => false,
    )
end

function julia_list_sessions_handler(::AbstractDict)
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
    return Dict{String,Any}(
        "content" => [Dict("type" => "text", "text" => text)],
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
        ),
        "required" => ["code"],
    ),
    julia_eval_handler,
)

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
        ),
    ),
    julia_restart_handler,
)

register!(
    "bt_julia_list_sessions",
    "List currently active per-`env_path` Julia sessions. Marks any session that has an in-flight eval.",
    Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
    julia_list_sessions_handler,
)
