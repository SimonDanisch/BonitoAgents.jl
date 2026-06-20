# Headless coverage for the typed-tool family added in baf4fba + the TodoWrite
# consolidation fix in 5396e6c + the background-task / stop affordance in
# 0bcfdd2 / 97e2d61.
#
# Three concerns:
#
#   1. ACP wire → typed `ToolCall` subtype (`BashCall` / `TodoWriteCall` /
#      `TaskCall` / `MCPCall` / `GenericTool`) — `parse_session_update` reads
#      `_meta.claudeCode.toolName` + `rawInput` and dispatches.
#   2. BonitoAgents build dispatch (`build_tool_msg`) — typed ACP value ↦ typed
#      BonitoAgents `ToolMsg` subtype, carrying tool-specific fields
#      (`is_background`, `tool_name`, `task_name`).
#   3. `is_live` / `is_taskbar_item` + `tool_header_dict["taskbar"]` flag —
#      background bash & subagent Task get a taskbar slot; one-shot tools
#      don't.
#   4. TodoWrite absorption — single bubble per logical todo list, even
#      across turns, until the entries reach all-done.
#   5. `request_tool_stop!` dispatch — synthetic user message queued for
#      background bash/task, silent no-op for everything else.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# ── Helpers ────────────────────────────────────────────────────────────────

# Build a `tool_call` SessionUpdate-shaped dict the way claude-agent-acp does
# (with the `_meta.claudeCode.toolName` envelope + `rawInput`).
function tool_call_params(id::String, name::String, raw_input::AbstractDict;
                          kind::String = "execute", title::String = name,
                          status::String = "pending",
                          content::AbstractVector = [])
    return Dict{String,Any}(
        "sessionUpdate" => "tool_call",
        "toolCallId"    => id,
        "title"         => title,
        "kind"          => kind,
        "status"        => status,
        "content"       => content,
        "_meta"         => Dict("claudeCode" => Dict("toolName" => name)),
        "rawInput"      => raw_input,
    )
end

# Build a chat model attached to a real ServerState + mock transport so the
# `Base.close(::TodoListMsg)` persist path runs against a real ChatSession.
function make_chat()
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    BT.ChatModel(state, mktempdir();
                  transport = BT.MockTransport((o, i) -> nothing))
end

# Convenience: build a PlanEntry vector.
mkentries(pairs::Vector) =
    [BT.PlanEntry(String(c), "", String(s)) for (c, s) in pairs]

# An *already-closed* updates channel — `process!(::TodoWriteCall)` drains
# `m.updates` for trailing tool_call_updates (rare, but the loop is there);
# a freshly-opened channel would block forever in a unit test.
function closed_chan()
    c = Channel{ACP.ToolCall}(1)
    close(c)
    return c
end

# Build a TodoWriteCall whose updates channel is already closed.
function mktodo(id, entries)
    ACP.TodoWriteCall(id, "think", "TodoWrite", "completed",
                       ACP.ToolContent[], closed_chan(), entries)
end

# ── 1. ACP wire → typed ToolCall ───────────────────────────────────────────

