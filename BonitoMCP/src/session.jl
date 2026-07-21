# JuliaSession + SessionManager backed by Malt.jl. One Malt.Worker per env_path.
#
# Key design points:
#   - Soft timeout, never a hard kill. Code keeps running across checkpoints.
#     The agent calls `bt_julia_eval` with `timeout=N`; if the eval doesn't
#     finish in N seconds, the result has `status: "running"` + the partial
#     stdout captured so far. The agent can `bt_julia_continue` to wait
#     longer, `bt_julia_interrupt` to SIGINT (state preserved), or
#     `bt_julia_restart` to SIGKILL (state lost).
#
#   - Streaming via stdout pipe. Worker is spawned with monitor_stdout=false
#     so its stdout/stderr are real Pipes back to us. Background reader
#     tasks pump bytes into a per-session buffer; each checkpoint drains
#     whatever has accumulated. No special framing needed.
#
#   - Output discipline (truncation, container summary, image detection,
#     trimmed backtrace, suppress-nothing) runs inside the worker via the
#     BonitoMCPHelper module (helper_payload.jl). The eval returns
#     pre-formatted block dicts — base types only, so Malt's serialiser
#     never sees user-defined types it doesn't know about.

using Malt
using Dates: format, now
import Pkg

# Runtime (pkgdir), not @__DIR__ — see remote_proxy_path; survives bundle reloc.
helper_payload_path() = joinpath(pkgdir(@__MODULE__)::String, "src", "helper_payload.jl")
const PKG_PATTERN = r"\bPkg\."
const DEFAULT_TIMEOUT = 30.0
const BONITO_UUID = Base.UUID("824d6782-a2ef-11e9-3a09-e5662e0c26f8")

# Hard cap on captured stdout. An abandoned printing eval (`for i in 1:10^8;
# println(i); end`) would otherwise grow `output_buffer` without bound (OOM) and
# pump tens of MB straight into the agent's MCP context. We keep only the LAST
# `STDOUT_CAP_BYTES` bytes (the tail is what's relevant for "what was it doing
# when I checked"), dropping the head with a one-line marker. Applied both in the
# pump (memory bound) and again on the drained `partial` (context bound).
const STDOUT_CAP_BYTES = 256 * 1024

# Locate Bonito's source directory in BonitoMCP's own active project, so a
# temp eval env can path-dep on the *same* Bonito BonitoMCP itself runs
# against. Returns `nothing` if Bonito isn't in the active project (e.g.
# BonitoMCP installed standalone) — caller falls back gracefully.
function _find_bonito_path()
    try
        deps = Pkg.dependencies()
        haskey(deps, BONITO_UUID) || return nothing
        src = deps[BONITO_UUID].source
        src isa AbstractString && isdir(src) ? String(src) : nothing
    catch e
        @debug "_find_bonito_path failed" exception = e
        nothing
    end
end

# Seed a fresh temp project so `using Bonito` on the Malt worker resolves to
# the proxy-aware dev Bonito (`id_prefix` & friends) rather than the
# registered version. Writes Project.toml + resolves it in a side julia
# subprocess so the worker can `using Bonito` immediately. Best-effort — a
# failure here just leaves the temp env empty, same as before.
function seed_temp_env_with_bonito!(env_dir::AbstractString)
    bonito_path = _find_bonito_path()
    bonito_path === nothing && return false
    proj_toml = joinpath(env_dir, "Project.toml")
    try
        open(proj_toml, "w") do io
            print(io, """
                [deps]
                Bonito = "$(BONITO_UUID)"

                [sources]
                Bonito = {path = $(repr(bonito_path))}
                """)
        end
        # Resolve in a side julia process (so the parent's project state isn't
        # disturbed and the Malt worker can `using Bonito` without doing its
        # own Pkg.resolve at first call).
        julia = joinpath(Sys.BINDIR::String, Base.julia_exename())
        run(pipeline(`$julia --project=$env_dir --startup-file=no -e "using Pkg; Pkg.resolve()"`;
                     stdout = devnull, stderr = devnull))
        true
    catch e
        @warn "seed_temp_env_with_bonito!: Pkg.resolve failed; the live-render bridge may fail until env_path is given explicitly" env_dir exception = e
        false
    end
end

# The minimum Bonito version with the remote-app proxy API that the live-render
# bridge needs. The eval worker uses the PROJECT's own Bonito (we never touch its
# LOAD_PATH); if that Bonito is older, the bridge setup errors clearly and only
# live-render display is affected — plain `bt_julia_eval` text output is untouched.
const MIN_BRIDGE_BONITO = v"5"

# ── JuliaSession ────────────────────────────────────────────────────────────
mutable struct JuliaSession
    env_path::Union{String,Nothing}
    is_temp::Bool
    is_test::Bool
    julia_cmd::Union{String,Nothing}
    worker::Union{Malt.Worker,Nothing}
    output_buffer::IOBuffer
    output_lock::ReentrantLock          # protects output_buffer
    stdout_pump::Union{Task,Nothing}
    stderr_pump::Union{Task,Nothing}
    # Drains `stream_channel` and forwards the worker's live stdout/stderr over
    # /mcp-ws to the chat (coalesced + trailing-window capped). Dies when the
    # channel closes (kill_session!). No on-disk log, no polling.
    stream_forward::Union{Task,Nothing}
    in_flight::Union{Task,Nothing}      # Malt.remote_eval task
    in_flight_code::String
    in_flight_started::Float64
    lock::ReentrantLock                 # serialises eval/continue/interrupt
    stream_channel::Channel{String}     # real-time stdout/stderr chunks for /mcp-ws streaming
    dialed_back::Bool                   # `ensure_eval_dialed!` dedupes against this; flipped under `lock`
    dial_error::String                  # last eval-bridge setup/connect failure (live-render bridge)
    closed::Bool                        # terminal: set by kill_session!; start! refuses to resurrect
