"""
TestKit: realistic end-to-end test harness for BonitoAgents.

The whole production stack runs unchanged (real `dev_server`, real worker, real
subprocess spawn, real ACP JSON-RPC over the worker WebSocket, real websockets).
The ONLY thing swapped is the agent: the test enables the `MockAgent` provider
(`BT_ENABLE_MOCK_AGENT`) and makes it the default (`BT_DEFAULT_PROVIDER`), so the
worker spawns the `MockACP` package (`julia -m MockACP`) like any other provider —
no bash wrapper, no `agent_bin` override. MockACP runs in "dispatcher" mode: it
dials back to a TCP dispatcher in THIS process, which invokes a user-supplied
`agent::Function` per prompt and translates its returned event list into the ACP
frames the chat would have seen from real claude.

Usage:

    using TestKit

    server = dev_server(agent = msg -> [
        text("I'll edit that file."),
        edit("/sim/foo.jl", "old contents", "new contents"),
        text("Done."),
    ])
    try
        open_browser(server)
        navigate(server, "/")
        new_chat(server)
        send_message(server, "please edit foo.jl")
        wait_for(server, "tool message landed",
                 \"\"\"document.querySelector('.bt-tool-msg[data-msg-id]')\"\"\")
        screenshot(server, "/tmp/edit-tool.png")
        click(server, ".bt-tool-msg .bt-tool-header")
        screenshot(server, "/tmp/edit-tool-expanded.png")
    finally
        close(server)
    end

Event constructors (`text`, `edit`, `bash`, `thought`, `end_turn`) build a
small DSL the dispatcher serialises to JSON for the mock binary.

STRICT E2E POLICY (see CONVENTIONS.md "E2E tests — STRICT policy"): drive
EVERYTHING through this harness — `dev_server` + a real electron browser by URL
(`open_browser`/`new_chat`/`send_message`/`click`/`wait_for`/`eval_js`), asserting
ONLY on the rendered DOM, exactly as a user would. Do NOT hand-spawn Malt/eval
workers, call `*_handler`/`render_eval_html`/internals, or otherwise bypass the
chat inside an e2e test. Eval packages → a committed test env (e.g. `test/evalenv`)
+ warmup, never a runtime-built tmp project.
"""
module TestKit

using JSON, Sockets, Base64
import BonitoAgents as BT
import BonitoMCP
import BonitoWorker
import ElectronCall
const ECT = ElectronCall.Testing   # browser driving: open_window/eval_js/wait_for/screenshot

export TestServer, dev_server, add_worker!,
       text, user, thought, edit, bash, todo, usage, commands, delay, tool, tool_update, REPLAY_FN,
       post_turn,
       sub_text, sub_tool,
       diff_block, text_block, error_reply, crash, end_turn,
       mcp_call, bt_eval, bt_continue,
       open_browser, navigate, to_dashboard, new_chat, open_chat,
       send_message, switch_agent, set_window_size, click, click_until, click_text, set_input,
       exit_success,
       screenshot, eval_js, wait_for, current_chat_id,
       js_errors, clear_js_errors

# ── Event DSL ──────────────────────────────────────────────────────────────
# Each constructor returns a small `Dict` carrying the event type + payload.
# The mock binary's dispatcher loop maps these to ACP frames.

text(s::AbstractString)                 = Dict("type" => "text",    "text"  => String(s))
# A replayed USER turn — only meaningful inside a `REPLAY_FN` script (the
# session/load history the mock re-streams); prompts never produce user events.
user(s::AbstractString)                 = Dict("type" => "user",    "text"  => String(s))

"""
    post_turn(events; delay_ms = 300) -> Dict

Agent event carrying frames the mock emits BETWEEN TURNS — `delay_ms` after the
prompt response, with no turn open. Mirrors the real wire (see
test/fixtures/bg_subagent_wire.jsonl): a background subagent's tagged activity
(`sub_text`/`sub_tool`) keeps flowing after end_turn, and the main agent's
auto-wake completion announcement arrives as untagged `text`.
"""
post_turn(events::Vector; delay_ms = 300) =
    Dict{String,Any}("type" => "post_turn", "events" => events,
                     "delay_ms" => Float64(delay_ms))

# Scripted `session/load` replay: `REPLAY_FN[]` maps a session id to the event
# list (user/text/thought/tool) the mock re-streams as the resumed session's
# history — how the real agent replays its jsonl. Default: no replay, which is
# what every pre-existing resume test expects. Set per test, reset in `finally`.
const REPLAY_FN = Ref{Function}(sid -> Any[])
thought(s::AbstractString)              = Dict("type" => "thought", "text"  => String(s))
edit(path, old, new; id = nothing)      = begin
    d = Dict{String,Any}("type" => "edit", "path" => String(path),
                          "old" => String(old), "new" => String(new))
    id === nothing || (d["id"] = String(id))
    d
end
bash(command, output; id = nothing) = begin
    d = Dict{String,Any}("type" => "bash", "command" => String(command),
                          "output" => String(output))
    id === nothing || (d["id"] = String(id))
    d
end
"""
    mcp_call(tool; id = nothing, args...) -> Dict

Agent event that runs the REAL BonitoMCP handler for the bare tool name
`tool` exactly the way the real chat does it: Malt worker per `env_path`,
real `--project` activation, real captured stdout/value/errors. The
dispatcher executes it in the test process and pipes the resulting MCP
content blocks back to the mock as ACP tool_call frames announced under
`mcp__btworker__<tool>`. `args` are the tool arguments (`nothing`-valued
ones are dropped; `env_path = nothing` opts into BonitoMCP's ephemeral-temp
session, same as the default in production). `bt_eval` / `bt_continue` are
sugar over this.
"""
mcp_call(tool::AbstractString; id = nothing, args...) = begin
    d = Dict{String,Any}("type" => "mcp_call", "tool" => String(tool))
    id === nothing || (d["id"] = String(id))
    for (k, v) in pairs(args)
        v === nothing || (d[String(k)] = v)
    end
    d
end
bt_eval(code; env_path = nothing, id = nothing, timeout = nothing) =
    mcp_call("bt_julia_eval"; id, code = String(code), env_path, timeout)
# bt_julia_continue reattaches to the in-flight eval after a soft-timeout
# checkpoint — its call carries NO code argument, exactly like real claude.
bt_continue(; env_path = nothing, timeout = nothing, id = nothing) =
    mcp_call("bt_julia_continue"; id, env_path, timeout)

# Content-block specs for the generic `tool` event. `diff_block` renders as a
# Monaco DiffEditor; `text_block` as a tool text block (grep-style lines render
# as search rows; `"<label>:\n<body>"` with label in stdout/result/error/stderr
# renders as a bt_julia_eval section).
diff_block(path, old, new) = Dict("type" => "diff", "path" => String(path),
                                  "old" => String(old), "new" => String(new))
text_block(s::AbstractString) = Dict("type" => "text", "text" => String(s))

