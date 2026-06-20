# Defense-in-depth for the tool-message finish path. Three layers, each tested
# in isolation:
#
#   1. ACP `close(::TurnState)` force-fails any tool still in `st.tools` and
#      pushes ONE final terminal-status snapshot through its `updates` channel
#      before closing. Without this, a cancel/EOF mid-tool turn leaves the
#      chat-side `process_update!` draining a channel that closed with the
#      tool's status frozen mid-flight (e.g. `"in_progress"`), and the
#      conditional finalize at the BonitoAgents edge silently skipped append +
#      finished_at stamping. The bubble pulsed forever; the chat.md never
#      recorded the tool.
#
#   2. BonitoAgents `Base.close(::ToolMsg)` is TOTAL: non-terminal status at
#      close time is treated as failure — flip to "failed", emit a final
#      `tool_update`, stamp `finished_at`, persist. No silent no-op.
#
#   3. `is_turn_orphan` predicate + `sweep_turn_orphans!` walk msgs_store at
#      end-of-turn and close any ToolMsg still mid-flight. Status-based, so
#      backgrounded bashes (status="completed" at launch) and live worker
#      apps are correctly left alone — their lifecycles are owned elsewhere.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

# Same `make_chat` helper used in test_tool_messages.jl — chat backed by a
# real ChatSession so the persist path is exercised end-to-end.
function make_chat_total()
    state = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
    BT.ChatModel(state, mktempdir();
                  transport = BT.MockTransport((o, i) -> nothing))
end

# ── 1. ACP close(::TurnState) — force-fail pending tools ───────────────────

@testset "ACP close(::TurnState): pending tool → terminal snap + close" begin

    @testset "in_progress tool gets a final failed snap" begin
        st = ACP.TurnState()
        ch = Channel{ACP.ToolCall}(4)
        tc = ACP.GenericTool("tc1", "execute", "long thing", "in_progress",
                             ACP.ToolContent[], ch, "", Dict{String,Any}())
        st.tools[tc.id] = tc

        close(st)

        @test tc.status == "failed"
        @test !isopen(ch)
        # One snap was pushed before the close — that's the terminal hand-off the
        # consumer relies on to see `b.status == "failed"`.
        drained = [snap for snap in ch]
        @test length(drained) == 1
        @test drained[1] === tc                # we put! tc itself
        @test drained[1].status == "failed"
        @test isempty(st.tools)
    end

    @testset "already-terminal tool is just closed (no synthetic snap)" begin
        st = ACP.TurnState()
        ch = Channel{ACP.ToolCall}(4)
        tc = ACP.GenericTool("tc2", "read", "cat foo", "completed",
                             ACP.ToolContent[], ch, "Read", Dict{String,Any}())
        st.tools[tc.id] = tc

        close(st)

        @test tc.status == "completed"          # unchanged
        @test !isopen(ch)
        @test isempty([snap for snap in ch])    # no synthetic snap injected
    end

    @testset "multiple pending tools all get force-failed" begin
        st = ACP.TurnState()
        chs = [Channel{ACP.ToolCall}(4) for _ in 1:3]
        ids = ["a", "b", "c"]
        tcs = [ACP.GenericTool(id, "execute", "x", "in_progress",
                               ACP.ToolContent[], chs[i], "", Dict{String,Any}())
               for (i, id) in enumerate(ids)]
        for tc in tcs
            st.tools[tc.id] = tc
        end

        close(st)

        @test all(tc.status == "failed" for tc in tcs)
        @test all(!isopen(ch) for ch in chs)
        @test isempty(st.tools)
    end
end

# ── 2. BonitoAgents Base.close(::ToolMsg) — total ────────────────────────────

@testset "Base.close(::ToolMsg) is total" begin

    @testset "non-terminal status → force-fail + persist + emit" begin
        chat = make_chat_total()
        t = BT.GenericToolMsg("orphan-1", "execute", "Bash", "long thing",
                              "in_progress", "", time(), nothing, chat)
        push!(chat.msgs_store, t)

        close(t)

        @test t.status == "failed"
        @test t.finished_at !== nothing
        @test BT.is_live(t) == false

        # Wire event: a tool_update with status=failed and a finished_at stamp.
        evt = chat.comm[]
        @test evt["type"]   == "tool_update"
        @test evt["id"]     == "orphan-1"
        @test evt["status"] == "failed"
        @test haskey(evt, "finished_at")

        # Persisted to chat.md — load_history sees a "failed" ToolMsg by id.
        loaded = filter(m -> m isa BT.ToolMsg, BT.load_history(chat.chat_session))
        @test any(m -> m.id == "orphan-1" && m.status == "failed", loaded)
    end

    @testset "already-terminal status → persist unchanged (no force-flip)" begin
        chat = make_chat_total()
        t = BT.GenericToolMsg("ok-1", "read", "Read", "cat x.txt",
                              "completed", "ok", time(), nothing, chat)
        push!(chat.msgs_store, t)

        close(t)

        @test t.status == "completed"               # unchanged
        @test t.finished_at !== nothing             # stamped if it wasn't
        # No spurious force-failed wire event — the natural happy path doesn't
        # emit its own tool_update (the per-snap loop already did that).
        # We only assert the close path is silent on a happy-path message.
        @test isempty(chat.comm[]) || get(chat.comm[], "status", nothing) != "failed"

        loaded = filter(m -> m isa BT.ToolMsg, BT.load_history(chat.chat_session))
        @test any(m -> m.id == "ok-1" && m.status == "completed", loaded)
    end

    @testset "BashToolMsg foreground orphan → force-failed like generic" begin
        chat = make_chat_total()
        b = BT.BashToolMsg("bash-orphan", "execute", "sleep 10", "in_progress", "",
                           time(), nothing, "sleep 10", false, "", 0, false, "", chat)
        push!(chat.msgs_store, b)

        close(b)

        @test b.status == "failed"
        @test b.finished_at !== nothing
        @test BT.is_live(b) == false
    end