end

function JuliaSession(env_path;
                       is_temp::Bool   = false,
                       is_test::Bool   = false,
                       julia_cmd::Union{String,Nothing} = nothing)
    return JuliaSession(env_path, is_temp, is_test, julia_cmd,
                        nothing, IOBuffer(), ReentrantLock(),
                        nothing, nothing, nothing,
                        nothing, "", 0.0,
                        ReentrantLock(), Channel{String}(Inf), false, "", false)
end

# The chat routes live stream chunks by this key (matched against the eval
# tool's env_path, normalized the same way on the chat side). Temp sessions
# collapse onto TEMP_KEY; project sessions use their abspath env_dir.
stream_route(s::JuliaSession) = s.is_temp ? TEMP_KEY : String(s.env_path)

is_alive(s::JuliaSession) = s.worker !== nothing && Malt.isrunning(s.worker)

# Env overrides for the eval worker so it behaves like a bare
# `julia --project=env_path`. The BonitoAgentsApp bundle launcher exports a fixed
# `JULIA_LOAD_PATH` (bundle project + stdlib, with NO `@`); Malt workers inherit
# the parent env, so without this override the worker resolves packages against
# the BUNDLE's project and ignores `--project=env_path` entirely. Malt's `env`
# kwarg can only SET vars (it routes through `Base.byteenv`, which can't express
# removal), so we reset `JULIA_LOAD_PATH` to Julia's documented default — exactly
# what an un-set `JULIA_LOAD_PATH` would yield: `@` (the active project, i.e.
# env_path via --project), `@v#.#` (shared default env), `@stdlib`. Keeps the
# worker on the PROJECT's Bonito/WGLMakie, never the bundle's precompiled copies;
# JULIA_DEPOT_PATH is left as-is so the worker keeps a writable precompile depot.
const DEFAULT_LOAD_PATH = join(["@", "@v#.#", "@stdlib"], Sys.iswindows() ? ";" : ":")
worker_env() = ["JULIA_LOAD_PATH" => DEFAULT_LOAD_PATH]

# Build the exeflags vector. Handles juliaup `+channel` syntax + custom flags.
function build_exeflags(env_path, julia_cmd)::Vector{String}
    # `--color=yes`: the worker's stdout is a Pipe (not a tty), so colored tools
    # (`Pkg.status`, `printstyled`, error backtraces) would emit PLAIN text by
    # default. Force color so captured stdout carries ANSI — the chat renders it
    # as a colored terminal block (`render_text_block` → RichText). The value repr
    # is already colored via the render io_context; this covers stdout.
    base = String["--threads=auto", "--color=yes"]
    env_path === nothing || push!(base, "--project=$(abspath(env_path))")
    if julia_cmd !== nothing
        # julia_cmd is something like "julia +1.11" or "julia --check-bounds=yes"
        # The exename is `julia` by default; we strip that and pull in the rest.
        parts = split(julia_cmd)
        @assert !isempty(parts)
        # Drop the `julia` token if present (Malt provides the executable)
        rest = parts[1] == "julia" ? parts[2:end] : parts
        prepend!(base, rest)
    end
    return base
end

"""
    ensure_eval_dialed!(s::JuliaSession)

If the server injected WebSocket dial-back coordinates (via the MCP `env`),
bootstrap the worker-side proxy bridge and have the worker dial the server. This
one Malt call (over BonitoMCP's OWN link to the worker) includes `RemoteProxy` +
builds the bridge; the worker then opens the dial-back WebSocket and runs
`RemoteProxy.serve_bridge`, which pipes the Bonito protocol over it RAW (no Malt
on that socket — see RemoteProxy.jl). Lets the server render this worker's
`bt_julia_eval` results (incl. interactive Bonito apps) live into the chat.
Idempotent + lazy (called before an eval executes, once Bonito is loaded).
"""
function ensure_eval_dialed!(s::JuliaSession)
    # `BONITOAGENTS_SERVER_URL` is set by the BonitoWorker daemon (the install
    # URL it dialed in on) and inherited down through claude-agent-acp → MCP
    # child. Single source of truth for "where the server is", shared with the
    # worker-control WS so the two dial-backs can't disagree.
    server_url = get(ENV, "BONITOAGENTS_SERVER_URL", "")
    isempty(server_url) && return s
    wsurl = replace(rstrip(server_url, '/'), r"^http" => "ws") * "/eval-ws"
    # The whole bootstrap (start! + RemoteProxy include + dial_loop spawn + the
    # dedupe read/write of s.dialed_back) runs under s.lock. Two concurrent
    # bt_show_app calls would otherwise each `start!` and each spawn an eternal
    # dial_loop that steals d.ws[] from the other forever; the unlocked start!
    # also raced execute's locked one (leaked Malt worker, interleaved pumps).
    # s.lock is reentrant, so a caller already holding it (none today) is fine.
    @lock s.lock ensure_eval_dialed_locked!(s, wsurl)
    return s