"""
    tool(; kind, title, status, content, tool_name, id, complete, open_status,
           raw_input) -> Dict

Agent event for a generic tool call of any `kind` ("edit", "search",
"execute", "other"). `content` is a vector of `diff_block` / `text_block`.
Pass `complete = false` to leave the bubble live (open) for follow-up
`tool_update`s; `open_status` sets the opening status (default "in_progress").
`raw_input` is the tool call's argument dict (ACP's `rawInput`) — it rides the
opening `tool_call` frame and feeds the eval extras (code preview, ⏱ timeout
badge, ⊗ stop) and the ✎ editable-path derivation. Real claude-agent-acp
STREAMS tool input, so the common shape is to open with an EMPTY `raw_input`
and ship the real args on a later [`tool_update`](@ref) (which also forwards
`raw_input`).
"""
tool(; kind = "other", title = "tool", status = "completed", content = Any[],
       tool_name = nothing, id = nothing, complete = true,
       open_status = "in_progress", raw_input = nothing) = begin
    d = Dict{String,Any}("type" => "tool", "kind" => String(kind),
                         "title" => String(title), "status" => String(status),
                         "content" => content, "complete" => complete,
                         "open_status" => String(open_status))
    id        === nothing || (d["id"]        = String(id))
    tool_name === nothing || (d["tool_name"] = String(tool_name))
    raw_input === nothing || (d["raw_input"] = Dict{String,Any}(raw_input))
    d
end

"""
    tool_update(id; status, content, raw_input) -> Dict

Agent event that updates an already-open tool (matched by `id`) — flip its
status and/or ship more content, without restating its identity. `raw_input`
streams (merges) the tool call's arguments AFTER the announcement, exactly the
way real claude-agent-acp delivers tool input: ACP merges it into the live
`MCPCall`/`GenericTool`, so the eval extras (code preview, ⏱, ⊗) and the ✎
editable-path hint materialise on this in-flight update rather than the empty
opening header.
"""
tool_update(id; status = nothing, content = nothing, raw_input = nothing) = begin
    d = Dict{String,Any}("type" => "tool_update", "id" => String(id))
    status    === nothing || (d["status"]    = String(status))
    content   === nothing || (d["content"]   = content)
    raw_input === nothing || (d["raw_input"] = Dict{String,Any}(raw_input))
    d
end

"""
    sub_text(parent_id, s) -> Dict

Agent event that emits the SAME `agent_message_chunk` frame as [`text`](@ref)
but tagged `_meta.claudeCode.parentToolUseId = parent_id` — the way
claude-agent-acp forwards a running SUBAGENT's prose. The chat must route it
into the parent Task bubble's activity feed, never the main transcript.
"""
sub_text(parent_id, s::AbstractString) = Dict{String,Any}(
    "type" => "sub_text", "parent" => String(parent_id), "text" => String(s))

"""
    sub_tool(parent_id; kind, title, status, id, update = false) -> Dict

Agent event that emits a subagent TOOL frame tagged with
`_meta.claudeCode.parentToolUseId = parent_id`: a `tool_call` announcement by
default, or (with `update = true`) a `tool_call_update` that flips the
already-announced sub-tool's status — mirroring the frames claude-agent-acp
forwards for a subagent's tool use. Feeds the parent Task bubble's activity
feed (one entry per sub-tool id, status rewritten in place).
"""
sub_tool(parent_id; kind = "other", title = "tool", status = "in_progress",
         id = nothing, update = false) = begin
    d = Dict{String,Any}("type" => "sub_tool", "parent" => String(parent_id),
                         "kind" => String(kind), "title" => String(title),
                         "status" => String(status), "update" => update)
    id === nothing || (d["id"] = String(id))
    d
end

"""
    todo(entries) -> Dict

Agent event that emits a `plan` SessionUpdate (the channel real
claude-agent-acp uses for todos). `entries` is a vector of NamedTuples with
`content`, `status` ("pending" | "in_progress" | "completed") and an optional
`priority` ("high" | "medium" | "low", default "medium"). Re-emitting mutates
the one live list in the taskbar; pair with `delay` to hold the turn open
while asserting against the live panel.
"""
todo(entries::AbstractVector) = Dict("type" => "todo",
    "entries" => [Dict("content"  => String(e.content),
                       "status"    => String(e.status),
                       "priority"  => String(get(e, :priority, "medium"))) for e in entries])

"""
    usage(used, size; cost = nothing) -> Dict

Agent event that emits a `usage_update` SessionUpdate (context/cost
telemetry, the shape claude-agent-acp ≥ 0.44 sends after every assistant
message). Drives the header context meter.
"""
function usage(used::Integer, size::Integer; cost = nothing)
    ev = Dict{String,Any}("type" => "usage", "used" => used, "size" => size)
    cost === nothing || (ev["cost"] = Float64(cost))
    return ev
end

"""
    commands(cmds) -> Dict

Agent event that emits an `available_commands_update` SessionUpdate (the
complete slash-command set). `cmds` is a vector of NamedTuples with `name`,
`description` and an optional `hint` (argument hint) — the shape the composer
autocomplete consumes.
"""
commands(cmds::AbstractVector) = Dict("type" => "commands",
    "commands" => [begin
            hint = get(c, :hint, nothing)
            d = Dict{String,Any}("name" => String(c.name),
                                 "description" => String(c.description))
            d["input"] = hint === nothing ? nothing : Dict("hint" => String(hint))
            d
        end for c in cmds])

"""
    delay(ms) -> Dict

Agent event that sleeps `ms` milliseconds in the mock WITHOUT ending the
turn, so frames already emitted (a pinned todo, an in-progress tool) stay
live while the test asserts against them.
"""
delay(ms::Real) = Dict("type" => "delay", "ms" => Float64(ms))

"""
    error_reply(message) -> Dict

Agent event: answer the prompt with a JSON-RPC error (the agent is alive but
failed). The chat renders an inline `[error: <message>]` bubble.
"""
error_reply(message::AbstractString) = Dict("type" => "error_reply", "message" => String(message))

"""
    crash() -> Dict

Agent event that HARD-KILLS the mock agent subprocess mid-prompt (`exit(1)`),
exactly like a real claude-agent-acp dying. No `session/prompt` response is
ever sent, so the chat's pending read fails with EOFError/ConnectionClosed →
`is_session_dead_error` → `session_alive` flips false and the header restart
button gains its dead/pulse class (`.bt-header-restart-dead`). Clicking it runs
`restart_chat_session!`, which respawns a fresh mock agent and revives the chat.
"""
crash()                              = Dict("type" => "crash")

end_turn(; stopReason = "end_turn")  = Dict("type" => "end", "stopReason" => String(stopReason))