@testset "ACP parse_session_update → typed ToolCall" begin

    @testset "Bash with run_in_background=true → BashCall" begin
        p = tool_call_params("b1", "Bash",
            Dict("command" => "sleep 10; echo done", "run_in_background" => true);
            kind = "execute", title = "sleep 10; echo done")
        u = ACP.parse_session_update(p)
        @test u isa ACP.ToolCallNotif
        @test u.tool_name == "Bash"
        @test u.raw_input["command"] == "sleep 10; echo done"

        tc = ACP.build_tool_call(u)
        @test tc isa ACP.BashCall
        @test tc.id == "b1"
        @test tc.kind == "execute"
        @test tc.command == "sleep 10; echo done"
        @test tc.run_in_background == true
        @test tc.description === nothing
    end

    @testset "Bash without run_in_background → BashCall is_background=false" begin
        p = tool_call_params("b2", "Bash",
            Dict("command" => "ls -la", "description" => "list files"))
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.BashCall
        @test tc.run_in_background == false
        @test tc.description == "list files"
    end

    @testset "TodoWrite → TodoWriteCall with entries lifted from rawInput.todos" begin
        p = tool_call_params("t1", "TodoWrite",
            Dict("todos" => [
                Dict("content" => "Step one", "status" => "pending",     "priority" => "high"),
                Dict("content" => "Step two", "status" => "in_progress", "priority" => "medium"),
            ]); kind = "think", title = "TodoWrite")
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.TodoWriteCall
        @test length(tc.entries) == 2
        @test tc.entries[1].content == "Step one"
        @test tc.entries[1].status  == "pending"
        @test tc.entries[2].status  == "in_progress"
    end

    @testset "Task / Agent with run_in_background → TaskCall" begin
        p_task = tool_call_params("t2", "Task",
            Dict("description" => "research X",
                 "prompt" => "Investigate the API",
                 "run_in_background" => true,
                 "name" => "research-runner");
            kind = "other", title = "research X")
        tc = ACP.build_tool_call(ACP.parse_session_update(p_task))
        @test tc isa ACP.TaskCall
        @test tc.description == "research X"
        @test tc.prompt == "Investigate the API"
        @test tc.run_in_background == true
        @test tc.task_name == "research-runner"

        # `Agent` is the newer SDK name for the same shape — same routing.
        p_agent = tool_call_params("a1", "Agent",
            Dict("description" => "explore", "prompt" => "go"))
        tc2 = ACP.build_tool_call(ACP.parse_session_update(p_agent))
        @test tc2 isa ACP.TaskCall
        @test tc2.run_in_background == false
        @test tc2.task_name === nothing
    end

    @testset "mcp__server__tool → MCPCall with split name" begin
        p = tool_call_params("m1", "mcp__btworker__bt_julia_eval",
            Dict("code" => "1 + 1"); title = "mcp__btworker__bt_julia_eval")
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.MCPCall
        @test tc.server    == "btworker"
        @test tc.tool_name == "bt_julia_eval"
        @test tc.raw_input["code"] == "1 + 1"
    end

    @testset "Unknown tool name → GenericTool fallback" begin
        p = tool_call_params("u1", "SomeFutureTool", Dict("arg" => "x"))
        tc = ACP.build_tool_call(ACP.parse_session_update(p))
        @test tc isa ACP.GenericTool
        @test tc.name == "SomeFutureTool"
        @test tc.raw_input["arg"] == "x"
    end

    @testset "No meta envelope → empty tool_name, GenericTool fallback" begin
        # An ACP backend that doesn't fill the claudeCode envelope at all.
        p = Dict{String,Any}(
            "sessionUpdate" => "tool_call",
            "toolCallId"    => "g1",
            "title"         => "Read",
            "kind"          => "read",
            "status"        => "pending",
            "content"       => [],
        )
        u = ACP.parse_session_update(p)
        @test u.tool_name == ""
        tc = ACP.build_tool_call(u)
        @test tc isa ACP.GenericTool
        @test tc.name == ""
    end
end

# ── 2. BonitoAgents build_tool_msg dispatch ─────────────────────────────────

@testset "BonitoAgents build_tool_msg dispatch" begin
    chat = make_chat()

    # BashCall background → BashToolMsg(is_background=true)
    bash_bg = ACP.BashCall("b1", "execute", "sleep 10", "in_progress",
                           ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                           "sleep 10", true, nothing)
    m_bash = BT.build_tool_msg(chat, bash_bg)
    @test m_bash isa BT.BashToolMsg
    @test m_bash.command == "sleep 10"
    @test m_bash.is_background == true

    # TaskCall → TaskToolMsg
    task = ACP.TaskCall("t1", "other", "research", "in_progress",
                        ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                        "research", "Investigate", true, "researcher")
    m_task = BT.build_tool_msg(chat, task)
    @test m_task isa BT.TaskToolMsg
    @test m_task.is_background == true
    @test m_task.task_name == "researcher"

    # MCPCall → MCPToolMsg (server + bare tool_name)
    mcp = ACP.MCPCall("m1", "other", "mcp__btworker__bt_julia_eval", "completed",
                      ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                      "btworker", "bt_julia_eval", Dict{String,Any}("code" => "1"))
    m_mcp = BT.build_tool_msg(chat, mcp)
    @test m_mcp isa BT.MCPToolMsg
    @test m_mcp.server == "btworker"
    @test m_mcp.tool_name == "bt_julia_eval"

    # GenericTool → GenericToolMsg
    gen = ACP.GenericTool("g1", "read", "cat foo.txt", "completed",
                          ACP.ToolContent[], Channel{ACP.ToolCall}(1),
                          "Read", Dict{String,Any}())
    m_gen = BT.build_tool_msg(chat, gen)
    @test m_gen isa BT.GenericToolMsg