end

function ensure_eval_dialed_locked!(s::JuliaSession, wsurl::AbstractString)
    is_alive(s) || start!(s)
    secret     = get(ENV, "BONITOAGENTS_SECRET", "")
    project_id = get(ENV, "BONITOAGENTS_PROJECT_ID", "")
    # Dedupe against this session's own state — avoids a Main-global
    # idempotency flag on the worker (Julia 1.12 strict-globals would force
    # a `Core.eval`/world-age dance, and we'd be inventing the dedupe twice).
    # Once we've dialed back, the worker's `dial_loop` task self-reconnects
    # on WS drop — we do NOT want to spawn a duplicate dial_loop. Just verify
    # the connection IS currently up; if it's between reconnect attempts
    # (backoff sleep), wait briefly for it to come back before failing. This
    # is the path that fires when bt_show_app runs against a worker whose WS
    # was lost (e.g. after a BonitoAgents server restart).
    if s.dialed_back
        worker_ws_live() = try
            Malt.remote_eval_fetch(s.worker,
                :(isdefined(Main, :RemoteProxy) &&
                  Main.RemoteProxy.BRIDGE[] !== nothing &&
                  Main.RemoteProxy.BRIDGE[].driver.ws[] !== nothing))
        catch
            false
        end
        if worker_ws_live(); s.dial_error = ""; return s; end
        @info "BonitoMCP: eval-ws bridge currently disconnected — waiting for dial_loop to reconnect"
        for _ in 1:40   # ~10s budget, covers max_backoff (8s) plus reconnect
            if worker_ws_live(); s.dial_error = ""; return s; end
            sleep(0.25)
        end
        s.dial_error = "the eval-ws bridge was connected earlier but is currently down and the worker's dial_loop hasn't reconnected within ~10s — the BonitoAgents server may be unreachable at $wsurl (server restarted / wrong URL)."
        @warn "BonitoMCP: eval-ws bridge stayed disconnected; will not double-dial. Use bt_julia_restart to rebuild the worker if the issue persists." wsurl
        return s
    end
    try
        # The live-render bridge needs Bonito ≥ 5 (the remote-app proxy API). The
        # eval worker uses the PROJECT's OWN Bonito — we never touch its env or
        # LOAD_PATH. If that Bonito is too old, fail with a clear, actionable
        # message BEFORE the RemoteProxy include (which would otherwise throw a
        # cryptic `UndefVarError: proxy_send`). Only live-render display is
        # affected; plain bt_julia_eval text output works regardless of version.
        ok, vstr = Malt.remote_eval_fetch(s.worker, quote
            using Bonito
            local v = pkgversion(Bonito)
            (v !== nothing && v >= $(MIN_BRIDGE_BONITO),
             v === nothing ? "unknown" : string(v))
        end)
        if !ok
            s.dial_error = "the live-render bridge needs Bonito ≥ $(MIN_BRIDGE_BONITO) " *
                "(the remote-app proxy API), but this chat's project env resolved " *
                "Bonito v$(vstr). Add a Bonito ≥ $(MIN_BRIDGE_BONITO) to the project " *
                "env (e.g. `[sources] Bonito = {path = \"…/dev/Bonito\"}` then " *
                "`Pkg.resolve()`) and reopen the chat. Only live-render display is " *
                "affected — bt_julia_eval text output works regardless."
            @warn "BonitoMCP: the live-render bridge needs Bonito ≥ $(MIN_BRIDGE_BONITO); this project env has Bonito v$(vstr) — skipping bridge setup" project_env = s.env_path
            return s
        end
        # Bootstrap over BonitoMCP's OWN Malt link: include RemoteProxy + build the
        # bridge, get its namespace prefix. The dial-back socket itself carries NO
        # Malt — it's a raw Bonito frame pipe (see RemoteProxy.serve_bridge); Malt
        # is only this one-time setup call.
        prefix = Malt.remote_eval_fetch(s.worker, quote
            using Bonito
            # Re-include if RemoteProxy is absent OR only PARTIALLY loaded. A failed
            # include (e.g. the resolved Bonito lacks the remote-app proxy API the
            # module touches at load time) leaves a PARTIAL module registered in
            # Main — early defs present, late ones (`render_eval_html`) missing — and
            # the include THREW. The old bare `isdefined(Main, :RemoteProxy)` guard
            # then skipped re-include forever, so the next call built a bridge on the
            # broken module and the missing def surfaced later as a cryptic
            # `render_eval_html not defined`. `render_eval_html` is the module's last
            # def ⇒ its presence means a complete load; otherwise re-include, which
            # re-throws the REAL load error if the env is wrong.
            if !(isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :render_eval_html))
                include($(remote_proxy_path()))
            end
            Main.RemoteProxy.ensure_bridge!()
        end)
        # Drive a self-reconnecting dial loop on the worker. Handshake carries
        # the prefix so the host knows the namespace before any frame flows.
        # `dial_loop` survives transient WS drops by reconnecting with backoff —
        # `BRIDGE[].routes` is preserved across drops, so already-registered
        # apps keep working without re-running their code.
        Malt.remote_eval_fetch(s.worker, quote
            Main.RemoteProxy.start_dial!(
                $wsurl,
                $(secret * " " * project_id * " " * prefix))
            nothing
        end)
        # Wait until the dial actually connects (serve_bridge sets the socket) so
        # callers can immediately reach the bridge over the raw transport.
        ready = false
        for _ in 1:120   # ~30s budget — covers cold include + first dial
            if Malt.remote_eval_fetch(s.worker,
                    :(isdefined(Main, :RemoteProxy) && Main.RemoteProxy.BRIDGE[] !== nothing &&
                      Main.RemoteProxy.BRIDGE[].driver.ws[] !== nothing))
                ready = true; break
            end
            sleep(0.25)
        end
        if ready
            s.dial_error = ""
        else
            s.dial_error = "the RemoteProxy bridge was built on the worker but never connected to $wsurl within 30s — the eval worker couldn't reach the BonitoAgents server (wrong/unreachable BONITOAGENTS_SERVER_URL, server gone, or the dial_loop crashed). Check the worker log for a 'dial loop crashed' / 'dial failed' warning."
            @warn "BonitoMCP: bridge dial not connected 30s after setup" wsurl
        end
        # The bridge IS set up and dial_loop is spawned (it self-reconnects), so
        # keep dialed_back=true regardless of `ready` — re-running setup would
        # spawn a duplicate dial_loop. The skip-path above surfaces dial_error on
        # the next call if it's still not connected.
        s.dialed_back = true
    catch e
        s.dialed_back = false   # allow retry on the next call
        # Capture the REAL worker-side setup error (e.g. a `using Bonito` that
        # resolved a Bonito without the remote-app API → `UndefVarError:
        # proxy_send` while including RemoteProxy) so bt_show_app can surface it
        # to the agent instead of a generic "bridge not connected".
        s.dial_error = sprint(showerror, e, catch_backtrace())
        @warn "BonitoMCP: eval dial-back setup failed" exception = (e, catch_backtrace())
    end
    return s