# Normalise whatever the agent function returned into a Vector{Dict}. The
# convention is "missing `end` event = auto-append end_turn".
function normalise(events)
    out = Dict[]
    if events isa AbstractDict
        push!(out, events)
    elseif events isa AbstractString
        push!(out, text(events))
    else
        for e in events
            e isa AbstractDict || error("TestKit: agent event must be a Dict, got $(typeof(e))")
            push!(out, e)
        end
    end
    if isempty(out) || String(get(last(out), "type", "")) != "end"
        push!(out, end_turn())
    end
    return out
end

# ── TestServer ────────────────────────────────────────────────────────────

mutable struct TestServer
    h::BT.DevHandle
    agent_fn::Ref{Function}            # mutable so tests can swap mid-run
    dispatcher_sock::Sockets.TCPServer
    dispatcher_port::Int
    dispatcher_task::Task
    # Browser handle, lazily opened by `open_browser` so headless server
    # tests (no GUI) don't pay the Electron cost.
    browser::Ref{Any}                  # ElectronCall.Testing.TestContext | nothing
    closed::Ref{Bool}
end

# The dispatcher's TCP server starts BEFORE `dev_server` returns so the
# worker can connect back the moment it spawns a mock agent. But
# `bt_eval` needs the server URL + worker-secret to point the eval
# bridge at — these are known only after `dev_server` returns. Stash
# them in a Ref the dispatcher reads each time it invokes a real
# BonitoMCP handler. `nothing` until `TestServer` finishes wiring up.
const SERVER_CONTEXT = Ref{Union{Nothing, NamedTuple{(:url, :secret, :project_id), Tuple{String, String, Ref{String}}}}}(nothing)

"""
    scrub_mock_env!()

Remove a previous mock `dev_server`'s ENV leftovers from this process. The
mock knobs are only meaningful to the mock provider, EXCEPT
`BT_DEFAULT_PROVIDER`, which is a general knob — only remove it when it holds
a value the mock path itself set (a user's own `BT_DEFAULT_PROVIDER=MiMoCode`
stays untouched).
"""
function scrub_mock_env!()
    for k in ("BT_ENABLE_MOCK_AGENT", "BT_MOCK_ACP_SCENARIO",
              "BT_MOCK_ACP_DISPATCHER", "BT_MOCK_PROJECT",
              "BT_MOCK_ACP_IGNORE_CANCEL")
        delete!(ENV, k)
    end
    get(ENV, "BT_DEFAULT_PROVIDER", "") in ("MockCode", "MockCode2") &&
        delete!(ENV, "BT_DEFAULT_PROVIDER")
    return nothing
end

"""
    dev_server(; agent = msg -> end_turn(), port = nothing, kwargs...) -> TestServer

Start a real BonitoAgents dev server, swap the worker's `claude-agent-acp`
with the mock script, and route every prompt back to `agent`. The
returned `TestServer` is the handle every helper takes as its first arg.

`mock = false` keeps the worker on its REAL default provider (an actual
`claude-agent-acp` from PATH / `CLAUDE_AGENT_ACP`) while still returning a
`TestServer` with all the browser/eval helpers — used to seed genuine agent
sessions (e.g. the docs-walkthrough rig); `agent` is then ignored.
"""
function dev_server(; agent::Function = (_msg -> end_turn()),
                      port::Union{Int,Nothing} = nothing,
                      browser_width::Int  = 1280,
                      browser_height::Int = 820,
                      ignore_cancel::Bool = false,
                      mock::Bool = true,
                      kwargs...)
    ensure_display!()
    agent_ref = Ref{Function}(agent)

    # 1. Stand up the TCP dispatcher BEFORE we start the dev server, so the
    #    moment the worker spawns a mock agent for the first chat it can
    #    connect back without retry. (Harmlessly idle when mock = false.)
    sock = listen(Sockets.IPv4(0x7f000001), 0)   # 127.0.0.1:<auto>
    disp_port = Sockets.getsockname(sock)[2]
    dispatcher_task = Base.errormonitor(@async begin
        while isopen(sock)
            client = try accept(sock) catch; break end
            Base.errormonitor(@async handle_client(client, agent_ref))
        end
    end)

    # 2. Enable the mock as a real, selectable provider. It is no longer a bash
    #    wrapper handed to the worker as `agent_bin` — it's the AgentProviders
    #    `MockAgent` descriptor, which launches the `MockACP` package
    #    (`julia -m MockACP`) like any other agent. We just:
    #      • include it in the provider list   (BT_ENABLE_MOCK_AGENT)
    #      • make it the test env's default     (BT_DEFAULT_PROVIDER=MockCode)
    #      • point MockACP at THIS process's dispatcher socket + scenario
    #      • tell it which project resolves MockACP (the BonitoAgents test env)
    #    These reach BOTH the server (this process) and the worker (its child)
    #    because `dev_server` writes `agent_env` into `ENV` before spawning the
    #    worker, which inherits it (and the spawned MockACP inherits it in turn).
    test_env = abspath(joinpath(@__DIR__, ".."))   # .../BonitoAgents/test — where MockACP is a dep
    agent_env = mock ? Dict{String,String}(
        "BT_ENABLE_MOCK_AGENT"   => "1",
        "BT_DEFAULT_PROVIDER"    => "MockCode",
        "BT_MOCK_ACP_SCENARIO"   => "dispatcher",
        "BT_MOCK_ACP_DISPATCHER" => "127.0.0.1:$(disp_port)",
        "BT_MOCK_PROJECT"        => test_env,
    ) : Dict{String,String}()
    # `BT.dev_server` copies `agent_env` into the PROCESS ENV (so the worker
    # subprocess inherits it) — which means a prior mock dev_server in this
    # same Julia process left all of the above behind. A later `mock = false`
    # server must not inherit that: its chats would default to MockCode and
    # the spawned MockACP would dial the DEAD dispatcher port of the closed
    # mock server ("ACP connection closed" on every bind, no agent stderr
    # anywhere near the failure). Scrub the mock leftovers before starting.
    mock || scrub_mock_env!()
    # Opt-in: make the mock IGNORE `session/cancel` (wedged-agent simulation) so a
    # test can drive the chat's re-cancel → force-close escalation.
    ignore_cancel && (agent_env["BT_MOCK_ACP_IGNORE_CANCEL"] = "1")

    h = BT.dev_server(; port = port, agent_env = agent_env, kwargs...)
    sleep(0.8)   # let the worker WS dial in before tests start poking
    # Now publish the server URL + secret to the dispatcher so that
    # `bt_eval` invocations can route the eval worker's dial-back to the
    # right BonitoAgents instance.
    SERVER_CONTEXT[] = (url = h.url, secret = h.secret, project_id = Ref(""))
    # Clean slate for the MCP control dial-back (armed lazily on the first eval,
    # see invoke_mcp) in case a prior test tore down without close().
    try BonitoMCP.reset_ctrl_dialback!() catch end

    return TestServer(h, agent_ref, sock, disp_port, dispatcher_task,
                       Ref{Any}(nothing), Ref(false))
end