end

# ── 3. is_live / is_taskbar_item + tool_header_dict["taskbar"] ────────────

@testset "is_live / is_taskbar_item + taskbar flag in header dict" begin
    now_t = time()

    # Background bash is taskbar + live until terminal.
    bash_bg = BT.BashToolMsg("b1", "execute", "sleep", "in_progress", "",
                              now_t, nothing, "sleep 10", true, "", 0, false, "", nothing)
    @test BT.is_live(bash_bg) == true
    @test BT.is_taskbar_item(bash_bg) == true
    h = BT.tool_header_dict(bash_bg)
    @test h["taskbar"] == true
    @test h["background"] == true        # subtype-specific flag

    # Same shape, foreground bash — neither taskbar nor (long-term) live UX.
    bash_fg = BT.BashToolMsg("b2", "execute", "ls", "in_progress", "",
                              now_t, nothing, "ls -la", false, "", 0, false, "", nothing)
    @test BT.is_live(bash_fg) == true             # status-based liveness still applies
    @test BT.is_taskbar_item(bash_fg) == false
    @test BT.tool_header_dict(bash_fg)["taskbar"] == false

    # Task subagent backgrounded → taskbar item.
    task_bg = BT.TaskToolMsg("t1", "other", "explore", "in_progress", "",
                              now_t, nothing, "explore X", true, "explorer", nothing)
    @test BT.is_taskbar_item(task_bg) == true

    # MCP / generic tools never land in the taskbar.
    mcp = BT.MCPToolMsg("m1", "other", "bt_julia_eval", "in_progress", "",
                        now_t, nothing, "btworker", "bt_julia_eval", nothing)
    @test BT.is_taskbar_item(mcp) == false
    gen = BT.GenericToolMsg("g1", "read", "cat", "in_progress", "",
                            now_t, nothing, nothing)
    @test BT.is_taskbar_item(gen) == false

    # Terminal status → not live.
    bash_done = BT.BashToolMsg("b3", "execute", "echo", "completed", "ok",
                                now_t, now_t, "echo hi", true, "", 0, false, "", nothing)
    @test BT.is_live(bash_done) == false

    # `finished_at` wins over status even when status is mid-flight (used by
    # absorbed TodoLists, but applies uniformly).
    bash_finished_early = BT.BashToolMsg("b4", "execute", "x", "in_progress", "",
                                          now_t, now_t, "x", true, "", 0, false, "", nothing)
    @test BT.is_live(bash_finished_early) == false
end

# ── 4. TodoWrite absorption ───────────────────────────────────────────────