end

function start!(s::JuliaSession)
    # Terminal-state guard: a session killed via kill_session! must never be
    # resurrected into a fresh, untracked worker (it would be unreachable by the
    # manager's restart/shutdown — a zombie holding a second live worker for the
    # same env). Callers that hit a closed session must obtain a NEW session from
    # the manager instead. (M6: make the wrong state impossible.)
    s.closed && error("session is closed (killed); create a fresh one via the manager")
    is_alive(s) && return s
    # A fresh worker means a fresh dial-back — the old worker's bridge died with
    # it, so clear the dedupe flag (M10).
    s.dialed_back = false
    s.worker = Malt.Worker(
        monitor_stdout = false,
        monitor_stderr = false,
        env            = worker_env(),
        exeflags       = build_exeflags(s.env_path, s.julia_cmd),
    )
    # Background pumps drain worker stdout/stderr into our buffer (the agent's
    # copy, drained into the MCP response) AND push each chunk to stream_channel.
    # Both streams merge into the same buffer — same UX as a normal REPL.
    s.stdout_pump = Threads.@spawn pump_pipe!(s, s.worker.stdout)
    s.stderr_pump = Threads.@spawn pump_pipe!(s, s.worker.stderr)
    # The forwarder relays stream_channel over /mcp-ws to the chat's live tail
    # (see stream_forward_loop!). Spawned once per session; dies when the channel
    # closes in kill_session!.
    s.stream_forward = Threads.@spawn stream_forward_loop!(s)

    # The worker is a plain `julia --project=env_path`: `--project` sets the env,
    # and `worker_env()` resets JULIA_LOAD_PATH to Julia's default so the inherited
    # bundle JULIA_LOAD_PATH can't shadow it (see worker_env). Packages resolve
    # exactly as the user's env dictates — we do NOT stack any extra entry. If
    # bt_show_app needs a proxy-aware Bonito, the project's env must declare it
    # (surfaced as a dial_error otherwise); we never silently inject a Bonito.

    # Auto-Revise (best-effort) + load our format helper. The trailing
    # `; nothing` is load-bearing: include() returns the module object and
    # Malt can't serialise a `Module` reference back to the parent.
    Malt.remote_eval_fetch(s.worker, :(try; using Revise; catch; end; nothing))
    Malt.remote_eval_fetch(s.worker, :(include($(helper_payload_path())); nothing))
    # The worker's PIPED stdout/stderr are write-buffered: plain `println`s in
    # user code would reach the host (and the chat's live stream tail) in
    # multi-second bursts — a terminal flushes far more eagerly. A 4Hz
    # flusher task makes the captured stream terminal-faithful; it dies with
    # the streams (flush on a closing stream throws → loop ends) and with
    # the worker.
    Malt.remote_eval_fetch(s.worker, :(@async try
        while true
            flush(stdout)
            flush(stderr)
            sleep(0.25)
        end
    catch
        # stream closed — worker shutting down
    end; nothing))

    # Interactive-app dial-back is lazy (ensure_eval_dialed! from bt_show_app),
    # so non-Bonito eval sessions don't pay for it.

    if s.is_test
        Malt.remote_eval_fetch(s.worker,
            :(try; using TestEnv; TestEnv.activate(); catch; end; nothing))
    end
    return s
end