# Dispatcher loop per mock-agent connection. Reads one `{"prompt": "..."}`
# per session/prompt, invokes the agent function, streams the resulting
# events back as line-delimited JSON. For high-level events that need
# real MCP execution (`bt_eval`), the dispatcher runs the corresponding
# BonitoMCP handler IN THIS PROCESS, then forwards the result blocks to
# the mock as a `bt_eval_result` event the mock knows how to wrap as ACP
# tool_call frames. This keeps the bt_* execution real (same Malt worker,
# same env_path, same package resolution) without making the mock binary
# itself an MCP client.
function handle_client(client, agent_ref::Ref{Function})
    try
        while !eof(client)
            line = try readline(client) catch; break end
            isempty(line) && continue
            msg = JSON.parse(line)
            # session/load replay request: serve the scripted history for this
            # session id (REPLAY_FN, default empty) and terminate the stream.
            if haskey(msg, "replay")
                events = try
                    Base.invokelatest(REPLAY_FN[], String(msg["replay"]))
                catch e
                    @warn "TestKit REPLAY_FN threw" exception = e
                    Any[]
                end
                for ev in events
                    println(client, JSON.json(ev)); flush(client)
                end
                println(client, JSON.json(Dict("type" => "end"))); flush(client)
                continue
            end
            prompt = String(get(msg, "prompt", ""))
            # On a resumed session the server prepends a transcript of the prior
            # conversation, with the user's real new message after a "My new
            # message:" divider. A real agent reads the transcript and replies to
            # the new message; the scripted test agents instead branch on the
            # prompt text, so hand them ONLY the new message — otherwise replayed
            # history (e.g. a past "crash now") would wrongly re-trigger them.
            if occursin("My new message:", prompt)
                prompt = String(strip(last(split(prompt, "My new message:"; limit = 2))))
            end
            response = try
                # invokelatest so tests can swap `agent_fn` mid-run (the
                # dispatcher task is spawned before those closures exist).
                normalise(Base.invokelatest(agent_ref[], prompt))
            catch e
                # Surface the test's agent-fn crash in the chat as a
                # synthetic agent message, so the test still sees something
                # rather than the prompt hanging forever.
                [text("agent fn threw: $(sprint(showerror, e))"), end_turn()]
            end
            for ev in response
                forward_event(client, ev)
            end
        end
    catch e
        e isa Base.IOError || @warn "TestKit dispatcher client crashed" exception=e
    finally
        try close(client) catch end
    end
end

# Per-event dispatch — high-level events get rewritten into the lower-level
# `bt_eval_result` event the mock knows how to map to ACP frames; everything
# else is forwarded verbatim.
function forward_event(client, ev::AbstractDict)
    t = String(get(ev, "type", ""))
    if t == "mcp_call"
        invoke_mcp(client, ev)
    else
        println(client, JSON.json(ev)); flush(client)
    end
end

# Run BonitoMCP.julia_eval_handler with the args from the event. The
# handler spawns / reuses a Malt worker keyed by `env_path`, executes the
# code with `--project=$env_path`, and returns MCP content blocks +
# isError. We forward those to the mock as a structured event the mock
# turns into ACP `tool_call` + `tool_call_update` frames carrying the
# same content.
# Point the eval worker's dial-back at OUR dev_server (url / secret / project_id)
# for the duration of `f`, then restore. `bt_eval` needs this:
# the worker inherits these env vars when `get_or_create!` spawns it, and
# `ensure_eval_dialed!` uses them to (a) load `RemoteProxy` + build the bridge —
# which is what makes `render_eval_html` available so the result renders to a LIVE
# fragment instead of the text fallback — and (b) land the bridge in
# `EVAL_WORKERS[project_id]`, the dict the chat looks up when mounting. Without
# `BONITOAGENTS_SERVER_URL` the dial bails early (session.jl) and RemoteProxy
# never loads. The project_id MUST match the chat's pid (the EVAL_WORKERS key).
function with_bridge_env(ctx, f)
    keys = ("BONITOAGENTS_SERVER_URL", "BONITOAGENTS_SECRET", "BONITOAGENTS_PROJECT_ID")
    prev = map(k -> get(ENV, k, nothing), keys)
    ENV["BONITOAGENTS_SERVER_URL"] = ctx.url
    ENV["BONITOAGENTS_SECRET"]     = ctx.secret
    isempty(ctx.project_id[]) || (ENV["BONITOAGENTS_PROJECT_ID"] = ctx.project_id[])
    try
        return f()
    finally
        for (k, v) in zip(keys, prev)
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end

function invoke_mcp(client, ev::AbstractDict)
    tool = String(get(ev, "tool", "bt_julia_eval"))
    # Everything besides the event bookkeeping IS the tool's argument dict —
    # `mcp_call` sugar (bt_eval / bt_continue) puts args at the top level.
    args = Dict{String,Any}(String(k) => v for (k, v) in ev
                            if String(k) ∉ ("type", "tool", "id"))

    tool_id = String(get(ev, "id", "te_$(rand(UInt32))"))
    # Real claude opens the tool bubble BEFORE the MCP call runs, streams the
    # args on an update, and the status stays PENDING for the whole call —
    # that's what the chat's live affordances (compact code preview, stdout
    # stream tail, stop button, elapsed clock) key on. Announce first, run after.
    open_ev = Dict{String,Any}(
        "type" => "bt_eval_open", "tool_id" => tool_id,
        "tool" => "mcp__btworker__" * tool,
        "code" => String(get(ev, "code", "")),
        "env_path" => get(ev, "env_path", nothing))
    haskey(ev, "timeout") && (open_ev["timeout"] = ev["timeout"])
    println(client, JSON.json(open_ev)); flush(client)

    ctx = SERVER_CONTEXT[]
    runner() = tool == "bt_julia_continue" ?
        BonitoMCP.julia_continue_handler(args) : BonitoMCP.julia_eval_handler(args)
    # Faithful MCP-process behaviour: arm the /mcp-ws control dial-back (idempotent)
    # so the eval's live stdout streams over the REAL wire to the chat's tail, same
    # as production. Env vars (incl. project_id) are set by with_bridge_env, which
    # start_ctrl_dialback! reads synchronously; the async dial connects well before
    # the worker's first print. reset_ctrl_dialback! (dev_server/close) re-points it.
    armed() = (BonitoMCP.start_ctrl_dialback!(); runner())
    result = try
        # `ctx === nothing` is the standalone case (no live bridge → text fallback,
        # still a valid result). With a server context, wire the dial-back so the
        # result renders to a LIVE Bonito fragment over the eval bridge.
        ctx === nothing ? runner() : with_bridge_env(ctx, armed)
    catch e
        Dict{String,Any}(
            "content" => Any[Dict("type" => "text",
                                   "text" => "TestKit mcp_call crash: $(sprint(showerror, e))")],
            "isError" => true,
        )
    end

    out = Dict{String,Any}(
        "type"     => "bt_eval_result",
        "tool_id"  => tool_id,
        "tool"     => "mcp__btworker__" * tool,
        "code"     => String(get(ev, "code", "")),
        "env_path" => get(ev, "env_path", nothing),
        "content"  => get(result, "content", Any[]),
        "is_error" => Bool(get(result, "isError", false)),
        "opened"   => true,   # bt_eval_open already emitted the pending frames
    )
    println(client, JSON.json(out)); flush(client)
