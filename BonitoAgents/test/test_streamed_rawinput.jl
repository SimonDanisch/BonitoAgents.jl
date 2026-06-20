# Streamed tool input — regression for the REAL claude-agent-acp wire shapes
# (captured from a live session log, chats/<pid>/acp.jsonl):
#
#   tool_call          status=pending   rawInput={}            ← arguments NOT yet known
#   tool_call_update   status=ABSENT    rawInput={code,...}    ← arguments arrive, eval still running
#   tool_call_update   status=completed rawInput=ABSENT        ← result
#
# Pre-fix, the empty initial rawInput was snapshotted into the ToolMsg and
# never refreshed: no live code preview / ⏱ / ⊗ for real evals, and the ✎
# editor button on claude's Read/Edit tools resolved the DISPLAY TITLE
# ("Read CONVENTIONS.md") as a file path — a button that silently did
# nothing. These tests drive the full MockTransport → ACP parse → ChatModel
# pipeline with those exact frames and assert the comm events the browser
# renders from.

using Test
using JSON
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
const obs_on = BT.Bonito.Observables.on

# JSON-RPC responder streaming `updates` (raw wire dicts) on session/prompt.
function streaming_transport(updates::Vector)
    notif(u) = JSON.json(Dict("jsonrpc" => "2.0", "method" => "session/update",
        "params" => Dict("sessionId" => "s", "update" => u)))
    resp(id, result) = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
    on_setup = (outgoing::Channel{String}, incoming::Channel{String}) -> begin
        Base.errormonitor(@async try
            for line in outgoing
                msg    = JSON.parse(line)
                method = get(msg, "method", "")
                id     = get(msg, "id", nothing)
                if method == "initialize" && id !== nothing
                    put!(incoming, resp(id, Dict()))
                elseif method == "session/new" && id !== nothing
                    put!(incoming, resp(id, Dict("sessionId" => "s")))
                elseif method == "session/prompt" && id !== nothing
                    for u in updates
                        put!(incoming, notif(u))
                        # Pace the stream: ACP snapshots alias ONE mutable
                        # ToolCall, so back-to-back updates let a later
                        # status overwrite what the consumer reads from an
                        # earlier snap. Real agents have seconds between
                        # these frames.
                        sleep(0.3)
                    end
                    put!(incoming, resp(id, Dict("stopReason" => "end_turn")))
                end
            end
        catch e
            e isa InvalidStateException || @warn "responder failed" exception = e
        end)
        return nothing
    end
    return BT.MockTransport(on_setup)
end

function run_turn_collect(updates::Vector; cwd::AbstractString = mktempdir())
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, cwd; transport = streaming_transport(updates))
    events = Dict{String,Any}[]
    lk = ReentrantLock()
    obs_on(d -> lock(() -> push!(events, copy(d)), lk), model.comm)
    busy_seen = Bool[]
    obs_on(b -> push!(busy_seen, b), model.busy_active)
    BT.start_chat_client!(model)
    BT.send_message!(model, BT.UserMsg("go"))
    @assert timedwait(() -> busy_seen == [true, false], 10.0) === :ok "turn never finished"
    return model, events
end

# Exact wire shapes from the captured log (toolName rides _meta.claudeCode).
meta(name) = Dict("claudeCode" => Dict("toolName" => name))
text_block(t) = Dict("type" => "content",
                     "content" => Dict("type" => "text", "text" => t))

@testset "streamed rawInput (real claude-agent-acp shapes)" begin

@testset "bt_julia_eval: code/⏱/⊗ arrive on the in-flight update" begin
    evalname = "mcp__btworker__bt_julia_eval"
    updates = [
        # 1. announcement: NO arguments yet
        Dict("sessionUpdate" => "tool_call", "toolCallId" => "ev1",
             "kind" => "other", "title" => evalname, "status" => "pending",
             "_meta" => meta(evalname), "rawInput" => Dict(), "content" => []),
        # 2. arguments land; eval still running (NO status field)
        Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "ev1",
             "title" => evalname, "_meta" => meta(evalname),
             "rawInput" => Dict("code" => "sleep(2); 40 + 2", "timeout" => 60,
                                 "env_path" => "/tmp/p"),
             "content" => []),
        # 3. result
        Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "ev1",
             "status" => "completed",
             "content" => [text_block("```julia\nsleep(2); 40 + 2\n```\n42")]),
    ]
    model, events = run_turn_collect(updates)

    tool_events = [e for e in events
                   if get(e, "type", "") in ("tool", "tool_update") &&
                      get(e, "id", "") == "ev1"]
    @test !isempty(tool_events)

    # The initial header CAN'T have the code (the wire didn't either)…
    first_ev = tool_events[1]
    @test !haskey(first_ev, "code")

    # …but an update BEFORE terminal status must carry code + ⏱ + ⊗.
    live_with_code = [e for e in tool_events
                      if get(e, "type", "") == "tool_update" &&
                         haskey(e, "code") &&
                         !(get(e, "status", "") in ("completed", "failed"))]
    @test !isempty(live_with_code)
    e = live_with_code[1]
    @test e["code"] == "sleep(2); 40 + 2"
    @test e["timeout_s"] == "60s"
    @test e["stoppable"] === true

    # The ToolMsg's raw_input was refreshed from the late update.
    msg = only(m for m in model.msgs_store if m isa BT.MCPToolMsg)
    @test msg.raw_input["code"] == "sleep(2); 40 + 2"
    @test BT.tool_path_hint(msg) === nothing   # no path args on an eval