function pump_pipe!(s::JuliaSession, pipe)
    try
        while !eof(pipe)
            data = readavailable(pipe)
            isempty(data) && continue
            @lock s.output_lock begin
                write(s.output_buffer, data)
                cap_output_buffer!(s.output_buffer)
            end
            # Feed the live-tail forwarder. Best-effort: an unbounded channel
            # never blocks the pump, and if no chat is listening the forwarder
            # drains + drops (see stream_forward_loop!). Raw bytes (ANSI intact) —
            # the chat strips codes for the tail; keeping them keeps colored
            # rendering possible later without a wire change.
            try isopen(s.stream_channel) && put!(s.stream_channel, String(data)) catch end
        end
    catch e
        e isa EOFError && return
        e isa Base.IOError && return
        @warn "pipe pump error" exception=e
    end
end

# How long the forwarder batches a burst before shipping, and the max bytes per
# frame. Bounds /mcp-ws load so a firehose eval (300k lines) can't flood the
# control channel and starve its heartbeat — the tail only shows the last lines,
# so older bytes of an over-cap burst are dropped, never shipped.
const STREAM_COALESCE_S = 0.15
const STREAM_MAX_CHUNK  = 8_192

# Drain stream_channel, coalesce a short burst, and forward the trailing window
# over /mcp-ws (tagged with stream_route so the chat routes it to the right eval
# card). Always DRAINS even when no control channel is up (send is a no-op then),
# so the channel stays bounded. Ends when kill_session! closes the channel.
function stream_forward_loop!(s::JuliaSession)
    for first_chunk in s.stream_channel        # blocks until a chunk or channel close
        io = IOBuffer()
        write(io, first_chunk)
        sleep(STREAM_COALESCE_S)               # let a burst accumulate
        # Drain into an IOBuffer (O(1) amortized — NOT `buf *= take!`, which is
        # quadratic and melts the CPU under a 300k-line firehose). Bound the drain
        # to what's ALREADY queued (`n_avail` snapshot): a pump pushing as fast as
        # we take must not livelock this loop or grow `io` without bound — the rest
        # waits for the next window.
        for _ in 1:Base.n_avail(s.stream_channel)
            isready(s.stream_channel) || break
            write(io, take!(s.stream_channel))
        end
        # Ship only the trailing window — a firehose must never put a multi-MB
        # frame on the control channel. `last` is char-based, so the cut can't
        # split a UTF-8 codepoint.
        str = String(take!(io))
        length(str) > STREAM_MAX_CHUNK && (str = String(last(str, STREAM_MAX_CHUNK)))
        send_eval_stream_chunk(stream_route(s), str)
    end
    return nothing
end

# Keep `buf` bounded to `STDOUT_CAP_BYTES` by dropping the OLDEST bytes when it
# overflows (the tail is what matters for "what is it printing now"). Replaces
# the buffer contents with a marker + the kept tail. Caller holds `output_lock`.
function cap_output_buffer!(buf::IOBuffer)
    n = buf.size
    n <= STDOUT_CAP_BYTES && return buf
    all = take!(buf)                       # drains + resets buf
    tail = @view all[(end - STDOUT_CAP_BYTES + 1):end]
    dropped = n - STDOUT_CAP_BYTES
    write(buf, "[stdout truncated: dropped earliest $dropped bytes]\n")
    write(buf, tail)
    return buf
end

drain_output!(s::JuliaSession) = @lock s.output_lock String(take!(s.output_buffer))

# Truncate a (already-drained) stdout string to a byte budget for the MCP
# response, keeping the TAIL (most recent output). Pure so it's unit-testable.
function cap_response_text(text::AbstractString, max_bytes::Int = STDOUT_CAP_BYTES)
    bytes = codeunits(text)
    length(bytes) <= max_bytes && return String(text)
    dropped = length(bytes) - max_bytes
    keep = String(bytes[(dropped + 1):end])
    # The raw byte cut may have split a multibyte UTF-8 char, leaving invalid
    # leading continuation bytes. Advance to the first valid char boundary.
    start = 1
    while start <= ncodeunits(keep) && !isvalid(keep, start)
        start += 1
    end
    aligned = start == 1 ? keep : String(SubString(keep, start))
    return "[stdout truncated: dropped earliest $dropped bytes]\n" * aligned
end