end

"""
    add_worker!(s; name = "worker-extra") -> Base.Process

Spawn an ADDITIONAL worker process against the same dev server (its own config
dir + projects root, same server url + secret), exactly as a second machine
running the installer would. Returns the worker process so the test can later
`kill` it to simulate that machine going offline.
"""
function add_worker!(s::TestServer; name::AbstractString = "worker-extra")
    cfg  = mktempdir(prefix = "bonitoagents-test-wcfg2-")
    root = mktempdir(prefix = "bonitoagents-test-w2root-")
    prev = get(ENV, "BONITOAGENTS_CONFIG_DIR", nothing)
    ENV["BONITOAGENTS_CONFIG_DIR"] = cfg
    # A distinct, pinned worker id so it registers as a separate worker.
    write(joinpath(cfg, "worker_id"), "test-" * String(name) * "-" * string(rand(UInt32); base = 16))
    BonitoWorker.write_config!(; server_url = s.h.url, secret = s.h.secret,
                                 projects_root = root, name = String(name))
    proc, _ = BonitoWorker.spawn_worker()
    prev === nothing ? delete!(ENV, "BONITOAGENTS_CONFIG_DIR") : (ENV["BONITOAGENTS_CONFIG_DIR"] = prev)
    return proc
end

function Base.close(s::TestServer)
    s.closed[] && return s
    s.closed[] = true
    # Tear down the MCP dial-backs this process armed for `s` (see invoke_mcp):
    # the test process stands in for one MCP server per dev_server, so both its
    # /mcp-ws control dial AND every eval worker's /eval-ws render dial must be
    # re-pointed, not left dangling on this dead server. `reset_eval_dialback!`
    # keeps the warm eval workers alive (just drops their bridge) so the NEXT
    # dev_server re-dials fresh — this replaces the old `refresh_eval_session!`
    # test hack, tying eval-session lifecycle to the dev_server like production
    # ties it to the agent's MCP child.
    try BonitoMCP.reset_ctrl_dialback!() catch end
    try BonitoMCP.reset_eval_dialback!() catch end
    ctx = s.browser[]
    ctx === nothing || close(ctx)                 # ECT.close is itself best-effort
    isopen(s.dispatcher_sock) && close(s.dispatcher_sock)
    close(s.h)
    return s
end

"""
    exit_success()

Force-terminate the test process with code 0, bypassing Julia's atexit/thread
join. Call as the LAST line of an e2e script: the @testset has already printed
its result (a failing one throws first, so reaching here means it passed), but a
degraded headless Electron / wedged Reseau poller thread can stall Julia's
normal shutdown so the process never exits on its own. `_exit` sidesteps that.
"""
function exit_success()
    flush(stdout)
    flush(stderr)
    ccall(:_exit, Cvoid, (Cint,), Cint(0))
end

# ── DISPLAY/XAUTHORITY plumbing ────────────────────────────────────────────
# Subprocesses spawned by claude-agent-acp / the MCP worker don't inherit
# the parent shell's X env. Detect the live X socket + xauth cookie and
# set them so Electron can render into the user's session.
function ensure_display!()
    if isempty(get(ENV, "DISPLAY", ""))
        socks = filter(s -> startswith(s, "X"), readdir("/tmp/.X11-unix"))
        isempty(socks) && return     # no X — caller probably wants headless
        ENV["DISPLAY"] = ":" * first(sort(socks; rev = true))[2:end]
    end
    if isempty(get(ENV, "XAUTHORITY", ""))
        uid = parse(Int, strip(read(`id -u`, String)))
        rdir = "/run/user/$uid"
        if isdir(rdir)
            cands = filter(f -> startswith(f, "xauth"), readdir(rdir; sort = true))
            isempty(cands) || (ENV["XAUTHORITY"] = joinpath(rdir, first(cands)))
        end
    end
    return nothing
end

# ── Browser helpers ───────────────────────────────────────────────────────

"""
    open_browser(s; width = 1280, height = 820, route = "/")

Open one Electron window pointed at the dev server. Idempotent — the
second call closes the prior window and opens a fresh one.
"""
# `offscreen = true` (the DEFAULT) renders via OSR so requestAnimationFrame runs
# at ~60fps instead of the ~1.5fps a plain hidden window's compositor produces —
# the whole e2e suite exercises rAF-paced scroll/animation code, so faithful
# timing is the correct default. Pass `offscreen = false` to opt a specific test
# back onto the plain hidden-window path (e.g. to bisect an OSR-only difference).
function open_browser(s::TestServer; width::Int = 1280, height::Int = 820,
                       route::AbstractString = "/", offscreen::Bool = true)
    ensure_display!()
    old = s.browser[]
    old === nothing || close(old)
    url = "http://127.0.0.1:$(s.h.state.srv.port)$(route)"
    # ElectronCall.Testing.open_window already forces --ozone-platform=x11 and
    # sets backgroundThrottling=false + paintWhenInitiallyHidden=true, so
    # capturePage on the headless (show=false) window stays fresh.
    # `offscreen = true` switches to OSR so requestAnimationFrame runs at ~60fps
    # instead of the ~1.5fps a plain hidden window's compositor produces — needed
    # for tests that exercise rAF-paced scroll timing (momentum, follow-restore).
    # Only pass the kwarg when actually requested: the CI/test env pins a git
    # ElectronCall that predates `offscreen`, so the default path must call the
    # old signature. OSR is opt-in and only resolves against the dev checkout.
    ctx = offscreen ?
        ECT.open_window(url; width = width, height = height, show = false, offscreen = true) :
        ECT.open_window(url; width = width, height = height, show = false)
    s.browser[] = ctx
    ECT.install_error_sink(ctx)   # window.__errs for "no JS errors" assertions
    sleep(3.0)                     # let the dashboard mount + the chat session boot
    install_pane_scope!(s)
    return s
end

