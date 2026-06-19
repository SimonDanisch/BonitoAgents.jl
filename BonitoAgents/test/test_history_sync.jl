# Tests for syncing claude's resumed `.claude` history into our chat.md.
#
#   replay_history    — drive `session/load`, capture the agent's re-streamed
#                       history (session/update notifications) and coalesce it
#                       into ordered, fully-assembled messages
#   reconcile_replay! — keep chat.md canonical, adopt only what we're missing:
#                       empty chat.md → adopt all (import); non-empty → append
#                       the tail beyond our shared prefix (CLI-direct gap);
#                       identical → no-op (idempotent). Tools de-dup by id.
#
# Background: on resume the agent re-sends the jsonl as `session/update`s during
# `session/load` (it has no prompt in flight). The refactored dispatcher only
# fed updates to an active prompt turn and dropped these — `request_updates`
# generalizes that so `session/load` captures them too.
#
# TestKit migration. The deleted `MockTransport` scaffolding is gone — this whole
# file is the session/load REPLAY path, which is pure/state-logic, so it stays
# DIRECT unit tests with NO transport / NO agent turn / NO DOM:
#
#   * replay coalescing is driven straight through `ACP.collect_replayed_updates`
#     — the very seam `replay_history` was split into so it can be fed synthetic
#     channels (a `Channel{SessionUpdate}` of parsed wire updates + a `response`
#     channel carrying the session/load result). That is exactly the data
#     `request_updates` would have delivered off a real wire, minus the
#     subprocess; no Connection / transport needed.
#   * `reconcile_replay!` / `adopt_replayed!` round-trip through a real
#     `ChatModel(state, cwd)` whose `agent` is a no-op `MockAgent([])` (a state
#     holder that never spawns a subprocess — nothing here drives a turn). The
#     chat.md / tools persistence is asserted via `load_history` round-trips.

using Test
using BonitoAgents
const BT  = BonitoAgents
const ACP = BonitoAgents.AgentClientProtocol

newstate() = BT.ServerState(; state_dir = mktempdir(),
                              working_dir = mktempdir(), worker_secret = "x")
# A real ChatModel bound to a no-op MockAgent. Nothing in this file drives a
# turn, so the agent is a pure state holder — it never spawns the mock binary.
mkchat()   = BT.ChatModel(newstate(), mktempdir(); agent = BT.MockAgent([]))

am(t)  = ACP.AgentMessage(t)
um(t)  = ACP.UserMessage(t)
tcall(id; status="completed") = ACP.GenericTool(id, "read", "cat", status,
    ACP.ToolContent[ACP.TextContent("contents of $id")], Channel{ACP.ToolCall}(1))

# Drive the session/load replay coalescer the way `replay_history` does, minus
# the wire: parse each raw `update` dict into a `SessionUpdate` (exactly what
# `request_updates` hands off the dispatcher), feed them through a bounded
# channel + a `response` channel carrying the session/load result, and let
# `collect_replayed_updates` assemble the ordered, coalesced history. This is
# the test seam `collect_replayed_updates` was split out for.
function replay_frames(frames; load_result = Dict{String,Any}())
    updates = Channel{ACP.SessionUpdate}(64)
    for upd in frames
        put!(updates, ACP.parse_session_update(upd))
    end
    close(updates)
    response = Channel{Any}(1)
    put!(response, load_result)
    close(response)
    return ACP.collect_replayed_updates(updates, response)
end

@testset "history sync" begin

    @testset "replay_history captures + coalesces the session/load replay" begin
        frames = [
            Dict("sessionUpdate"=>"user_message_chunk",  "content"=>Dict("type"=>"text","text"=>"hi claude")),
            Dict("sessionUpdate"=>"agent_message_chunk", "content"=>Dict("type"=>"text","text"=>"Hello ")),
            Dict("sessionUpdate"=>"agent_message_chunk", "content"=>Dict("type"=>"text","text"=>"world")),
            Dict("sessionUpdate"=>"tool_call", "toolCallId"=>"t1", "kind"=>"read",
                 "title"=>"cat", "status"=>"completed", "content"=>[]),
            Dict("sessionUpdate"=>"agent_thought_chunk", "content"=>Dict("type"=>"text","text"=>"")),
        ]
        replay, load_result = replay_frames(frames)
        @test load_result isa AbstractDict   # raw session/load response surfaced

        @test length(replay) == 4
        @test replay[1] isa ACP.UserMessage  && replay[1].text == "hi claude"
        @test replay[2] isa ACP.AgentMessage && replay[2].text == "Hello world"  # chunks coalesced
        @test replay[3] isa ACP.ToolCall     && replay[3].id == "t1"
        @test replay[4] isa ACP.Thought      && replay[4].text == ""             # redacted, empty
    end

    @testset "reconcile: empty chat.md adopts the whole replay (import)" begin
        m = mkchat()
        BT.reconcile_replay!(m, ACP.Message[um("hello"), am("hi there"), tcall("t1")])
        @test [string(nameof(typeof(x))) for x in m.msgs_store] == ["UserMsg","AgentMsg","GenericToolMsg"]
        reloaded = BT.load_history(m.chat_session)          # round-trips through chat.md
        @test length(reloaded) == 3
        @test isfile(joinpath(m.chat_dir, "tools", "t1.json"))   # tool content persisted
        close(m)
    end

    @testset "reconcile: identical replay is a no-op (idempotent)" begin
        m = mkchat()
        mkreplay() = ACP.Message[um("hello"), am("hi there"), tcall("t1")]
        BT.reconcile_replay!(m, mkreplay())
        n1 = length(m.msgs_store)
        BT.reconcile_replay!(m, mkreplay())                  # resume again, same history
        @test length(m.msgs_store) == n1 == 3
        close(m)
    end

    @testset "reconcile: CLI-direct gap appends only the tail" begin
        m = mkchat()
        BT.adopt_replayed!(m, um("q1")); BT.adopt_replayed!(m, am("a1"))
        BT.reconcile_replay!(m, ACP.Message[um("q1"), am("a1"), um("q2"), am("a2")])
        @test [x.text for x in m.msgs_store] == ["q1","a1","q2","a2"]
        close(m)
    end

    @testset "reconcile: tools de-dup by id; empty thoughts skipped" begin
        m = mkchat()
        BT.adopt_replayed!(m, um("u")); BT.adopt_replayed!(m, am("a")); BT.adopt_replayed!(m, tcall("tx"))
        # replay repeats u/a/tx (tx matched by id) + a thought + a new agent turn
        th = ACP.Thought("")  # redacted thought from claude
        BT.reconcile_replay!(m, ACP.Message[um("u"), am("a"), tcall("tx"), th, am("after-tool")])
        @test length(m.msgs_store) == 4                      # only "after-tool" adopted
        @test m.msgs_store[end] isa BT.AgentMsg && m.msgs_store[end].text == "after-tool"
        @test !any(x -> x isa BT.ThoughtMsg, m.msgs_store)   # empty thought left no trace
        close(m)
    end

end