# ── Eval ────────────────────────────────────────────────────────────────────
"""
    execute(session, code; timeout, max_bytes, full_output)
        → NamedTuple

Returns one of:
  (status = :completed, blocks::Vector{Dict}, is_error::Bool, elapsed_s::Float64)
  (status = :running,   partial::String, elapsed_s::Float64, code::String)

The `code` field on the running variant carries the in-flight code so the chat
renderer can show the ```julia code echo + partial stdout as eval-shaped
content (same render as the completed case), instead of a raw status blob.

Soft timeout — `:running` means the eval is still in flight; the caller can
`continue_eval!` to wait more, `interrupt!` to SIGINT, or restart the session.
"""
function execute(s::JuliaSession, code::AbstractString;
                  timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT,
                  max_bytes::Int               = 10_000,
                  full_output::Bool            = false)
    @lock s.lock begin
        s.in_flight === nothing ||
            error("An eval is already in flight on this session — call " *
                  "bt_julia_continue, bt_julia_interrupt, or bt_julia_restart first.")
        is_alive(s) || start!(s)
        drain_output!(s)

        # Early parse-error detection (fast-fail with a clean message before the
        # remote round-trip). A parse error is a USER error, delivered as
        # terminal-faithful output text (never MCP isError — that's reserved for
        # infra failures; claude fuses isError results into one rawOutput blob).
        # The worker does the REAL evaluation REPL-style from the code STRING
        # (see `repl_eval`); we don't reuse this parsed AST.
        try
            Meta.parseall(String(code))
        catch e
            return (status   = :completed,
                    blocks   = [Dict{String,Any}("type"=>"text",
                                                  "text"=>"\e[91mERROR: parse error: $(sprint(showerror, e))\e[39m")],
                    html     = nothing,
                    is_error = false,
                    elapsed_s = 0.0)
        end

        # Anchor the .bonitoAgents/show/ dir in env_path so rich-output files
        # written by format_value travel with the project. RemoteSync
        # already covers .bonitoAgents/, so show files persist alongside the
        # chat history. For temp envs we fall back to a tmp dir.
        out_dir = s.env_path === nothing ?
            mktempdir(prefix = "bt-show-") :
            joinpath(s.env_path, ".bonitoAgents", "show")

        s.in_flight_code    = String(code)
        s.in_flight_started = time()
        # The worker REPL-evals the code STRING (`eval_and_format` →
        # `repl_eval`: per-top-level-statement, soft scope, correct world age)
        # and returns pre-formatted block dicts (base types only, never
        # user-defined types Malt's serialiser wouldn't recognise on the parent
        # side). A user error propagates here to `format_error`.
        code_str = String(code)
        wrapped = quote
            try
                Main.BonitoMCPHelper.eval_and_format($code_str, $out_dir, $max_bytes, $full_output)
            catch __mcp_err__
                Main.BonitoMCPHelper.format_error(__mcp_err__, catch_backtrace(),
                                                   $max_bytes, $full_output)
            end
        end
        s.in_flight = Malt.remote_eval(s.worker, wrapped)
        return await_or_yield(s, timeout)
    end
end

function continue_eval!(s::JuliaSession;
                        timeout::Union{Real,Nothing} = DEFAULT_TIMEOUT)
    @lock s.lock begin
        s.in_flight === nothing && error("No eval in flight on this session.")
        return await_or_yield(s, timeout)
    end
end

function interrupt!(s::JuliaSession)
    @lock s.lock begin
        s.in_flight === nothing && error("No eval in flight on this session.")
        Malt.interrupt(s.worker)
        # Generous timeout: the user's code might be in a try/catch that swallows
        # InterruptException briefly, but should yield within 30s.
        return await_or_yield(s, 30.0)
    end
end

# Poll the in-flight task for up to `timeout` seconds. Returns either
# completed (drained partial → stdout block + the value blocks) or running.
function await_or_yield(s::JuliaSession, timeout::Union{Real,Nothing})
    # Snapshot the in-flight task ONCE. `kill_session!` (and a cancel) can null
    # `s.in_flight` concurrently; polling the field directly would race a write
    # to `nothing` → `istaskdone(nothing)` MethodError. We only ever inspect our
    # own snapshot `f`; if it was nulled out from under us the session is gone
    # and the manager will hand out a fresh one (M4).
    f = s.in_flight
    f === nothing && error("No eval in flight on this session.")
    deadline = timeout === nothing ? Inf : time() + timeout
    # The loop also exits promptly when the eval task dies — e.g. an MCP
    # `notifications/cancelled` SIGINTs it via `handle_cancelled!`, which makes
    # `istaskdone` true and falls through to the completed (interrupted) result.
    while !istaskdone(f) && time() < deadline
        sleep(0.05)
    end
    elapsed = round(time() - s.in_flight_started; digits = 2)
    # Cap before it ever reaches the MCP response: even with the pump's
    # in-memory bound, a single drain can still be the full cap (256KB) which is
    # far too much to splice verbatim into the agent context.
    partial = cap_response_text(drain_output!(s))

    if istaskdone(f)
        # `format_value`/`format_error` return `(; blocks, html, errored, echo)`
        # — extra agent blocks, the result descriptor json, the TYPED user-error
        # flag, and the terminal-faithful output echo (result repr / ERROR text).
        result, fetch_failed = try
            (fetch(f), false)
        catch e
            ((; blocks = Dict{String,Any}[], html = nothing, errored = true,
               echo = interrupt_echo(e)), true)
        end
        value_blocks = result.blocks
        html         = result.html
        # M11: the task is done, but the worker's final `println`s may still be
        # in the OS pipe — the pump task hasn't necessarily flushed them into our
        # buffer by the time `fetch` returns. Without a settle, that trailing
        # stdout is invisible here and the NEXT execute's drain (after its own
        # `drain_output!`) throws it away. Drain-until-quiet with a small upper
        # bound: append late bytes to this result's `partial` so nothing is lost
        # or misattributed, while keeping the common (no-late-output) case fast.
        settle_deadline = time() + 0.3
        while time() < settle_deadline
            sleep(0.02)
            late = drain_output!(s)
            isempty(late) && break          # quiet → done settling
            partial = cap_response_text(partial * late)
        end
        # Clear only if it's still OUR task — a concurrent kill may have already
        # nulled/replaced it.
        @lock s.lock (s.in_flight === f && (s.in_flight = nothing))
        # MCP-level isError is INFRASTRUCTURE failures only (worker task
        # died / interrupt): claude-agent-acp fuses isError content into one
        # rawOutput string, so a plain user error must never ride it — the
        # descriptor's typed `errored` flag carries that instead. No block
        # sniffing anywhere: the flag comes from the worker payload.
        is_error = fetch_failed
        # Stitch ONE terminal-faithful output text: captured stdout/stderr,
        # then the echo (result repr / red ERROR text) — exactly what a REPL
        # session would show. No code echo (the agent has its own tool input,
        # the chat has the typed `code` field), no in-band labels.
        output = partial
        if result.echo !== nothing
            output = isempty(output) ? result.echo : output * "\n" * result.echo
        end
        blocks = Dict{String,Any}[]
        isempty(output) ||
            push!(blocks, Dict{String,Any}("type" => "text", "text" => output))
        append!(blocks, value_blocks)
        return (status = :completed, blocks = blocks, html = html,
                is_error = is_error, elapsed_s = elapsed)
    end
    return (status = :running, partial = partial, elapsed_s = elapsed,
            code = s.in_flight_code)