# Under the shared runner the chat-pane KeyedList keeps ONE `.bt-chatpane` per
# opened chat in the DOM (only the active one visible) — that's the product's
# fast-switch design. But the suites read message state via global selectors
# like `document.querySelector('.bt-messages')`, which would grab the FIRST
# (often a hidden, stale) pane once more than one chat has been opened.
#
# This shim makes the global `document.querySelector(All)` resolve chat-MESSAGE
# selectors (`.bt-messages`, `.bt-agent-msg`, `.bt-user-msg`, `.bt-tool-*`,
# `.bt-plan-msg`, `.bt-taskbar-*`, `.bt-thinking`, …) within the VISIBLE chat
# pane — i.e. the rendered DOM the user actually sees, which is exactly the
# contract ("scope to its OWN chat"). It falls through to native for every other
# selector, and the app's own JS already scopes `.bt-messages` per-pane
# (`pane.querySelector`), so this never perturbs the product runtime. Installed
# fresh on every `open_browser` (so a reconnect re-arms it).
function install_pane_scope!(s::TestServer)
    eval_js(s, raw"""(() => {
        if (window.__btPaneScopeInstalled) return true;
        window.__btPaneScopeInstalled = true;
        // NB: deliberately NOT scoping `.bt-embed`, `.bw-ws-panel`, `.bt-slot`
        // (app_detach moves embeds OUT of the chat pane into workspace panels —
        // scoping those would hide a detached embed), nor sidebar/dashboard/lens
        // header selectors (single, not per-pane).
        const MSG = /(^|[\s,>])\.bt-(messages|agent-msg|user-msg|tool-msg|tool-title|tool-header|tool-body|tool-status|tool-summary|plan-msg|taskbar|thinking|diff-block|search-row|eval-section|section-label|multi-diff|busy|text-input|send-btn|lens|header-provider)/;
        const visiblePane = () => {
            const panes = [...document.querySelectorAll('.bt-view-chats .bt-chatpane, .bt-chatpane')];
            return panes.find(p => p.offsetParent !== null) || null;
        };
        const wrap = (orig, all) => function(sel) {
            try {
                if (typeof sel === 'string' && MSG.test(sel)) {
                    const p = visiblePane();
                    if (p) return all ? p.querySelectorAll(sel) : p.querySelector(sel);
                }
            } catch (e) {}
            return orig.call(this, sel);
        };
        document.querySelector    = wrap(Document.prototype.querySelector,    false);
        document.querySelectorAll = wrap(Document.prototype.querySelectorAll, true);
        return true;
    })()""")
    return s
end

"""
    eval_js(s, code) -> Any

Run JavaScript in the browser; the value of the last expression is
returned to Julia (via Electron's JSON bridge). Long-running JS should
return primitive types only — no DOM refs.
"""
# Thrown when the Electron bridge doesn't answer within the per-call watchdog.
# TYPED so `wait_for` can tell "bridge was busy for THIS poll" (retry within its
# own budget) apart from a real JS/bridge error (rethrow). A bare `error()` would
# force string-matching at the catch site.
struct BridgeTimeout <: Exception
    secs::Float64
    code::String
end
Base.showerror(io::IO, e::BridgeTimeout) =
    print(io, "eval_js timed out after $(e.secs)s (Electron bridge wedged?): ",
          first(replace(e.code, r"\s+" => " "), 90))

function eval_js(s::TestServer, code::AbstractString; timeout::Real = 20)
    ctx = s.browser[]
    ctx === nothing && error("open_browser first")
    # Hard-bound the bridge round-trip: a wedged/overloaded Electron renderer (e.g.
    # right after a 500-message flood) must NEVER hang the harness. If the bridge
    # doesn't answer in `timeout`s we throw — the caller fails fast instead of the
    # whole run deadlocking. (This is the foundation that makes `wait_for` — and
    # therefore every suite — impossible to deadlock.)
    res = Ref{Any}(nothing); ex = Ref{Any}(nothing); done = Ref(false)
    # @async (thread 1, cooperative): the ECT bridge waits on an IPC response which
    # yields, so this outer watchdog loop still gets scheduled and can time out.
    @async begin
        try; res[] = ECT.eval_js(ctx, String(code)); catch e; ex[] = e; finally; done[] = true; end
    end
    t0 = time()
    while !done[] && time() - t0 < timeout; sleep(0.02); end
    done[] || throw(BridgeTimeout(Float64(timeout), String(code)))
    ex[] === nothing || throw(ex[])
    return res[]
end

"""
    js_errors(s) -> Vector

JavaScript errors captured by the sink installed in `open_browser`
(`window.onerror` + `unhandledrejection`), since the last `clear_js_errors`.
Each entry has `type`/`message` (and maybe `filename`/`lineno`). A non-empty
result means the UI threw during the run — a real bug, not test noise. The
runner gates every suite on this being empty.
"""
function js_errors(s::TestServer)
    s.browser[] === nothing && return Any[]
    # Route through the WATCHDOG eval_js, not ECT.js_errors (whose eval is
    # unbounded): the gate runs right after a suite, and a suite that pegged the
    # renderer (e.g. the 500-row flood) would otherwise hang the gate — and thus
    # the whole runner — waiting for the paint to finish. Bounded: a pegged
    # renderer makes this throw BridgeTimeout, which the runner treats as
    # "couldn't sample, renderer busy" rather than a hang.
    v = eval_js(s, "window.__errs || []"; timeout = 10)
    return v === nothing ? Any[] : v
end

"""
    clear_js_errors(s)

Reset the JS error sink. The runner calls this between suites so an error is
attributed to the suite that actually caused it.
"""
function clear_js_errors(s::TestServer)
    s.browser[] === nothing && return nothing
    # Bounded + best-effort (same reasoning as js_errors): if the renderer is
    # pegged the sink simply clears once it frees; never hang the runner on it.
    try
        eval_js(s, "window.__errs = []; true"; timeout = 10)
    catch e
        e isa BridgeTimeout || rethrow()
    end
    return nothing
end

# (Removed `refresh_eval_session!`.) It `restart!`-ed the whole eval worker at
# each test's START to dodge a stale per-env dial-back — a racy stand-in that
# also threw away warm compile state. The dial-back is now re-pointed at
# dev_server CLOSE (`BonitoMCP.reset_eval_dialback!` in `Base.close(::TestServer)`),
# deterministically and without killing the worker, so tests never need it.

"""
    wait_for(s, label, js_predicate; timeout = 8) -> Bool

Poll `js_predicate` (a JS expression returning truthy/falsy) until it's
truthy or `timeout` seconds elapse. Returns the truthy value (or `false`).
"""
function wait_for(s::TestServer, label::AbstractString, predicate::AbstractString;
                   timeout::Real = 8, interval::Real = 0.1)
    t0 = time()
    code = "(() => { try { return " * String(predicate) * "; } catch (e) { return false; } })()"
    # Per-poll bound is SHORT (≤5s): if the renderer is momentarily pinned (e.g.
    # synchronously rendering a 500-row flood) THIS poll's round-trip is abandoned
    # and we retry within `timeout`, instead of one 20s round-trip eating the whole
    # budget — or worse, throwing and aborting the suite. A genuinely dead bridge
    # makes every poll BridgeTimeout, so we still exhaust `timeout` and throw below
    # (bounded detector intact). Only the bridge-timeout is swallowed; a real
    # eval/bridge error rethrows.
    poll = min(Float64(timeout), 5.0)
    while time() - t0 < timeout
        v = try
            eval_js(s, code; timeout = poll)
        catch e
            e isa BridgeTimeout || rethrow()
            nothing
        end
        v in (false, nothing) || return v
        sleep(interval)
    end
    error("wait_for timed out after $(timeout)s: $label")