@testset "TodoListMsg lifecycle: taskbar pin while live, history on finalize" begin
    # The REAL wire carries todos exclusively as `plan` SessionUpdates
    # (verified on a live acp.jsonl); the TodoWrite tool_call channel is
    # deliberately inert.
    plan(entries) = ACP.Plan(entries)
    pinned_todo(chat) = begin
        items = chat.taskbar_items[]
        idx = findfirst(t -> t.kind === :todo, items)
        idx === nothing ? nothing : items[idx]
    end

    @testset "TodoWrite tool_calls are inert (single-channel)" begin
        chat = make_chat()
        BT.process!(chat, mktodo("tw1", mkentries([("A", "pending")])))
        @test chat.live_todo[] === nothing
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 0
        @test pinned_todo(chat) === nothing
    end

    @testset "a live list pins to the taskbar — no chat message" begin
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "pending"), ("B", "pending")])))
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 0
        t = chat.live_todo[]
        @test t isa BT.TodoListMsg && BT.is_live(t)
        pin = pinned_todo(chat)
        @test pin !== nothing
        @test pin.entries == [("A", "pending"), ("B", "pending")]
    end

    @testset "subsequent plans mutate the SAME live list + pin" begin
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "pending"), ("B", "pending")])))
        first_id = chat.live_todo[].id

        BT.process!(chat, plan(mkentries([("A", "completed"), ("B", "in_progress")])))

        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 0
        @test chat.live_todo[].id == first_id
        pin = pinned_todo(chat)
        @test pin.id == first_id
        @test pin.entries == [("A", "completed"), ("B", "in_progress")]
    end

    @testset "all-done finalizes: pin drops, history bubble appears" begin
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "pending")])))
        live_id = chat.live_todo[].id

        BT.process!(chat, plan(mkentries([("A", "completed")])))

        @test chat.live_todo[] === nothing
        @test pinned_todo(chat) === nothing
        todos = filter(m -> m isa BT.TodoListMsg, chat.msgs_store)
        @test length(todos) == 1
        @test todos[1].id == live_id
        @test todos[1].finished_at !== nothing
    end

    @testset "redundant all-done re-send is DROPPED (no duplicate bubble)" begin
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "pending")])))
        BT.process!(chat, plan(mkentries([("A", "completed")])))
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 1

        # Claude re-sends the final state ("todos cleared") — must not
        # create a second identical bubble.
        BT.process!(chat, plan(mkentries([("A", "completed")])))
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 1
        @test chat.live_todo[] === nothing
    end

    @testset "a DIFFERENT all-done list still lands once" begin
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "completed")])))
        BT.process!(chat, plan(mkentries([("X", "completed")])))
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 2
    end

    @testset "zombie: finalize_todo! moves an unfinished list to history" begin
        # run_turn!'s finally does exactly this for a list whose turn ended.
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "completed"), ("B", "pending")])))
        t = chat.live_todo[]
        BT.finalize_todo!(chat, t)

        @test chat.live_todo[] === nothing
        @test pinned_todo(chat) === nothing
        todos = filter(m -> m isa BT.TodoListMsg, chat.msgs_store)
        @test length(todos) == 1
        @test [e.status for e in todos[1].entries] == ["completed", "pending"]
    end
end

# ── Turn-scoped cancel ──────────────────────────────────────────────────────
# A stop-click echoes the turn sequence it was AIMED at; a stale click
# (buffered while its turn finished) must not cancel the next turn. Observed
# live: three consecutive fresh prompts each murdered within one frame by
# stop-clicks meant for earlier turns.
@testset "CancelCommand is scoped to its turn" begin
    using JSON: JSON

    # Transport that records outgoing frames and answers the handshake.
    function recording_transport(sent::Vector{String})
        BT.MockTransport((outgoing, incoming) -> begin
            Base.errormonitor(@async try
                for line in outgoing
                    push!(sent, line)
                    msg = JSON.parse(line)
                    id = get(msg, "id", nothing)
                    m  = get(msg, "method", "")
                    if m == "initialize"
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,"result"=>Dict())))
                    elseif m == "session/new"
                        put!(incoming, JSON.json(Dict("jsonrpc"=>"2.0","id"=>id,
                                                      "result"=>Dict("sessionId"=>"s"))))
                    end
                end
            catch e
                e isa InvalidStateException || @warn "responder" e
            end)
            nothing
        end)
    end
    cancels(sent) = count(l -> occursin("session/cancel", l), sent)

    sent = String[]
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    model = BT.ChatModel(state, mktempdir(); transport = recording_transport(sent))
    BT.start_chat_client!(model)
    @test timedwait(() -> model.client[] !== nothing, 5.0) === :ok

    # Pretend turn 7 is running (cancel! itself no-ops without an active
    # turn, so we only verify the seq gate in front of it).
    model.turn_seq[] = 7

    # Stale: aimed at turn 3 → dropped BEFORE reaching the client.
    BT.handle_command!(model, nothing, BT.CancelCommand(3))
    @test cancels(sent) == 0

    # Unscoped (legacy) and current-turn cancels pass the gate; without an
    # active prompt the ACP client then no-ops, so still nothing on the
    # wire — the gate is what we are testing, the A8 idle-guard is already
    # covered in the ACP suite.
    BT.handle_command!(model, nothing, BT.CancelCommand(7))
    BT.handle_command!(model, nothing, BT.CancelCommand())
    @test cancels(sent) == 0

    @test BT.parse_chat_command(Dict{String,Any}("type"=>"cancel","seq"=>5)) ==
          BT.CancelCommand(5)
    @test BT.parse_chat_command(Dict{String,Any}("type"=>"cancel")) ==
          BT.CancelCommand(-1)