end

# Terminal-faithful text for a Malt task failure (interrupt / worker death).
# Drills through the wrapper layers via showerror (TaskFailedException →
# RemoteException → InterruptException or whatever the user's code threw).
interrupt_echo(e) = "\e[91mERROR: $(sprint(showerror, e))\e[39m"

# ── Lifecycle ───────────────────────────────────────────────────────────────
function kill_session!(s::JuliaSession)
    if is_alive(s)
        try Malt.stop(s.worker) catch end
    end
    # Deliberately NOT taken under s.lock: kill_session! must be able to reap a
    # worker whose eval ignored the interrupt, and that eval's await_or_yield
    # poll holds s.lock for its whole duration — locking here would deadlock the
    # cancel-kill path. Safety against the `istaskdone(nothing)` race (M4) comes
    # from await_or_yield snapshotting its task ONCE at entry and never re-reading
    # s.in_flight in the poll loop. `closed` is the terminal flag (M6): start!
    # refuses to resurrect, so a freed session can't spin up a second worker.
    s.closed = true
    s.worker = nothing
    s.in_flight = nothing
    # Closing the channel ends stream_forward_loop! (the `for` over it returns).
    try close(s.stream_channel) catch end
    s.is_temp && s.env_path !== nothing && isdir(s.env_path) &&
        try rm(s.env_path; recursive = true, force = true) catch end
    return nothing
end

# ── SessionManager ──────────────────────────────────────────────────────────
mutable struct SessionManager
    sessions::Dict{String,JuliaSession}
    # Single-flight creations: key -> the @async Task currently building that
    # key's session. Removed the instant the build finishes (success OR failure),
    # so it only ever holds the few in flight — no per-key lock registry to leak.
    creating::Dict{String,Task}
    lock::ReentrantLock                 # guards BOTH `sessions` and `creating`
end

SessionManager() = SessionManager(Dict{String,JuliaSession}(),
                                  Dict{String,Task}(),
                                  ReentrantLock())

const TEMP_KEY = "__temp__"

_key(env_path::Union{String,Nothing}) = env_path === nothing ? TEMP_KEY : abspath(env_path)

# Return the live Julia session for `env_path`, creating one if needed. Creation
# is SINGLE-FLIGHT per key: concurrent callers for the same env_path share ONE
# in-flight build instead of each spawning a duplicate worker. The slow part
# (`build_session!` → `start!`, which spawns + dials a Malt worker) runs in the
# build task OUTSIDE `m.lock`, so DIFFERENT projects still come up concurrently
# while the SAME project funnels to one worker. Replaces the old per-key
# `create_locks` registry (one ReentrantLock per env_path, never freed) — and
# unifies `m.sessions` access onto the single `m.lock` the other accessors use.
function get_or_create!(m::SessionManager, env_path::Union{String,Nothing};
                        julia_cmd::Union{String,Nothing} = nothing)
    key = _key(env_path)
    while true
        task = @lock m.lock begin
            existing = get(m.sessions, key, nothing)
            # Live session matching the requested julia_cmd → done (common path).
            existing !== nothing && is_alive(existing) && existing.julia_cmd == julia_cmd &&
                return existing
            # Else join the in-flight build for this key, or start one. The session
            # we're superseding (dead / wrong julia_cmd, or nothing) is handed to
            # the build task to reap.
            t = get(m.creating, key, nothing)
            if t === nothing
                t = @async build_session!(m, key, env_path, julia_cmd, existing)
                m.creating[key] = t
            end
            t
        end
        # Await the build OUTSIDE the lock. A failed build rethrows here; the task
        # already pruned `creating[key]`, so a later call retries cleanly.
        s = fetch(task)::JuliaSession
        # The build we joined may have been started for a different julia_cmd by a
        # caller that asked first; if so, loop and start our own (replacing it).
        is_alive(s) && s.julia_cmd == julia_cmd && return s
    end
end