end

"""
    click(s, css_selector)

Click the first element matching the CSS selector. Throws if it's missing.
"""
function click(s::TestServer, selector::AbstractString)
    sel = String(selector)
    # Prefer the VISIBLE match. SharedServer keeps other chats' panes mounted but
    # hidden (display:none ⇒ offsetParent null), so a bare `querySelector` on a
    # pane element (`.bt-stop-btn`, `.bt-send-btn`, …) could resolve to a STALE
    # pane and click the wrong chat. Targeting the visible one auto-scopes every
    # click to the active pane, so a test can't leak across panes by accident.
    # Falls back to the first match when nothing is "visible" (e.g. a global
    # dashboard control), preserving old behaviour for non-pane selectors.
    ok = eval_js(s, """(() => {
        const els = [...document.querySelectorAll($(json(sel)))];
        const el = els.find(e => e.offsetParent !== null) || els[0];
        if (!el) return false;
        el.click();
        return true;
    })()""")
    ok === true || error("click: no element matched $sel")
    return s
end

# Click the first visible `selector` repeatedly until `predicate` holds — rides
# out the race where a framework wires the click handler after the element
# mounts (so a lone synthetic click is dropped). Delegates to the ElectronCall
# primitive; errors if the state never appears.
function click_until(s::TestServer, selector::AbstractString, predicate::AbstractString;
                     timeout::Real = 15, interval::Real = 0.3)
    ctx = s.browser[]
    ctx === nothing && error("open_browser first")
    ECT.click_until(ctx, String(selector), String(predicate);
                    timeout = Float64(timeout), interval = Float64(interval)) ||
        error("click_until: '$selector' did not produce the expected state within $(timeout)s")
    return s
end

"""
    navigate(s, route)

Drive the BonitoAgents dashboard to a project / view. `route` can be one of:

  * `"/"`               — root dashboard
  * `"/?pid=<id>"`      — opens the chat for project `<id>` (server pushes
                          `current_view` via its standard URL handling)

For routes that aren't direct URLs, prefer the high-level helpers
(`new_chat`, `open_project`) below.
"""
function navigate(s::TestServer, route::AbstractString)
    base = "http://127.0.0.1:$(s.h.state.srv.port)"
    eval_js(s, "location.href = $(json(base * String(route)))")  # errors if no browser
    sleep(2.0)
    return s
end

# ── UI action primitives ───────────────────────────────────────────────────
# Everything below drives the real UI (clicks, typing) instead of poking
# server-side models, so the tests exercise the same path a user does.

# Visible-only filter: skip elements that are display:none / detached. The
# dashboard keeps several pickers in the DOM at once; only one is shown.
const VIS = "el => el && el.offsetParent !== null"

"Click the first *visible* button whose trimmed text equals `label`."
function click_text(s::TestServer, label::AbstractString)
    ok = eval_js(s, """(() => {
        const b = [...document.querySelectorAll('button')].filter($VIS)
            .find(b => (b.innerText||'').trim() === $(json(String(label))));
        if (!b) return false; b.click(); return true; })()""")
    ok === true || error("click_text: no visible button labelled $(repr(label))")
    return s
end

# Like `click_text` but RE-CLICKS the visible button labelled `label` until
# `predicate` (a JS expression) is truthy — the text-matched twin of
# `click_until`. Rides out the cold-mount race where Bonito wires a button's
# onclick only AFTER it mounts, so the FIRST synthetic click lands before the
# handler attaches and is silently dropped (a lone `click_text` then hangs on a
# form that never opens); the re-click loop also absorbs a slow first
# server-side render of the target UI. Returns the truthy value; errors if the
# state never appears.
function click_text_until(s::TestServer, label::AbstractString, predicate::AbstractString;
                          timeout::Real = 30, interval::Real = 0.4)
    t0 = time()
    clickjs = """(() => {
        const b = [...document.querySelectorAll('button')].filter($VIS)
            .find(b => (b.innerText||'').trim() === $(json(String(label))));
        if (b) b.click(); return true; })()"""
    check = "(() => { try { return " * String(predicate) * "; } catch (e) { return false; } })()"
    while time() - t0 < timeout
        eval_js(s, clickjs)   # (re-)click if present; no-op if the button is gone
        v = try
            eval_js(s, check; timeout = min(Float64(timeout), 5.0))
        catch e
            e isa BridgeTimeout || rethrow()
            nothing
        end
        v in (false, nothing) || return v
        sleep(interval)
    end
    error("click_text_until: '$label' did not produce the expected state within $(timeout)s")
end

"""
    set_input(s, selector, value; placeholder = nothing)

Set the first *visible* input/textarea matching `selector` (optionally narrowed
to one whose placeholder equals `placeholder`) and fire an `input` event so
Bonito handlers run.
"""
function set_input(s::TestServer, selector::AbstractString, value::AbstractString;
                   placeholder::Union{Nothing,AbstractString} = nothing)
    narrow = placeholder === nothing ? "" :
        "els = els.filter(e => (e.placeholder||'') === $(json(String(placeholder))));"
    ok = eval_js(s, """(() => {
        let els = [...document.querySelectorAll($(json(String(selector))))].filter($VIS);
        $narrow
        const el = els[0]; if (!el) return false;
        el.focus();
        const set = Object.getOwnPropertyDescriptor(el.constructor.prototype, 'value').set;
        set.call(el, $(json(String(value))));
        el.dispatchEvent(new Event('input', {bubbles: true}));
        return true; })()""")
    ok === true || error("set_input: no visible element for $(repr(selector))")
    return s
end

"Go to the dashboard by clicking the Home entry in the sidebar."
function to_dashboard(s::TestServer)
    eval_js(s, """(() => { const h = [...document.querySelectorAll('.bt-side-item')]
        .find(e => (e.innerText||'').trim().startsWith('Home')); if (h) h.click(); return true; })()""")
    sleep(0.6)
    return s
end

