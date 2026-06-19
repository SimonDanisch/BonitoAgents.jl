# Typed-tool family + TodoWrite consolidation + background-task / stop affordance.
#
# Split per the TestKit migration: the pure typed-dispatch / `build_tool_msg` /
# `is_live` / `is_taskbar_item` / `tool_header_dict` / `tool_key` / TodoList
# lifecycle / `request_tool_stop!` functions are genuinely agent-free — they map
# an ACP wire value (or a directly-constructed `ToolMsg`) to a typed BonitoAgents
# message and assert its fields. Those stay DIRECT unit tests, built against a
# real `ServerState` + a `ChatModel` whose `agent` is a no-op `MockAgent` (the
# deleted `MockTransport`/`transport=` scaffolding is gone; nothing here drives a
# turn, so no transport is needed at all).
#
# Two things that used to be asserted via internal state are now DOM e2e on the
# TestKit harness instead:
#   * "the agent emits a tool / a todo list → it renders + the taskbar updates"
#     — driven through the real stack with `TK.tool` / `TK.todo`.
#   * the turn-scoped cancel gate (a stale `{type:'cancel', seq}` must not kill a
#     later turn; the current-seq one does) — the old wire-recording transport is
#     deleted, so we drive the REAL `CancelCommand` through a live in-flight turn
#     and assert via busy state.
#
# Concerns covered as pure units:
#   1. ACP wire → typed `ToolCall` subtype (parse_session_update + build_tool_call)
#   2. BonitoAgents build dispatch (build_tool_msg)
#   3. is_live / is_taskbar_item + tool_header_dict["taskbar"]
#   4. TodoWrite absorption (single bubble per logical list)
#   5. request_tool_stop! dispatch (StopToolCommand)
#   6. tool_key + filter-key persistence

using Test
include(joinpath(@__DIR__, "testkit", "TestKit.jl"))
import .TestKit, BonitoAgents
const TK  = TestKit
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol
using .TestKit: text, tool, todo, delay, text_block, end_turn

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