# The single-flight build body — runs as the `creating[key]` task. Reaps the
# superseded session, builds + starts a fresh one, then publishes it and clears
# the in-flight marker atomically. On failure it clears the marker (so a retry
# starts clean) and tears down any half-started worker before rethrowing.
function build_session!(m::SessionManager, key::String, env_path::Union{String,Nothing},
                        julia_cmd::Union{String,Nothing}, stale::Union{JuliaSession,Nothing})
    s = nothing
    try
        # Reap the session we're replacing (dead or julia_cmd-mismatch), off the
        # lock — killing does I/O. `kill_session!` is idempotent, so racing a
        # concurrent `restart!` on the same session is harmless.
        stale === nothing || kill_session!(stale)

        is_temp = env_path === nothing
        env_dir = is_temp ? mktempdir(; prefix = "bonitoagents-mcp-") : abspath(env_path)
        # Temp envs are otherwise empty, so `using Bonito` on the Malt worker
        # falls back to the user depot and resolves the REGISTERED Bonito — which
        # lacks the remote-app proxy API (`id_prefix`, …) RemoteProxy.jl needs.
        # Seed the temp env with a path-dep on BonitoMCP's own Bonito so the
        # worker resolves the SAME one. Best-effort: if Bonito can't be located,
        # bt_show_app fails loudly but bt_julia_eval still works in the bare env.
        is_temp && seed_temp_env_with_bonito!(env_dir)
        is_test = !is_temp && basename(rstrip(env_dir, '/')) == "test"
        s = JuliaSession(env_dir; is_temp, is_test, julia_cmd)
        start!(s)
    catch
        @lock m.lock delete!(m.creating, key)
        s === nothing || (try kill_session!(s) catch end)
        rethrow()
    end
    @lock m.lock begin
        m.sessions[key] = s
        delete!(m.creating, key)
    end
    return s
end

# Pure lookup — never creates, replaces, or kills a session. `bt_julia_continue`
# / `bt_julia_interrupt` MUST use this: routing them through `get_or_create!`
# (with `julia_cmd=nothing`) would kill+replace the very session carrying the
# in-flight eval on a `julia_cmd` mismatch or a transiently dead worker, then
# error "No eval in flight" (M5). Errors if the session is absent.
function lookup_session(m::SessionManager, env_path::Union{String,Nothing})
    key = _key(env_path)
    @lock m.lock begin
        haskey(m.sessions, key) || error(
            "No Julia session for $(env_path === nothing ? "<temp>" : env_path) — " *
            "nothing to continue/interrupt. Start one with bt_julia_eval.")
        return m.sessions[key]
    end
end

function restart!(m::SessionManager, env_path::Union{String,Nothing})
    key = _key(env_path)
    @lock m.lock begin
        haskey(m.sessions, key) || return nothing
        kill_session!(m.sessions[key])
        delete!(m.sessions, key)
    end
    return nothing
end

"""
    reset_eval_dialback!(m::SessionManager = manager(), env_path = nothing)

Drop the live-render dial-back WITHOUT killing the session: the warm Malt worker
and its compiled state survive, but its `RemoteProxy` bridge is torn down
(`stop_dial!`) and `s.dialed_back` flips false, so the NEXT eval re-dials to
whatever server is current. This is the eval-side parallel of
`reset_ctrl_dialback!`: an MCP host / dev_server that goes away re-points the dial
rather than leaving the worker bridged to a dead server. `env_path === nothing`
resets every session. Keeping the worker warm is the point — re-`start!`ing it
(as `restart!` does) would re-pay the eval env's compile cost.
"""
function reset_eval_dialback!(m::SessionManager = manager(),
                              env_path::Union{AbstractString,Nothing} = nothing)
    targets = @lock m.lock begin
        env_path === nothing ? collect(values(m.sessions)) :
            (haskey(m.sessions, _key(env_path)) ? JuliaSession[m.sessions[_key(env_path)]] : JuliaSession[])
    end
    for s in targets
        reset_eval_dialback!(s)
    end
    return nothing
end

function reset_eval_dialback!(s::JuliaSession)
    @lock s.lock begin
        s.dialed_back || return nothing
        if is_alive(s)
            try
                Malt.remote_eval_fetch(s.worker, quote
                    isdefined(Main, :RemoteProxy) && isdefined(Main.RemoteProxy, :stop_dial!) &&
                        Main.RemoteProxy.stop_dial!()
                    nothing
                end)
            catch e
                @warn "reset_eval_dialback!: worker bridge teardown failed (continuing)" exception = e
            end
        end
        s.dialed_back = false
    end
    return nothing
end

list_sessions(m::SessionManager) = @lock m.lock begin
    [(env_path = s.env_path,
      alive    = is_alive(s),
      temp     = s.is_temp,
      julia_cmd = s.julia_cmd,
      in_flight = s.in_flight !== nothing)
     for s in values(m.sessions)]
end

function shutdown!(m::SessionManager)
    @lock m.lock begin
        for s in values(m.sessions)
            try kill_session!(s) catch end
        end
        empty!(m.sessions)
    end
    return nothing
end

# Pkg-aware: when no explicit timeout was passed and the code uses `Pkg.*`,
# disable the soft-timeout — Pkg installs are routinely multi-minute and the
# default 30s checkpoint cadence would be noise. Explicit user timeout always
# wins. Pass `timeout = 0` (or anything ≤ 0) to disable.
function effective_timeout(code::AbstractString,
                            requested::Union{Real,Nothing})::Union{Real,Nothing}
    if requested === nothing
        return occursin(PKG_PATTERN, code) ? nothing : DEFAULT_TIMEOUT
    end
    return requested > 0 ? requested : nothing
end

# The process-wide session manager + accessor `manager()` live on the one
# `SERVER` context (see context.jl).