end

# ── 5. Stop-tool dispatch ─────────────────────────────────────────────────

@testset "request_tool_stop! per-variant" begin

    # The stop button is a DIRECT action, never a chat message: claude-agent-acp
    # completes the bg tool_call at launch and never sends a terminal update on
    # its id, so we finalize the pill ourselves (and SIGTERM the shell when a
    # worker is reachable — none here, so just finalize). No synthetic UserMsg.
    @testset "background BashToolMsg → finalized directly, NO chat message" begin
        chat = make_chat()
        t = BT.BashToolMsg("b1", "execute", "sleep 100", "in_progress", "",
                            time(), nothing, "sleep 100", true, "/tmp/x.output",
                            0, true, "", chat)   # bg_running = true
        push!(chat.msgs_store, t)
        BT.pin_task!(chat, BT.tool_taskbar_item(chat, t))
        @test BT.is_pinned(chat, "b1")

        BT.handle_command!(chat, nothing, BT.StopToolCommand("b1"))

        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))  # no synthetic msg
        @test !t.bg_running                       # finalized
        @test t.status == "completed"
        @test !BT.is_pinned(chat, "b1")           # pin dropped
    end

    @testset "non-background bash → silent no-op" begin
        chat = make_chat()
        t = BT.BashToolMsg("b2", "execute", "ls", "in_progress", "",
                            time(), nothing, "ls -la", false, "", 0, false, "", chat)
        push!(chat.msgs_store, t)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("b2"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
        @test t.status == "in_progress"           # untouched
    end

    @testset "background TaskToolMsg → finalized directly, NO chat message" begin
        chat = make_chat()
        t = BT.TaskToolMsg("ta1", "other", "research", "in_progress", "",
                           time(), nothing, "research", true, "researcher", chat)
        push!(chat.msgs_store, t)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("ta1"))

        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
        @test !BT.is_live(t)                       # closed → terminal
    end

    @testset "generic / MCP tools → silent no-op" begin
        chat = make_chat()
        m = BT.MCPToolMsg("m1", "other", "bt_julia_eval", "completed", "",
                          time(), time(), "btworker", "bt_julia_eval", chat)
        push!(chat.msgs_store, m)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("m1"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
    end

    @testset "unknown tool id → silent no-op" begin
        chat = make_chat()
        BT.handle_command!(chat, nothing, BT.StopToolCommand("nonexistent"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
    end

    @testset "parse_bg_output_path strips trailing sentence punctuation" begin
        # The launch banner ends "…/<id>.output. You will be notified" — the
        # greedy \\S+ used to keep the period, yielding a path that never
        # exists (so the pill could never finalize). Regression guard.
        txt = "Command running in background with ID: x. " *
              "Output is being written to: /tmp/t/abc.output. You will be notified"
        @test BT.parse_bg_output_path([(text = txt,)]) == "/tmp/t/abc.output"
        # Plain newline-terminated form is unaffected.
        @test BT.parse_bg_output_path([(text = "written to: /tmp/t/x.output\nmore",)]) ==
              "/tmp/t/x.output"
    end

    @testset "parse_chat_command extracts StopToolCommand" begin
        cmd = BT.parse_chat_command(Dict("type" => "stop_tool", "id" => "x1"))
        @test cmd isa BT.StopToolCommand
        @test cmd.tool_id == "x1"

        # Missing id → UnknownCommand (silent no-op).
        @test BT.parse_chat_command(Dict("type" => "stop_tool")) isa BT.UnknownCommand
    end
end

# ── Per-tool filter keys (toolbar show/hide is keyed on the ACP tool name) ──
@testset "per-tool filter keys" begin

    @testset "tool_key dispatch" begin
        named = BT.GenericToolMsg("g1", "other", "ToolSearch", "Search tools",
                                  "completed", "", 0.0, 0.0, nothing)
        @test BT.tool_key(named) == "ToolSearch"
        # 8-arg back-compat ctor → name="" → kind fallback (old chats,
        # agents without the claudeCode meta).
        nameless = BT.GenericToolMsg("g2", "read", "cat x", "completed", "",
                                     0.0, 0.0, nothing)
        @test nameless.name == ""
        @test BT.tool_key(nameless) == "read"

        bash = BT.BashToolMsg("b1", "execute", "ls -la", "completed", "",
                              0.0, 0.0, "ls -la", false, "", 0, false, "", nothing)
        @test BT.tool_key(bash) == "Bash"
        task = BT.TaskToolMsg("t1", "execute", "Explore", "completed", "",
                              0.0, 0.0, "explore", false, nothing, nothing)
        @test BT.tool_key(task) == "Task"
        mcp = BT.MCPToolMsg("m1", "other", "bt_show", "completed", "",
                            0.0, 0.0, "btworker", "bt_show", nothing)
        @test BT.tool_key(mcp) == "bt_show"
        app = BT.BonitoAppMsg("a1", "bonito_app", "plot", "completed", "",
                              0.0, 0.0, "btworker", "app-1", nothing)
        @test BT.tool_key(app) == "bt_show_app"
    end

    @testset "wire header carries the filter key" begin
        named = BT.GenericToolMsg("g1", "other", "ToolSearch", "Search tools",
                                  "completed", "", 0.0, 0.0, nothing)
        @test BT.tool_header_dict(named)["tool"] == "ToolSearch"
        bash = BT.BashToolMsg("b1", "execute", "ls -la", "completed", "",
                              0.0, 0.0, "ls -la", false, "", 0, false, "", nothing)
        @test BT.tool_header_dict(bash)["tool"] == "Bash"
        mcp = BT.MCPToolMsg("m1", "other", "bt_show", "completed", "",
                            0.0, 0.0, "btworker", "bt_show", nothing)
        @test BT.tool_header_dict(mcp)["tool"] == "bt_show"
    end

    @testset "persistence: filter key survives reload" begin
        dir = mktempdir()
        session = BT.load_session(dir, dir)
        # A typed Bash tool persists its resolved key…
        BT.append_tool(session, BT.BashToolMsg("b1", "execute", "ls -la",
            "completed", "12 files", 0.0, 0.0, "ls -la", false, "", 0, false, "", nothing))
        # …and so does a named generic tool.
        BT.append_tool(session, BT.GenericToolMsg("g1", "other", "ToolSearch",
            "Search tools", "completed", "", 0.0, 0.0, nothing))
        loaded = filter(m -> m isa BT.ToolMsg, BT.load_history(session))
        @test [m.name for m in loaded] == ["Bash", "ToolSearch"]
        @test [BT.tool_key(m) for m in loaded] == ["Bash", "ToolSearch"]
        # Reload lands as GenericToolMsg, key intact.
        @test all(m -> m isa BT.GenericToolMsg, loaded)
    end

    @testset "persistence: legacy 3-field tool meta still parses" begin
        dir = mktempdir()
        session = BT.load_session(dir, dir)
        open(session.path, "a") do io
            println(io, "!!! tool \"read · completed · old1\"")
            println(io, "    `cat file.txt`")
            println(io)
        end
        loaded = filter(m -> m isa BT.ToolMsg, BT.load_history(session))
        @test length(loaded) == 1
        t = loaded[1]
        @test t.id == "old1" && t.kind == "read" && t.status == "completed"
        @test t.name == ""
        @test BT.tool_key(t) == "read"    # kind fallback
    end

end