# Real ServerState + a ChatModel whose agent is a no-op MockAgent. None of the
# pure tests drive a turn, so this never spawns a subprocess — it just gives the
# typed-message constructors / persist paths a real ChatSession to bind to.
function make_chat()
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    BT.ChatModel(state, mktempdir(); agent = BT.MockAgent([]))
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
    try
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
    finally
        close(chat)
    end
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
        close(chat)
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
        close(chat)
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
        close(chat)
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
        close(chat)
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
        close(chat)
    end

    @testset "a DIFFERENT all-done list still lands once" begin
        chat = make_chat()
        BT.process!(chat, plan(mkentries([("A", "completed")])))
        BT.process!(chat, plan(mkentries([("X", "completed")])))
        @test count(m -> m isa BT.TodoListMsg, chat.msgs_store) == 2
        close(chat)
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
        close(chat)
    end
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
        close(chat)
    end

    @testset "non-background bash → silent no-op" begin
        chat = make_chat()
        t = BT.BashToolMsg("b2", "execute", "ls", "in_progress", "",
                            time(), nothing, "ls -la", false, "", 0, false, "", chat)
        push!(chat.msgs_store, t)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("b2"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
        @test t.status == "in_progress"           # untouched
        close(chat)
    end

    @testset "background TaskToolMsg → finalized directly, NO chat message" begin
        chat = make_chat()
        t = BT.TaskToolMsg("ta1", "other", "research", "in_progress", "",
                           time(), nothing, "research", true, "researcher", chat)
        push!(chat.msgs_store, t)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("ta1"))

        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
        @test !BT.is_live(t)                       # closed → terminal
        close(chat)
    end

    @testset "generic / MCP tools → silent no-op" begin
        chat = make_chat()
        m = BT.MCPToolMsg("m1", "other", "bt_julia_eval", "completed", "",
                          time(), time(), "btworker", "bt_julia_eval", chat)
        push!(chat.msgs_store, m)
        BT.handle_command!(chat, nothing, BT.StopToolCommand("m1"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
        close(chat)
    end

    @testset "unknown tool id → silent no-op" begin
        chat = make_chat()
        BT.handle_command!(chat, nothing, BT.StopToolCommand("nonexistent"))
        @test isempty(filter(m -> m isa BT.UserMsg, chat.msgs_store))
        close(chat)
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

    @testset "parse_chat_command extracts CancelCommand with/without seq" begin
        @test BT.parse_chat_command(Dict{String,Any}("type"=>"cancel","seq"=>5)) ==
              BT.CancelCommand(5)
        @test BT.parse_chat_command(Dict{String,Any}("type"=>"cancel")) ==
              BT.CancelCommand(-1)
    end
end

# ── 6. Per-tool filter keys (toolbar show/hide is keyed on the ACP tool name) ──
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

# ── DOM e2e: an agent-emitted tool + todo render and update the taskbar ──────
# The "agent emits X → the user sees X" half, driven through the REAL stack:
# the agent callback emits a generic tool pill and a (live, then all-done) todo
# list, and we assert the rendered DOM + the taskbar pin.
@testset "agent-emitted tool + todo render + taskbar (DOM)" begin
    # Turn 1: a completed tool pill + a LIVE todo list, held open with a delay so
    # the live pin is observable; then the list completes (all-done) and the pin
    # drops while a history bubble lands.
    s = TK.dev_server(; agent = msg -> [
        tool(; id = "tool-x", kind = "read", title = "Read notes.txt",
               status = "completed", content = [text_block("file contents")]),
        todo([(content = "first step",  status = "in_progress"),
              (content = "second step", status = "pending")]),
        delay(2500),
        todo([(content = "first step",  status = "completed"),
              (content = "second step", status = "completed")]),
        text("done"),
        end_turn(),
    ])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        chat = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        TK.send_message(s, "do the steps")

        # The tool pill renders.
        @test TK.wait_for(s, "tool pill arrives",
            "document.querySelectorAll('.bt-tool-msg').length >= 1"; timeout = 30) == true
        @test TK.wait_for(s, "tool title shows the file", """
            [...document.querySelectorAll('.bt-tool-title')]
                .some(t => (t.innerText||'').indexOf('notes.txt') !== -1)
        """; timeout = 8) == true

        # While the list is live (held by the delay) it pins to the taskbar as a
        # todo slot (`.bt-taskbar-slot.bt-taskbar-todo`).
        @test TK.wait_for(s, "live todo pins to taskbar",
            "document.querySelectorAll('.bt-taskbar-slot.bt-taskbar-todo').length >= 1"; timeout = 15) == true
        @test timedwait(() -> chat.live_todo[] !== nothing, 10.0) === :ok

        # After all-done the live pin drops and the turn settles.
        @assert timedwait(() -> !chat.busy_active[], 20.0) === :ok "turn never settled"
        @test timedwait(() -> chat.live_todo[] === nothing, 10.0) === :ok
        @test TK.wait_for(s, "taskbar todo pin cleared",
            "document.querySelectorAll('.bt-taskbar-slot.bt-taskbar-todo').length === 0"; timeout = 10) == true

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end

# ── DOM e2e: the turn-scoped cancel gate ─────────────────────────────────────
# The deleted MockTransport let the old test record `session/cancel` frames off
# the wire. With it gone we drive the REAL CancelCommand through a live in-flight
# turn: a STALE-seq cancel (aimed at a turn that already ended) must NOT stop the
# current turn, while a CURRENT-seq cancel does. We fire each by notifying the
# chat's `comm` exactly as the JS stop button would (`{type:'cancel', seq}`), and
# observe `busy_active` rather than a now-deleted wire recorder.
@testset "cancel is scoped to its turn (DOM)" begin
    # The turn streams an opening chunk then HOLDS open (~5s) so we have a window
    # to fire the stale + current cancels against a genuinely busy turn.
    s = TK.dev_server(; agent = msg -> [text("HOLDING "), delay(5000),
                                        text("RESUMED "), end_turn()])
    try
        TK.open_browser(s; width = 1280, height = 820)
        pid = TK.new_chat(s)
        TK.click(s, ".bt-side-item[data-project-id=\"$pid\"]")
        TK.wait_for(s, "chat mounted", "!!document.querySelector('.bt-text-input')"; timeout = 10)
        model = lock(s.h.state.lock) do; s.h.state.chat_models[pid]; end

        TK.send_message(s, "hold then I cancel")
        @test TK.wait_for(s, "turn streaming",
            "document.body.textContent.indexOf('HOLDING') !== -1"; timeout = 20) == true
        @assert timedwait(() -> model.busy_active[], 8.0) === :ok "turn never went busy"

        cur_seq = model.turn_seq[]
        @test cur_seq >= 0

        # STALE cancel: aimed at a turn that already ended (seq-1). It must be
        # dropped before reaching the wire — the turn stays busy.
        TK.eval_js(s, """
            (() => { const c = document.querySelector('.bt-messages').__bt_chat;
                     c.comm.notify({type:'cancel', seq: $(cur_seq - 1)}); return true; })()""")
        sleep(0.8)
        @test model.busy_active[] == true        # stale cancel ignored
        @test model.session_alive[] == true

        # CURRENT cancel: aimed at the live turn — honored, busy clears fast,
        # session stays alive (graceful cancel, no force-close).
        TK.eval_js(s, """
            (() => { const c = document.querySelector('.bt-messages').__bt_chat;
                     c.comm.notify({type:'cancel', seq: $(cur_seq)}); return true; })()""")
        @test timedwait(() -> !model.busy_active[], 8.0) === :ok
        @test model.session_alive[] == true

        errs = TK.eval_js(s, "window.__errs || []")
        @test isempty(errs)
    finally
        close(s)
    end
end