end

@testset "Bash: late command/description/run_in_background reach the pill" begin
    script = "for i in \$(seq 1 900); do date; sleep 2; done"
    updates = [
        # announcement: NO arguments yet (streamed input)
        Dict("sessionUpdate" => "tool_call", "toolCallId" => "sh1",
             "kind" => "execute", "title" => "Bash", "status" => "pending",
             "_meta" => meta("Bash"), "rawInput" => Dict(), "content" => []),
        # arguments land while the shell runs: a background monitor loop
        Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "sh1",
             "_meta" => meta("Bash"),
             "rawInput" => Dict("command" => script,
                                 "description" => "Monitor system load",
                                 "run_in_background" => true),
             "content" => []),
        Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "sh1",
             "status" => "completed",
             "content" => [text_block("monitor started")]),
    ]
    model, events = run_turn_collect(updates)

    msg = only(m for m in model.msgs_store if m isa BT.BashToolMsg)
    @test msg.command == script
    @test msg.description == "Monitor system load"
    @test msg.is_background

    # The pill shows the human description, not the raw script; the script
    # rides as the header tooltip; the taskbar flag flips on.
    ups = [e for e in events
           if get(e, "type", "") == "tool_update" && get(e, "id", "") == "sh1"]
    @test any(e -> get(e, "title", "") == "Monitor system load", ups)
    @test any(e -> get(e, "command", "") == script, ups)
    @test any(e -> get(e, "taskbar", false) === true, ups)
    @test any(e -> get(e, "background", false) === true, ups)
end

@testset "Read: ✎ resolves rawInput.file_path, NOT the display title" begin
    cwd = mktempdir()
    fpath = joinpath(cwd, "hello.jl")
    write(fpath, "greet() = 1\n")
    updates = [
        Dict("sessionUpdate" => "tool_call", "toolCallId" => "rd1",
             "kind" => "read", "title" => "Read File", "status" => "pending",
             "_meta" => meta("Read"), "rawInput" => Dict(), "content" => []),
        Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "rd1",
             "kind" => "read", "title" => "Read hello.jl",
             "_meta" => meta("Read"),
             "rawInput" => Dict("file_path" => fpath), "content" => []),
        Dict("sessionUpdate" => "tool_call_update", "toolCallId" => "rd1",
             "status" => "completed",
             "content" => [text_block("greet() = 1\n")]),
    ]
    model, events = run_turn_collect(updates; cwd)

    # An update flagged the pill editable.
    editable_evs = [e for e in events
                    if get(e, "type", "") == "tool_update" &&
                       get(e, "id", "") == "rd1" && get(e, "editable", false) === true]
    @test !isempty(editable_evs)

    # The ToolMsg carries the REAL path (display title is NOT a path).
    msg = only(m for m in model.msgs_store if m isa BT.GenericToolMsg)
    @test msg.title == "Read hello.jl"
    @test BT.tool_path_hint(msg) == fpath

    # The same derivation the ✎ click handler runs resolves the real file —
    # pre-fix it produced the garbage path "Read hello.jl".
    content = BT.tool_content_for_render(msg, model.chat_dir)
    hd = Dict{String,Any}("kind" => msg.kind, "title" => msg.title)
    hint = BT.tool_path_hint(msg)
    hint === nothing || (hd["path_hint"] = hint)
    @test BT.editable_path_from(hd, content) == fpath

    # Persisted for history reload: the hint survives without the in-RAM msg.
    @test BT.stored_path_hint(model.chat_dir, "rd1") == fpath

    # And a display title alone (no hint) must NOT produce a path.
    @test BT.editable_path_from(
        Dict{String,Any}("kind" => "read", "title" => "Read hello.jl"),
        content) === nothing
end

end