"""
    new_chat(s; cwd = mktempdir(), title = basename(cwd)) -> String

Create a fresh chat the way a user does: from the dashboard, "+ New project",
type `cwd` into the folder picker, name it, and hit Create. Blocks until the
chat view is open. Returns the new chat's project id.
"""
function new_chat(s::TestServer; cwd::AbstractString = mktempdir(),
                                   title::AbstractString = "")
    name = isempty(title) ? basename(rstrip(String(cwd), '/')) : String(title)
    leaf = json(basename(rstrip(String(cwd), '/')))   # last path segment, for the gate
    to_dashboard(s)
    # RE-CLICK "+ New project" until the name field shows. A lone click can be
    # dropped on a cold/slow first render — Bonito wires the button's onclick
    # only after it mounts, so the first synthetic click lands before the handler
    # attaches and the form never opens (the exact race `click_until` fixes for
    # the ✎ button below; a single `click_text` here left `new_chat` hanging on
    # a cold isolated run). Generous timeout: the FIRST new_chat against a fresh
    # server also compiles the whole new-project / folder-picker UI server-side.
    click_text_until(s, "+ New project",
        "[...document.querySelectorAll('input')].some(e => e.offsetParent && (e.placeholder||'') === 'e.g. my-project')";
        timeout = 30)
    # Flip the breadcrumb to a text field. The ✎ button's onclick (notify
    # `editing=true`) is wired by Bonito only after the element mounts, so on a
    # cold/slow runner a single synthetic click can land before the handler
    # attaches and be lost. `click_until` re-clicks until the input appears.
    click_until(s, ".bt-addr-icon-btn", "[...document.querySelectorAll('.bt-addr-input')].some($VIS)"; timeout = 30)
    ok = eval_js(s, """(() => {
        const inp = [...document.querySelectorAll('.bt-addr-input')].filter($VIS)[0];
        if (!inp) return false;
        inp.focus();
        const set = Object.getOwnPropertyDescriptor(inp.constructor.prototype, 'value').set;
        set.call(inp, $(json(String(cwd))));
        inp.dispatchEvent(new Event('input', {bubbles: true}));
        inp.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', keyCode: 13, bubbles: true}));
        return true; })()""")
    ok === true || error("new_chat: folder path field (.bt-addr-input) not found")
    # Enter commits the path to the picker via an async round-trip. Gate on the
    # breadcrumb actually showing the target folder before "Choose" reads it —
    # otherwise Choose captures the old location and Create fails.
    wait_for(s, "path committed",
        "[...document.querySelectorAll('.bt-addr-bar')].some(b => b.offsetParent && (b.innerText||'').includes($leaf))";
        timeout = 30)
    click_text(s, "Choose")
    set_input(s, "input", name; placeholder = "e.g. my-project")
    click_text(s, "Create")
    # The chat view renders only after the ACP session binds, which spawns a
    # fresh mock-agent subprocess — its cold start can take the better part of a
    # minute, so wait generously here.
    wait_for(s, "chat view opened",
             "!!document.querySelector('.bt-text-input') && !!document.querySelector('.bt-chatpane')";
             timeout = 90)
    # The ACP session binds asynchronously; until it does, the sidebar hasn't
    # marked the new chat active and a re-render can briefly drop `.bt-text-input`.
    # Gate on the new chat actually being SELECTED (non-empty active pid) AND its
    # input being visible — otherwise `new_chat` can return mid-bind and the next
    # `send_message` races a flicker. This matters most under the shared runner,
    # where a populated sidebar makes the bind lag longer.
    wait_for(s, "new chat selected + input live",
             "(() => { const a=document.querySelector('.bt-side-item.bt-side-active'); " *
             "return !!a && !!(a.getAttribute('data-project-id')) && " *
             "[...document.querySelectorAll('.bt-text-input')].some(e=>e.offsetParent!==null); })()";
             timeout = 90)
    sleep(0.5)
    pid = current_chat_id(s)
    ctx = SERVER_CONTEXT[]
    ctx === nothing || (ctx.project_id[] = pid)
    return pid
end

"""
    open_chat(s, pid_or_title)

Open an existing chat by clicking its sidebar entry, matched by project id
(`data-project-id`) or by a substring of its title.
"""
function open_chat(s::TestServer, key::AbstractString)
    k = json(String(key))
    ok = eval_js(s, """(() => {
        const items = [...document.querySelectorAll('.bt-side-item')];
        let el = items.find(e => e.getAttribute('data-project-id') === $k);
        if (!el) el = items.find(e => (e.innerText||'').includes($k));
        if (!el) return false; el.click(); return true; })()""")
    ok === true || error("open_chat: no sidebar entry for $(repr(key))")
    wait_for(s, "chat view", "!!document.querySelector('.bt-text-input')"; timeout = 10)
    return s
end

"""
    switch_agent(s, label)

Switch the chat's agent/provider via the header dropdown, e.g. "Mock Agent",
"Claude Code", "MiMo Code", "OpenCode". The chat must be open.
"""
function switch_agent(s::TestServer, label::AbstractString)
    l = json(String(label))
    ok = eval_js(s, """(() => {
        const sel = document.querySelector('.bt-header-provider-select');
        if (!sel) return false;
        const opt = [...sel.options].find(o => (o.textContent||'').trim() === $l || o.value === $l);
        if (!opt) return false;
        sel.value = opt.value;
        sel.dispatchEvent(new Event('input', {bubbles: true}));
        sel.dispatchEvent(new Event('change', {bubbles: true}));
        return true; })()""")
    ok === true || error("switch_agent: provider option $(repr(label)) not found")
    return s
end

"""
    set_window_size(s, w, h)

Resize the renderer viewport via Chromium device emulation (more reliable than
`BrowserWindow.setSize` on headless Linux). Drives the CSS `@media` breakpoints
the responsive layout reads.
"""
function set_window_size(s::TestServer, w::Integer, h::Integer)
    ctx = s.browser[]
    ctx === nothing && error("open_browser first")
    ECT.set_window_size(ctx, Int(w), Int(h))
    return s
end

"""
    send_message(s, text)

Type `text` into the chat composer and click send, the same path a user takes.
A chat must be open (see [`new_chat`](@ref) / [`open_chat`](@ref)).
"""
function send_message(s::TestServer, txt::AbstractString)
    set_input(s, ".bt-text-input", String(txt))   # set_input already visibility-filters
    # Click the VISIBLE send button (the active pane's), never a hidden pane's.
    ok = eval_js(s, "(() => { const b=[...document.querySelectorAll('.bt-send-btn')].find(e=>e.offsetParent!==null); if(!b)return false; b.click(); return true; })()")
    ok === true || error("send_message: no visible send button (.bt-send-btn) — is a chat open?")
    return s
end

"""
    current_chat_id(s) -> String

Project id of the chat currently open in the browser, read from the active
sidebar entry (`.bt-side-item.bt-side-active`). Empty string on the dashboard.
"""
function current_chat_id(s::TestServer)
    pid = eval_js(s, """(() => { const a=document.querySelector('.bt-side-item.bt-side-active');
        return a ? (a.getAttribute('data-project-id') || '') : ''; })()""")
    return String(pid === nothing ? "" : pid)
end

"""
    screenshot(s, path)

Save a PNG of the current Electron window. Synchronous: blocks until the
file lands on disk so the next `Read` call sees it.
"""
function screenshot(s::TestServer, path::AbstractString; timeout::Real = 8)
    ctx = s.browser[]
    ctx === nothing && error("open_browser first")
    path = abspath(String(path))
    mkpath(dirname(path))
    # ECT.screenshot drives the main-process capturePage and writes the PNG
    # synchronously before returning.
    return ECT.screenshot(ctx; path = path)
end

# Tiny JSON-encode helper (no JSON3 dep in the test module).
json(x) = JSON.json(x)

end # module