end

# ── 3. is_turn_orphan + sweep_turn_orphans! ────────────────────────────────

@testset "is_turn_orphan predicate" begin
    t = time()

    # Non-terminal generic ToolMsg → orphan.
    in_progress = BT.GenericToolMsg("x1", "execute", "Bash", "x", "in_progress",
                                     "", t, nothing, nothing)
    @test BT.is_turn_orphan(in_progress) == true

    pending = BT.GenericToolMsg("x2", "execute", "Bash", "x", "pending",
                                 "", t, nothing, nothing)
    @test BT.is_turn_orphan(pending) == true

    completed = BT.GenericToolMsg("x3", "execute", "Bash", "x", "completed",
                                   "", t, nothing, nothing)
    @test BT.is_turn_orphan(completed) == false

    failed = BT.GenericToolMsg("x4", "execute", "Bash", "x", "failed",
                                "", t, nothing, nothing)
    @test BT.is_turn_orphan(failed) == false

    # KEY invariant: a backgrounded bash has status="completed" the instant the
    # agent reports launch. The sweep MUST leave it alone — its lifecycle is
    # owned by the bg poller, not the chat-message close path. Even with
    # bg_running=true it's NOT a turn orphan, because the status check looks
    # at the ACP-level status, not the chat-side `is_live` overload.
    bg_running = BT.BashToolMsg("bg1", "execute", "sleep 100", "completed", "",
                                 t, nothing, "sleep 100", true,
                                 "/tmp/x.out", 0, true, "", nothing)
    @test BT.is_live(bg_running) == true            # the bg poller's signal
    @test BT.is_turn_orphan(bg_running) == false    # but the sweep ignores it

    # A live worker app (status="completed" once launched) — never an orphan.
    app = BT.BonitoAppMsg("app1", "bonito_app", "plot", "completed", "",
                           t, nothing, "btworker", "app-id", nothing)
    @test BT.is_turn_orphan(app) == false

    # Non-tool messages are never orphans.
    @test BT.is_turn_orphan(BT.UserMsg("hi")) == false
end

@testset "sweep_turn_orphans! closes only orphans" begin
    chat = make_chat_total()
    t = time()

    orphan = BT.GenericToolMsg("orphan-2", "execute", "Bash", "thing",
                                "in_progress", "", t, nothing, chat)
    done   = BT.GenericToolMsg("done-2", "read", "Read", "cat",
                                "completed", "ok", t, t, chat)
    bg     = BT.BashToolMsg("bg-2", "execute", "sleep 100", "completed", "",
                             t, nothing, "sleep 100", true,
                             "/tmp/x.out", 0, true, "", chat)
    user   = BT.UserMsg(chat, "hello")

    push!(chat.msgs_store, orphan)
    push!(chat.msgs_store, done)
    push!(chat.msgs_store, bg)
    push!(chat.msgs_store, user)

    BT.sweep_turn_orphans!(chat)

    # Orphan got closed → failed + stamped.
    @test orphan.status == "failed"
    @test orphan.finished_at !== nothing

    # The "done" tool was not re-touched — status unchanged, finished_at the
    # same epoch we set above (not refreshed by an extra close call).
    @test done.status == "completed"
    @test done.finished_at == t

    # Live background bash is untouched — its lifecycle is the bg poller's.
    @test bg.status == "completed"
    @test bg.bg_running == true
    @test bg.finished_at === nothing

    # Persisted: the orphan now exists on disk as failed; the done tool is
    # present exactly once (no double-append).
    loaded = filter(m -> m isa BT.ToolMsg, BT.load_history(chat.chat_session))
    orphan_loaded = filter(m -> m.id == "orphan-2", loaded)
    @test length(orphan_loaded) == 1
    @test orphan_loaded[1].status == "failed"
end
